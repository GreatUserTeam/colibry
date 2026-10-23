#!/usr/bin/env bash
# Spark disk installer.
#
# Destructively installs Spark onto a whole disk with the layout the
# distro is designed around: a 1 GB EFI system partition and one btrfs
# system partition holding subvolumes @, @home, @var, @snapshots and @swap
# (the rest of the disk stays unallocated, like a factory Windows install).
# The system partition sits inside a LUKS2 volume whose passphrase is the
# root password collected by the OOBE wizard.
#
# The script runs in two modes. In OOBE mode (ANSWERS_FILE with the wizard
# answers plus the root-password and users handover files) it runs without
# a single interactive question; in standalone mode every value is asked
# on the terminal. All progress goes to the serial console as a bash trace;
# the wizard shows only the activity bar and reads the log on failure.
#
# The final phase is network-independent by construction: the distro flake
# ships in the live system with its flake.lock, the installer copies it to
# the target, and the exact system closure is built against the live store
# BEFORE nixos-install runs (the same derivation nixos-install will build,
# because the copied flake is byte-identical to the live one). Building the
# closure up front surfaces every evaluation or cache problem before the
# build swap exists, and the nixos-install build itself becomes a pure
# store lookup.
set -Eeuo pipefail

# The trace channel: fd 19 is the serial console (see configuration.nix),
# so the full trace of every installer line lands in the host-side log.
exec 19>/dev/console
BASH_XTRACEFD=19
PS4='+$(date "+%H:%M:%S") ${BASH_SOURCE[0]##*/}:${LINENO}: '
set -x

# sudo resets PATH to its secure path; the full system profile is restored
# so every disk tool resolves the same way in both modes. The nix flake
# features are pinned here so every nix invocation behaves identically no
# matter which nix.conf the calling unit has.
export PATH="/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"

log() { printf 'spark-install: %s\n' "$*" >&2; }

# The error trap names the exact failing line and command on the trace
# channel; the wizard surfaces the same information on the screen.
trap 'rc=$?; set +x; printf "spark-install: FAIL line %s exit %s: %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

# ---- inputs -----------------------------------------------------------------

INTERACTIVE_USERS=/etc/spark/interactive-users
: > "$INTERACTIVE_USERS"; chmod 600 "$INTERACTIVE_USERS"

if [ -n "${ANSWERS_FILE:-}" ] && [ -f "$ANSWERS_FILE" ]; then
  # OOBE mode: the wizard collected everything; consent is the wizard's
  # summary screen, the root password doubles as the disk passphrase, and
  # the system is always encrypted. The handover files are consumed from
  # their wizard paths and deleted from the live system afterwards.
  . "$ANSWERS_FILE"
  PW_FILE="${OOBE_ROOTPW_FILE:?root password handover file missing}"
  USERS_SOURCE="${OOBE_USERS_FILE:?users handover file missing}"
  ROOTPW=$(cat "$PW_FILE")
  ENCRYPT=yes
  log "mode=oobe host=$HOSTNAME tz=$TIMEZONE locale=$LOCALE keymaps=${KEYMAPS[*]} disk=$DISK size=$ROOT_SIZE encrypt=$ENCRYPT"
