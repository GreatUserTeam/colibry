#!/usr/bin/env bash
# Skein disk installer.
#
# Destructively installs Skein onto a whole disk: a 1 GiB EFI system
# partition and one btrfs system partition holding subvolumes @, @home,
# @var, @snapshots and @swap, the system partition inside a LUKS2 volume.
# The system partition takes a fixed comfortable size (like a factory
# Windows install) and the rest of the disk stays unallocated.
#
# Inputs (OOBE mode):
#   ANSWERS_FILE        JSON document with the collected settings
#                       (see /var/lib/skein-oobe.json in the OOBE contract).
#   SKEIN_LUKS_PASS     LUKS passphrase, passed in memory only; the
#                       installer consumes it for luksFormat/luksOpen and
#                       never writes it to any file.
#   OOBE_USERS_FILE     list of "username<TAB>password" lines; the
#                       accounts receive their passwords at first login.
#
# The root account password travels as a sha512-crypt hash inside the JSON
# document and lands in local.nix as users.users.root.hashedPassword; the
# plaintext never exists on disk. In standalone mode every value is asked
# on the terminal and the hash is computed locally (openssl passwd -6).
#
# The full trace goes to the serial debug port directly: /dev/console fans
# writes out to every registered console, which would put the raw trace on
# the visible screen during the installation.
set -Eeuo pipefail

# The trace channel: fd 19 is the serial console, so the full trace of
# every installer line lands in the host-side log and never on the screen.
exec 19>/dev/ttyS0
BASH_XTRACEFD=19
PS4='+$(date "+%H:%M:%S") ${BASH_SOURCE[0]##*/}:${LINENO}: '
set -x

# sudo resets PATH to its secure path; the full system profile is restored
# so every disk tool resolves identically in both modes. The nix flake
# features are pinned for every nix invocation.
export PATH="/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"

log() { printf 'skein-install: %s\n' "$*" >&2; }

# splash_progress PERCENT: advances the progress bar of the Plymouth
# animation the wizard raised for the installation; every failure mode
# (missing client, inactive daemon, unsupported command) degrades to a
# no-op so the installer never depends on the splash.
splash_progress() {
  command -v plymouth >/dev/null 2>&1 || return 0
  plymouth --ping >/dev/null 2>&1 || return 0
  plymouth system-update --progress "$1" >/dev/null 2>&1 || true
}

# The error trap names the exact failing line and command on the trace
# channel; the wizard surfaces the same information on the screen.
trap 'rc=$?; set +x; printf "skein-install: FAIL line %s exit %s: %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

# ---- inputs -----------------------------------------------------------------

if [ -n "${ANSWERS_FILE:-}" ] && [ -f "$ANSWERS_FILE" ]; then
  # OOBE mode: the wizard collected everything; consent is the wizard's
  # summary screen. The answers arrive as JSON; jq is the parser.
  USERS_SOURCE="${OOBE_USERS_FILE:?users handover file missing}"
  ENCRYPT=yes
  # The passphrase lives only in this process environment; it is consumed
  # below by cryptsetup and never persisted.
  ROOTPW="${SKEIN_LUKS_PASS:?LUKS passphrase handover missing}"

  HOSTNAME=$(jq -r .hostname "$ANSWERS_FILE")
  TIMEZONE=$(jq -r .timezone "$ANSWERS_FILE")
  LOCALE=$(jq -r .locale "$ANSWERS_FILE")
  read -r -a KEYMAPS < <(jq -r '.keymaps | join(" ")' "$ANSWERS_FILE")
  DISK=$(jq -r .disk "$ANSWERS_FILE")
  ROOT_SIZE=$(jq -r .root_size "$ANSWERS_FILE")
  ROOT_HASH=$(jq -r .root_password_hash "$ANSWERS_FILE")

  log "mode=oobe host=$HOSTNAME tz=$TIMEZONE locale=$LOCALE keymaps=${KEYMAPS[*]} disk=$DISK size=$ROOT_SIZE encrypt=$ENCRYPT"
