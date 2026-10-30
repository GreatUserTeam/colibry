#!/usr/bin/env bash
# Colibry disk installer - disk phase.
#
# Prepares the target disk of the Colibry installer: it validates the
# wizard's answers document, partitions the chosen disk in the Windows
# layout (a 1 GiB EFI system partition, one system partition sized by
# the answers, the rest of the disk left unallocated), encrypts the
# system partition with LUKS2, creates the btrfs subvolume layout and
# mounts everything at /mnt. The system installation itself continues in
# install-system.sh, which this script sources as its last step, so both
# phases share one process, one trace log and one error surface.
#
# Inputs (all provided by the OOBE wizard, see colibry-oobe.sh):
#   ANSWERS_FILE      required, JSON document of the collected answers
#   OOBE_USERS_FILE   required, "username<TAB>password" lines
#   COLIBRY_LUKS_PASS the disk passphrase; the single-password model of
#                     Colibry makes the root password the LUKS passphrase,
#                     so it travels in the process environment and never
#                     touches a file or a command line
set -Eeuo pipefail

# Command trace: fd 19 appends every executed line to the trace log; the
# wizard failure surface paints its tail into the journal.
exec 19>>/var/log/colibry-install-trace.log
BASH_XTRACEFD=19
set -x

# log: the only voice of the installer on stderr; the wizard captures
# everything into /var/log/colibry-install.log.
log() { printf 'colibry-install: %s\n' "$*" >&2; }

: "${ANSWERS_FILE:?ANSWERS_FILE is required}"
: "${OOBE_USERS_FILE:?OOBE_USERS_FILE is required}"
export OOBE_USERS_FILE

# The answers document is the single source of the collected values; jq
# emits shell assignments evaluated in this process.
eval "$(jq -r '@sh "HOSTNAME=\(.hostname) TIMEZONE=\(.timezone) LOCALE=\(.locale) DISK=\(.disk) ROOT_SIZE=\(.root_size) ROOT_PW_HASH=\(.root_password_hash) ENCRYPT=\(.encrypt)"' "$ANSWERS_FILE")"
mapfile -t KEYMAPS < <(jq -r '.keymaps[]' "$ANSWERS_FILE")