else
  # Standalone mode: every value is asked here, without the wizard.
  lsblk -o NAME,SIZE,MODEL | head -n 20
  read -r -p 'Target disk (e.g. /dev/vda): ' DISK
  read -r -p 'Time zone (e.g. Europe/Berlin): ' TIMEZONE
  [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || { log "unknown time zone"; exit 1; }
  read -r -p 'Locale (e.g. en_US.UTF-8): ' LOCALE
  locale -a 2>/dev/null | grep -qi "^$(printf '%s' "$LOCALE" | tr -d '.')\.utf8$" || { log "unknown locale"; exit 1; }
  read -r -p 'Computer name: ' HOSTNAME
  read -r -p 'Keyboard layouts (comma separated, e.g. us,ru): ' KMIN
  IFS=',' read -r -a KEYMAPS <<< "$KMIN"
  read -r -p 'System size [auto/max/custom GiB]: ' ROOT_SIZE
  read -r -p 'Encrypt the disk with LUKS2? [yes/no]: ' ENCRYPT
  if [ "$ENCRYPT" = yes ]; then
    printf 'Disk passphrase: '; read -r -s ROOTPW; printf '\n'
  else
    ROOTPW=''
  fi
  printf 'Root password: '; read -r -s PW1; printf '\n'
  printf 'Repeat: '; read -r -s PW2; printf '\n'
  [ "$PW1" = "$PW2" ] && [ -n "$PW1" ] || { log "root passwords differ"; exit 1; }
  PW_FILE=/etc/spark/root-password
  (umask 077; printf '%s' "$PW1" > "$PW_FILE")
  while :; do
    printf 'User name (empty to finish): '; read -r UN
    [ -n "$UN" ] || break
    printf 'Password for %s: ' "$UN"; read -r -s UP1; printf '\n'
    printf 'Repeat: '; read -r -s UP2; printf '\n'
    [ "$UP1" = "$UP2" ] && [ -n "$UP1" ] || { log "passwords differ"; exit 1; }
    printf '%s\t%s\n' "$UN" "$UP1" >> "$INTERACTIVE_USERS"
  done
  [ -s "$INTERACTIVE_USERS" ] || { log "at least one user is required"; exit 1; }
  USERS_SOURCE=$INTERACTIVE_USERS
fi

# ---- input validation -------------------------------------------------------

[ -b "$DISK" ] || { log "$DISK is not a block device"; exit 1; }
case "$HOSTNAME" in
  *[!a-zA-Z0-9-]*|'') log "invalid hostname"; exit 1 ;;
esac
HOSTNAME=$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')
[ -f "/usr/share/zoneinfo/$TIMEZONE" ] || { log "unknown time zone $TIMEZONE"; exit 1; }
command -v nixos-install >/dev/null || { log "nixos-install not found - run from a NixOS live session"; exit 1; }
for tool in parted mkfs.fat mkfs.btrfs cryptsetup nixos-generate-config; do
  command -v "$tool" >/dev/null || { log "$tool not found"; exit 1; }
done

# The keyboard layouts normalize to lowercase console keymap names; the xkb
# layout is the first entry (every layout this image offers has an xkb twin
# under the same name), and several layouts get the Alt+Shift switch.
KEYMAPS=($(printf '%s\n' "${KEYMAPS[@]}" | tr '[:upper:]' '[:lower:]'))
XKB_LAYOUT=${KEYMAPS[0]}
CONSOLE_KEYMAP=${KEYMAPS[0]}
if [ "${#KEYMAPS[@]}" -gt 1 ]; then
  XKB_OPTIONS='grp:alt_shift_toggle'
else
  XKB_OPTIONS=''
fi

# ---- preflight: disk state and boot firmware ---------------------------------

findmnt -rn "$DISK" >/dev/null && { log "$DISK is mounted - unmount it first"; exit 1; }
if [ ! -d /sys/firmware/efi ]; then
  # systemd-boot needs UEFI; the install itself still proceeds and the
  # warning is visible on the trace channel and in the install log.
  log "WARNING: no UEFI firmware detected; the installed system boots only on UEFI machines."
fi

# Resolve the system partition size in bytes.
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
ESP_BYTES=$((1025 * 1024 * 1024)) # The ESP starts at 1 MiB and is 1 GiB large.
case "$ROOT_SIZE" in
  auto)   if [ "$DISK_BYTES" -lt $((320 * 1024 * 1024 * 1024)) ]; then
            ROOT_BYTES=$((DISK_BYTES / 4)) # Small disks: a quarter of the disk.
          else
            ROOT_BYTES=$((80 * 1024 * 1024 * 1024)) # Large disks: 80 GiB.
          fi ;;
  max)    ROOT_BYTES=$((DISK_BYTES - ESP_BYTES)) ;;
  ''|*[!0-9]*) { log "invalid ROOT_SIZE '$ROOT_SIZE'"; exit 1; } ;;
  *)      ROOT_BYTES=$((ROOT_SIZE * 1024 * 1024 * 1024)) ;;