else
  # Standalone mode: every value is asked here, without the wizard.
  command -v openssl >/dev/null || { log "openssl not found - cannot hash the root password"; exit 1; }
  lsblk -o NAME,SIZE,MODEL | head -n 20
  read -r -p 'Target disk (e.g. /dev/vda): ' DISK
  read -r -p 'Time zone (e.g. Europe/Berlin): ' TIMEZONE
  timedatectl list-timezones | grep -qxF "$TIMEZONE" || { log "unknown time zone"; exit 1; }
  read -r -p 'Locale (e.g. en_US.UTF-8): ' LOCALE
  locale -a 2>/dev/null | grep -qi "^$(printf '%s' "$LOCALE" | tr -d '.')\.utf8$" || { log "unknown locale"; exit 1; }
  read -r -p 'Computer name: ' HOSTNAME
  read -r -p 'Keyboard layouts (comma separated, e.g. us,ru): ' KMIN
  IFS=',' read -r -a KEYMAPS <<< "$KMIN"
  read -r -p 'System size [auto/max/custom GiB]: ' ROOT_SIZE
  read -r -p 'Encrypt the disk with LUKS2? [yes/no]: ' ENCRYPT
  if [ "$ENCRYPT" = yes ]; then
    printf 'Disk passphrase (this also becomes the root password): '
    read -r -s ROOTPW; printf '\n'
  else
    ROOTPW=''
  fi
  ROOT_HASH=$(openssl passwd -6 "$ROOTPW")
  INTERACTIVE_USERS=/etc/skein/interactive-users
  : > "$INTERACTIVE_USERS"; chmod 600 "$INTERACTIVE_USERS"
  log 'User account passwords are set by each user at first login.'
  while :; do
    printf 'User name (empty to finish): '; read -r UN
    [ -n "$UN" ] || break
    printf '%s\n' "$UN" >> "$INTERACTIVE_USERS"
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
[ "$ROOT_HASH" != null ] && [ -n "$ROOT_HASH" ] || { log "root password hash missing from the answers"; exit 1; }
case "$ROOT_HASH" in \$6\$*) ;; *) log "root password hash is not a sha512-crypt string"; exit 1 ;; esac
timedatectl list-timezones | grep -qxF "$TIMEZONE" || { log "unknown time zone $TIMEZONE"; exit 1; }
command -v nixos-install >/dev/null || { log "nixos-install not found - run from a NixOS live session"; exit 1; }
for tool in jq parted mkfs.fat mkfs.btrfs cryptsetup nixos-generate-config; do
  command -v "$tool" >/dev/null || { log "$tool not found"; exit 1; }
done

# The keyboard layouts normalize to lowercase console keymap names; the xkb
# layout is the first entry, several layouts get the Alt+Shift switch.
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
  log "WARNING: no UEFI firmware detected; the installed system boots only on UEFI machines."
fi

# Resolve the system partition size in bytes. Windows-style sizing: the
# system partition always takes a fixed comfortable size for the OS, its
# package store and retained update generations, and the rest of the disk
# stays unallocated for the user to claim later. Small disks give the
# system a quarter instead, so USB sticks and VM test disks stay useful.
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
ESP_BYTES=$((1025 * 1024 * 1024))
case "$ROOT_SIZE" in
  auto)   if [ "$DISK_BYTES" -lt $((128 * 1024 * 1024 * 1024)) ]; then
            ROOT_BYTES=$((DISK_BYTES / 4))
          else
            ROOT_BYTES=$((64 * 1024 * 1024 * 1024))
          fi ;;
  max)    ROOT_BYTES=$((DISK_BYTES - ESP_BYTES)) ;;
  ''|*[!0-9]*) { log "invalid ROOT_SIZE '$ROOT_SIZE'"; exit 1; } ;;
  *)      ROOT_BYTES=$((ROOT_SIZE * 1024 * 1024 * 1024)) ;;