# XKB layout list: every chosen layout is usable, switching between the
# layouts happens with Alt+Shift when more than one is chosen.
XKB_LAYOUT=$(IFS=,; echo "${KEYMAPS[*]}")
XKB_OPTIONS=""
((${#KEYMAPS[@]} > 1)) && XKB_OPTIONS="grp:alt_shift_toggle"
CONSOLE_KEYMAP=${KEYMAPS[0]}

# The users handover must be "username<TAB>password" lines with sane
# names; the provisioning service of the installed system reads it.
[ -s "$OOBE_USERS_FILE" ] || { log "users handover $OOBE_USERS_FILE is empty"; exit 1; }
while IFS=$'\t' read -r user_name _; do
  [ -n "$user_name" ] || continue
  [[ "$user_name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { log "invalid user name in handover: $user_name"; exit 1; }
done < "$OOBE_USERS_FILE"

# --- disk selection and sizing (Windows-like layout) ---------------------------------------------

[ -b "$DISK" ] || { log "disk $DISK is not a block device"; exit 1; }
findmnt -rn --source "$DISK" >/dev/null && { log "$DISK is mounted; refusing to partition"; exit 1; }

DISK_BYTES=$(blockdev --getsize64 "$DISK")
ESP_BYTES=$((1024 ** 3))          # the EFI system partition is 1 GiB
MIN_ROOT_BYTES=$((24 * 1024 ** 3)) # the system partition never shrinks below 24 GiB

# Root size resolution: "auto" is 80 GiB, or 25% of the whole disk on
# disks under 320 GiB where 80 GiB would dominate; "max" takes everything
# after the ESP; a plain size (numfmt syntax, e.g. 120G) is taken as-is.
case "$ROOT_SIZE" in
  auto)
    if (( DISK_BYTES < 320 * 1024 ** 3 )); then
      ROOT_BYTES=$(( DISK_BYTES * 25 / 100 ))
    else
      ROOT_BYTES=$(( 80 * 1024 ** 3 ))
    fi ;;
  max) ROOT_BYTES=$(( DISK_BYTES - ESP_BYTES )) ;;
  *)   ROOT_BYTES=$(numfmt --from=iec "${ROOT_SIZE^^}") ;;
esac

# Anything below the floor, or larger than the disk after the ESP, is a
# configuration error, not something to silently clamp.
(( ROOT_BYTES >= MIN_ROOT_BYTES )) || { log "root size $ROOT_SIZE is below 24G"; exit 1; }
(( ROOT_BYTES < DISK_BYTES - ESP_BYTES )) || { log "root size leaves no room after the ESP"; exit 1; }

log "partitioning $DISK (ESP 1G, root $(numfmt --to=iec "$ROOT_BYTES"), rest unallocated)"
parted --script "$DISK" mklabel gpt
parted --script "$DISK" mkpart ESP fat32 1MiB $(( ESP_BYTES / 1024**2 + 1 ))MiB
parted --script "$DISK" set 1 esp on
# The rest of the disk after the root partition stays unallocated, like a
# factory Windows install; the dynamic swap service grows into it later.
if [ "$ROOT_SIZE" = max ]; then
  parted --script "$DISK" mkpart COLIBRY-ROOT "$(( ESP_BYTES / 1024**2 + 1 ))"MiB 100%
else
  parted --script "$DISK" mkpart COLIBRY-ROOT "$(( ESP_BYTES / 1024**2 + 1 ))"MiB \
      "$(( ESP_BYTES / 1024**2 + 1 + ROOT_BYTES / 1024**2 ))"MiB
fi
udevadm settle

# Partition nodes: lsblk lists the disk first, its partitions after.
mapfile -t PARTS < <(lsblk -rno PATH "$DISK" | tail -n +2)
[ "${#PARTS[@]}" -ge 2 ] || { log "partitioning produced no device nodes"; exit 1; }
ESP_PART=${PARTS[0]}
ROOT_PART=${PARTS[1]}

# --- encryption -----------------------------------------------------------------------------------

# The single-password model: the root password chosen in the wizard is
# the LUKS passphrase. It arrives in the process environment, is piped to
# cryptsetup on stdin and is unset immediately after the volume is open.
if [ "$ENCRYPT" = true ]; then
  log "encrypting $ROOT_PART with LUKS2 (AES-XTS-512)"
  printf '%s' "$COLIBRY_LUKS_PASS" | cryptsetup luksFormat --type luks2 \
      --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id \
      --key-file - "$ROOT_PART"
  printf '%s' "$COLIBRY_LUKS_PASS" | cryptsetup open --key-file - "$ROOT_PART" colibry-root
  BTRFS_DEV=/dev/mapper/colibry-root
else
  BTRFS_DEV=$ROOT_PART
fi

# The root-password handover of the installed system: a one-shot service
# (modules/encryption.nix) applies the password with chpasswd on the
# first boot and removes the file. The plaintext exists on the target
# disk only inside the soon-to-be-encrypted root partition, mode 0600.
install -d -m 0755 /mnt/etc/colibry
(umask 077; printf '%s' "$COLIBRY_LUKS_PASS" > /mnt/etc/colibry/root-password)
unset COLIBRY_LUKS_PASS

# --- filesystems ----------------------------------------------------------------------------------

mkfs.fat -F 32 -n ESP "$ESP_PART"
mkfs.btrfs -f -L COLIBRY "$BTRFS_DEV"

# Subvolumes are created on the top level of the fresh filesystem, then
# the top level is unmounted and each subvolume is mounted at its place:
#   @          system root        @var        mutable state
#   @home      user homes (homed containers)  @snapshots  timeline
#   @swap      nodatacow swap area
mount "$BTRFS_DEV" /mnt
for sub in @ @home @var @snapshots @swap; do
  btrfs subvolume create "/mnt/$sub"
done
umount /mnt

# Root options compress the whole system; @swap is nodatacow, so the
# swap file never fights copy-on-write.
mount -o noatime,compress=zstd,subvol=@ "$BTRFS_DEV" /mnt
mkdir -p /mnt/home /mnt/var /mnt/.snapshots /mnt/swap /mnt/boot
mount -o noatime,compress=zstd,subvol=@home "$BTRFS_DEV" /mnt/home
mount -o noatime,compress=zstd,subvol=@var "$BTRFS_DEV" /mnt/var
mount -o noatime,compress=zstd,subvol=@snapshots "$BTRFS_DEV" /mnt/.snapshots
mount -o noatime,nodatacow,subvol=@swap "$BTRFS_DEV" /mnt/swap
chmod 700 /mnt/swap
chattr +C /mnt/swap
btrfs filesystem mkswapfile --size 2g /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# The ESP mounts at /boot of the target: systemd-boot installs its
# loader there and kernel updates write new generations to it.
mount "$ESP_PART" /mnt/boot

# The disk phase is done; the system phase continues in the same process.
. "$(dirname "$(readlink -f "$0")")/install-system.sh"