esac
[ "$ROOT_BYTES" -ge $((24 * 1024 * 1024 * 1024)) ] || { log "system partition must be at least 24 GiB"; exit 1; }
[ $((ESP_BYTES + ROOT_BYTES)) -le "$DISK_BYTES" ] || { log "system size exceeds the disk"; exit 1; }
ROOT_END=$((ESP_BYTES + ROOT_BYTES)) # Absolute byte offset of the partition end.

# ---- partitioning -----------------------------------------------------------

log "partitioning $DISK (ESP 1 GiB + system $(numfmt --to=iec "$ROOT_BYTES"))"
parted -s --align optimal "$DISK" mklabel gpt
parted -s --align optimal "$DISK" mkpart SPARK-BOOT fat32 1MiB 1025MiB
parted -s --align optimal "$DISK" set 1 esp on
parted -s --align optimal "$DISK" mkpart SPARK-ROOT btrfs 1025MiB "${ROOT_END}B"
partprobe "$DISK" 2>/dev/null || true
sleep 1
ESP_PART=/dev/disk/by-partlabel/SPARK-BOOT
ROOT_PART=/dev/disk/by-partlabel/SPARK-ROOT
for _ in $(seq 1 10); do [ -e "$ROOT_PART" ] && break; sleep 1; done
[ -e "$ROOT_PART" ] || { log "partition nodes did not appear"; exit 1; }

# ---- encryption (optional) ---------------------------------------------------

if [ "$ENCRYPT" = yes ]; then
  printf '%s' "$ROOTPW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$ROOT_PART"
  printf '%s' "$ROOTPW" | cryptsetup open --key-file - "$ROOT_PART" spark-root
  BTRFS_DEV=/dev/mapper/spark-root
else
  BTRFS_DEV=$ROOT_PART
fi

# ---- btrfs layout --------------------------------------------------------------

mkfs.btrfs -f -L SPARK "$BTRFS_DEV"
mount "$BTRFS_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt

# Root subvolume options: zstd compression everywhere, no atime updates; the
# swap subvolume opts out of copy-on-write so the swapfile never fragments.
mount -o subvol=@,compress=zstd,noatime "$BTRFS_DEV" /mnt
mkdir -p /mnt/{home,var,.snapshots,swap,boot}
mount -o subvol=@home,compress=zstd,noatime "$BTRFS_DEV" /mnt/home
mount -o subvol=@var,compress=zstd,noatime "$BTRFS_DEV" /mnt/var
mount -o subvol=@snapshots,compress=zstd,noatime "$BTRFS_DEV" /mnt/.snapshots
mount -o subvol=@swap,nodatacow "$BTRFS_DEV" /mnt/swap
mount "$ESP_PART" /mnt/boot

# The persistent 2 GiB swapfile inside @swap; it activates now (the build
# phase below needs it) and on every boot of the installed system.
chattr +C /mnt/swap
btrfs filesystem mkswapfile --size 2g /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# ---- NixOS configuration of the installed system --------------------------------

# The distro flake is copied from the live system into the target's /etc.
# The copy is byte-identical to the live flake (NAR hashing ignores the
# writable bit the chmod adds), so the closure preflight below builds the
# exact derivation nixos-install will build.
TARGET=/mnt/etc/nixos/spark
mkdir -p "$TARGET"
cp -r "$(readlink -f /etc/spark/flake)/." "$TARGET/"
chmod -R u+w "$TARGET"
[ -f "$TARGET/flake.lock" ] || { log "flake.lock is missing from the live flake - rebuild the ISO"; exit 1; }