esac
[ "$ROOT_BYTES" -ge $((24 * 1024 * 1024 * 1024)) ] || { log "system partition must be at least 24 GiB"; exit 1; }
[ $((ESP_BYTES + ROOT_BYTES)) -le "$DISK_BYTES" ] || { log "system size exceeds the disk"; exit 1; }
ROOT_END=$((ESP_BYTES + ROOT_BYTES))

# ---- partitioning -----------------------------------------------------------

splash_progress 10
log "partitioning $DISK (ESP 1 GiB + system $(numfmt --to=iec "$ROOT_BYTES"))"
parted -s --align optimal "$DISK" mklabel gpt
parted -s --align optimal "$DISK" mkpart SKEIN-BOOT fat32 1MiB 1025MiB
parted -s --align optimal "$DISK" set 1 esp on
parted -s --align optimal "$DISK" mkpart SKEIN-ROOT btrfs 1025MiB "${ROOT_END}B"
partprobe "$DISK" 2>/dev/null || true
sleep 1
ESP_PART=/dev/disk/by-partlabel/SKEIN-BOOT
ROOT_PART=/dev/disk/by-partlabel/SKEIN-ROOT
for _ in $(seq 1 10); do [ -e "$ESP_PART" ] && [ -e "$ROOT_PART" ] && break; sleep 1; done
[ -e "$ESP_PART" ] && [ -e "$ROOT_PART" ] || { log "partition nodes did not appear"; exit 1; }

# The EFI system partition carries the boot loader; parted only carves the
# partition, so a fresh FAT32 is created here before any mount relies on it.
mkfs.fat -F 32 -n SKEIN-BOOT "$ESP_PART"

# ---- encryption --------------------------------------------------------------

if [ "$ENCRYPT" = yes ]; then
  # The passphrase is taken from the environment (OOBE mode) or from the
  # interactive prompt above (standalone mode); in both cases it exists
  # only in the memory of this process.
  printf '%s' "$ROOTPW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$ROOT_PART"
  printf '%s' "$ROOTPW" | cryptsetup open --key-file - "$ROOT_PART" skein-root
  BTRFS_DEV=/dev/mapper/skein-root
else
  BTRFS_DEV=$ROOT_PART
fi
unset ROOTPW
splash_progress 30

# ---- btrfs layout --------------------------------------------------------------

mkfs.btrfs -f -L SKEIN "$BTRFS_DEV"
mount "$BTRFS_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt

mount -o subvol=@,compress=zstd,noatime "$BTRFS_DEV" /mnt
mkdir -p /mnt/home /mnt/var /mnt/.snapshots /mnt/swap /mnt/boot
mount -o subvol=@home,compress=zstd,noatime "$BTRFS_DEV" /mnt/home
mount -o subvol=@var,compress=zstd,noatime "$BTRFS_DEV" /mnt/var
mount -o subvol=@snapshots,compress=zstd,noatime "$BTRFS_DEV" /mnt/.snapshots
mount -o subvol=@swap,nodatacow "$BTRFS_DEV" /mnt/swap
mount "$ESP_PART" /mnt/boot

chattr +C /mnt/swap
btrfs filesystem mkswapfile --size 2g /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
swapon /mnt/swap/swapfile
splash_progress 40

# ---- NixOS configuration of the installed system --------------------------------

# The distro flake is copied from the live system into the target's /etc;
# the copy is byte-identical to the live flake.
TARGET=/mnt/etc/nixos/skein
mkdir -p "$TARGET"
cp -r "$(readlink -f /etc/skein/flake)/." "$TARGET/"
chmod -R u+w "$TARGET"
[ -f "$TARGET/flake.lock" ] || { log "flake.lock is missing from the live flake - rebuild the ISO"; exit 1; }

