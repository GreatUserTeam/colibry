#!/usr/bin/env bash
# Spark QEMU test runner.
#
# Boots the installer ISO or the installed system in a virtual machine
# and records everything the guest writes to its serial console (the
# system console of every Spark system) into a log file next to this
# script. The log is self-describing: a header with the exact ISO
# identity, the disk state and the host information is written into the
# file before the guest output starts, and every run appends to the
# rotated file instead of truncating it blindly.
#
# Boot flow (explicit, no guessing):
#   * Disk absent          -> a virtual disk is created and the machine
#                             boots from the ISO (installer flow).
#   * Disk present, no ISO -> the machine boots from the disk
#                             (installed-system flow).
#   * Disk present, ISO given -> the ISO wins and the installer runs
#                             again; it repartitions the whole disk.
#   * --clear              -> delete the virtual disk first, which
#                             returns the machine to the installer flow.
#
# Usage:
#   ./run.sh                        boot (create the disk on first use)
#   ./run.sh --iso result/iso/x.iso boot a specific ISO
#   ./run.sh --clear                wipe the disk, boot the installer
#   ./run.sh --clear --iso PATH     combine both
#   DISK_SIZE=64G ./run.sh --clear  recreate the disk with a custom size
#   MEMORY=8G SMP=8 ./run.sh        override RAM and CPU count
#   ./run.sh --headless           no graphical window (serial log only)
set -euo pipefail
cd "$(dirname "$0")"

# Default resources of the virtual machine. The installer sizes the system
# partition from the disk size and builds the installed closure during the
# installation, so both values must stay comfortably large.
DISK_SIZE="${DISK_SIZE:-128G}"
MEMORY="${MEMORY:-6G}"
SMP="${SMP:-4}"
DISK_IMG="spark-test-disk.qcow2"
LOG="spark.log"

CLEAR=0
HEADLESS=0
ISO=""

# Parse the flags and treat a bare argument as the ISO path so the common
# "./run.sh result/iso/*.iso" form keeps working.
while [ $# -gt 0 ]; do
  case "$1" in
    --clear)   CLEAR=1 ;;
    --headless) HEADLESS=1 ;;
    --iso)
      shift
      # An --iso flag without a usable path is a usage error; it is caught
      # here with an explicit message before the value is consumed anywhere.
      if [ $# -eq 0 ] || [ -z "$1" ]; then
        echo "error: --iso requires a path to an ISO image" >&2
        exit 2
      fi
      ISO=$1
      ;;
    *)         ISO=$1 ;;
  esac
  shift
done

# --clear restarts the machine from a blank disk, which is the only way
# back to the installer flow once a disk exists.
if [ "$CLEAR" -eq 1 ]; then
  rm -f "$DISK_IMG"
fi

# Resolve the ISO only when it is actually needed, so an installed-system
# boot never depends on (possibly stale) build artifacts.
if [ ! -f "$DISK_IMG" ] || [ -n "$ISO" ]; then
  if [ -z "$ISO" ]; then
    ISO=$(ls result/iso/*.iso 2>/dev/null | head -n 1 || true)
  fi
  if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "error: no bootable ISO found." >&2
    echo "build one (./build.sh) or pass --iso /path/to.iso" >&2
    exit 1
  fi
  BOOT_ORDER="d"
else
  BOOT_ORDER="c"
fi

# Create the virtual disk once; it persists between runs so the installed
# system survives a shutdown of the VM.
if [ ! -f "$DISK_IMG" ]; then
  qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null
  echo "disk:      $DISK_IMG (new, $DISK_SIZE)"
else
  echo "disk:      $DISK_IMG (existing)"
fi

# Hardware acceleration is used whenever the host exposes KVM; without it
# the guest runs on the TCG software emulator, which is slow but works on
# machines that cannot load the KVM module.
ACCEL_ARGS=(-enable-kvm -cpu host)
if [ ! -w /dev/kvm ]; then
  echo "warning: /dev/kvm is not writable; falling back to software emulation (slow)." >&2
  ACCEL_ARGS=(-cpu max)
fi

# Locate the OVMF UEFI firmware in the places where common hosts keep it.
OVMF=""
for path in \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    "$HOME/.nix-profile/share/qemu/OVMF_CODE.fd" \
    /run/libvirt/nix-ovmf/OVMF_CODE.fd
do
    if [ -f "$path" ]; then OVMF="$path"; break; fi
done
if [ -z "$OVMF" ]; then
  echo "error: OVMF firmware not found (install edk2-ovmf or the qemu OVMF package of your distribution)." >&2
  exit 1
fi

# A graphical window is the default so the Spark desktop can be inspected
# visually; --headless reduces the runner to the serial log for machines
# without a display server.
DISPLAY_ARGS=(-display gtk)
if [ "$HEADLESS" -eq 1 ]; then
  DISPLAY_ARGS=(-display none)
fi

# PipeWire audio is attached only when a running PipeWire server answers;
# otherwise the machine runs silently instead of failing to start on
# hosts without audio infrastructure.
AUDIO_ARGS=(-audiodev none,id=snd0)
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  AUDIO_ARGS=(-audiodev pipewire,id=snd0)
fi

# The CD-ROM drive exists only when an ISO is known: an installed-system
# boot has no optical drive at all, so the firmware can never pick it up.
CDROM_ARGS=()
if [ -n "$ISO" ]; then
  CDROM_ARGS=(-drive "file=${ISO},media=cdrom,readonly=on")
fi

# Keep the serial log of the previous boot next to the fresh one so two
# consecutive runs can be compared without any external tooling.
if [ -f "$LOG" ]; then
  mv -f "$LOG" "$LOG.prev"
fi

# The log header: everything needed to interpret the guest output below
# it - the exact image (with its hash), the machine state and the host.
# It is written before the VM starts; the serial chardev below opens the
# same file in append mode, so the guest output always follows the header.
{
  echo "# spark serial log"
  echo "# captured: $(date -Is)"
  echo "# host:     $(uname -srm)"
  echo "# qemu:     $(qemu-system-x86_64 --version | head -n 1)"
  if [ -n "$ISO" ]; then
    echo "# iso:      $ISO"
    echo "# iso size: $(stat -c %s "$ISO") bytes, mtime $(stat -c %y "$ISO")"
    echo "# iso sha256: $(sha256sum "$ISO" | cut -d' ' -f1)"
  fi
  echo "# disk:     $DISK_IMG ($DISK_SIZE, boot order $BOOT_ORDER)"
  echo "# guest output follows"
  echo
} >> "$LOG"

echo "boot order: $([ "$BOOT_ORDER" = d ] && echo "cdrom (installer)" || echo "disk (installed system)")"
echo "serial log: $LOG (previous boot: $LOG.prev)"
echo "follow it:  tail -f $LOG"

# The serial console of the guest (its system console) is mirrored to the
# log file. The chardev append mode (QEMU 7.1+) keeps the header written
# above and appends the guest output after it, so concurrent runs never
# destroy each other's record.
exec qemu-system-x86_64 \
    -name spark-test \
    "${ACCEL_ARGS[@]}" \
    -m "$MEMORY" -smp "$SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF}" \
    "${CDROM_ARGS[@]}" \
    -drive "file=${DISK_IMG},format=qcow2,if=virtio" \
    -boot "order=${BOOT_ORDER}" \
    -usb -device usb-tablet \
    "${DISPLAY_ARGS[@]}" \
    -chardev "file,id=ser0,path=${LOG},append=on" \
    -serial chardev:ser0 \
    "${AUDIO_ARGS[@]}" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0