# The machine configuration is generated directly INTO the flake directory:
# configuration.nix imports ./hardware-configuration.nix relative to its own
# location, and the generated file describes the freshly created volumes.
# The generated luks entries would declare the volume a second time (Spark
# names the device in local.nix), so they are stripped; the generated
# configuration.nix template is removed because the flake defines its
# configurations in flake.nix and nothing imports the template.
nixos-generate-config --root /mnt --dir "$TARGET"
sed -i -e '/boot.initrd.luks/d' "$TARGET/hardware-configuration.nix"
rm -f "$TARGET/configuration.nix"

# installed-boot.nix carries the boot loader of the machine. Every value is
# a default: shared modules may refine them, and the ISO (which never sees
# this file) is untouched.
{
  printf '{ config, lib, ... }:\n{\n'
  printf '  boot.loader.systemd-boot.enable = lib.mkDefault true;\n'
  printf '  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;\n'
  printf '  boot.loader.systemd-boot.consoleMode = lib.mkDefault "max";\n'
  printf '  boot.loader.systemd-boot.editor = lib.mkDefault false;\n'
  printf '  boot.loader.timeout = lib.mkDefault 0;\n'
  printf '}\n'
} > "$TARGET/installed-boot.nix"

# local.nix overrides the defaults of configuration.nix with the values
# the wizard collected. Only the LUKS entry is written when encryption was
# chosen, so an unencrypted system never carries a dead placeholder.
{
  printf '{ config, lib, ... }:\n{\n'
  printf '  networking.hostName = "%s";\n' "$HOSTNAME"
  printf '  time.timeZone = "%s";\n' "$TIMEZONE"
  printf '  i18n.defaultLocale = "%s";\n' "$LOCALE"
  printf '  services.xserver.xkb.layout = "%s";\n' "$XKB_LAYOUT"
  [ -n "$XKB_OPTIONS" ] && printf '  services.xserver.xkb.options = "%s";\n' "$XKB_OPTIONS"
  printf '  console.keyMap = "%s";\n' "$CONSOLE_KEYMAP"
  if [ "$ENCRYPT" = yes ]; then
    printf '  boot.initrd.luks.devices."spark-root".device = "%s";\n' "$ROOT_PART"
  fi
  printf '}\n'
} > "$TARGET/local.nix"

# ---- build phase -----------------------------------------------------------------

# The build swap gives the Nix build room beyond the live RAM; it is a
# scratch file, removed before unmounting.
dd if=/dev/zero of=/mnt/swap/swapfile.build bs=1M count=12288 status=none
chmod 600 /mnt/swap/swapfile.build
mkswap /mnt/swap/swapfile.build
swapon /mnt/swap/swapfile.build

# Offline preflight: build the exact system closure of the target flake
# against the live store. Every input of the closure is pinned in
# flake.lock and already present in the live store (the ISO was built
# from the same lock), so nothing is fetched. A failure here aborts before
# nixos-install and is fully diagnosable on the trace channel.
log "preflight: building the system closure offline"
nix build --offline --no-link "$TARGET#nixosConfigurations.spark.config.system.build.toplevel"

log "running nixos-install"
nixos-install --flake "$TARGET#spark" --no-root-passwd

# ---- first-boot provisioning handover --------------------------------------------

# The provisioning service of the installed system (modules/encryption.nix)
# reads these files on its first boot and deletes them afterwards.
install -m 600 "$PW_FILE" /mnt/etc/spark/root-password
install -m 600 "$USERS_SOURCE" /mnt/etc/spark/homed-users
touch /mnt/etc/spark/firstboot
sed -i "s/time.timeZone = lib.mkDefault \"UTC\";/time.timeZone = lib.mkDefault \"$TIMEZONE\";/" "$TARGET/configuration.nix"

# ---- teardown -----------------------------------------------------------------------

swapoff /mnt/swap/swapfile.build
rm -f /mnt/swap/swapfile.build
swapoff /mnt/swap/swapfile
sync
umount -R /mnt

log "installation finished"