# The machine configuration is generated directly INTO the flake directory.
# The generated luks entries would declare the volume a second time (Skein
# names the device in local.nix), so they are stripped. nixos-generate-config
# never overwrites an existing configuration.nix, so the copied distro file
# survives untouched.
nixos-generate-config --root /mnt --dir "$TARGET"
sed -i -e '/boot.initrd.luks/d' "$TARGET/hardware-configuration.nix"

{
  printf '{ config, lib, ... }:\n{\n'
  printf '  boot.loader.systemd-boot.enable = lib.mkDefault true;\n'
  printf '  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;\n'
  printf '  boot.loader.systemd-boot.consoleMode = lib.mkDefault "max";\n'
  printf '  boot.loader.systemd-boot.editor = lib.mkDefault false;\n'
  printf '  boot.loader.timeout = lib.mkDefault 0;\n'
  printf '}\n'
} > "$TARGET/installed-boot.nix"

# local.nix carries the collected values. The root password arrives as a
# sha512-crypt hash and is installed as hashedPassword, so the plaintext
# never touches the target disk. The LUKS device is declared only when
# encryption was chosen. The update manager stays off in development
# builds (released installers write the update server channels here).
{
  printf '{ config, lib, ... }:\n{\n'
  printf '  networking.hostName = "%s";\n' "$HOSTNAME"
  printf '  time.timeZone = "%s";\n' "$TIMEZONE"
  printf '  i18n.defaultLocale = "%s";\n' "$LOCALE"
  printf '  services.xserver.xkb.layout = "%s";\n' "$XKB_LAYOUT"
  [ -n "$XKB_OPTIONS" ] && printf '  services.xserver.xkb.options = "%s";\n' "$XKB_OPTIONS"
  printf '  console.keyMap = "%s";\n' "$CONSOLE_KEYMAP"
  printf '  users.users.root.hashedPassword = "%s";\n' "$ROOT_HASH"
  printf '  skein.updates.enable = false;\n'
  if [ "$ENCRYPT" = yes ]; then
    printf '  boot.initrd.luks.devices."skein-root".device = "%s";\n' "$ROOT_PART"
  fi
  printf '}\n'
} > "$TARGET/local.nix"
splash_progress 55

# ---- build phase -----------------------------------------------------------------

dd if=/dev/zero of=/mnt/swap/swapfile.build bs=1M count=12288 status=none
chmod 600 /mnt/swap/swapfile.build
mkswap /mnt/swap/swapfile.build
swapon /mnt/swap/swapfile.build

# Offline preflight: build the exact system closure of the target flake
# against the live store; a failure here aborts before nixos-install. The
# installer image ships the source trees of every locked flake input in
# its store (system.extraDependencies in iso/iso.nix), so the offline
# evaluation resolves the inputs without any download. The full nix
# output is captured, so the failure reason is visible on the wizard's
# failure screen and in the serial log.
log "preflight: building the system closure offline"
splash_progress 70
if ! nix build --offline --no-link "$TARGET#nixosConfigurations.skein.config.system.build.toplevel" \
    > /tmp/skein-preflight.log 2>&1; then
  log "preflight build failed; the last lines of the nix output follow:"
  tail -n 25 /tmp/skein-preflight.log >&2
  exit 1
fi

log "running nixos-install"
splash_progress 80
nixos-install --flake "$TARGET#skein" --no-root-passwd
splash_progress 95

# ---- first-boot provisioning handover --------------------------------------------

# The provisioning service of the installed system reads these files on
# first boot and deletes them afterwards. The users file keeps the
# "username<TAB>password" line format its provisioning service reads.
install -m 600 "$USERS_SOURCE" /mnt/etc/skein/homed-users
touch /mnt/etc/skein/firstboot

# ---- teardown -----------------------------------------------------------------------

swapoff /mnt/swap/swapfile.build
rm -f /mnt/swap/swapfile.build
swapoff /mnt/swap/swapfile
sync
umount -R /mnt
splash_progress 100

log "installation finished"
