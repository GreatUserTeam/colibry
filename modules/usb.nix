# USB removable media module of Spark.
# A single policy governs every USB storage device, whether it was plugged
# in before power-on or hot-plugged later: mount read-only + noexec, scan
# it with ClamAV, notify the user on detection, and unmount it after ten
# idle minutes. udev drives the whole flow, so there is no polling script
# and boot-time devices (udev event replay) go through the same path.
{ config, pkgs, lib, ... }:

let
  # Notifies the human user over the session D-Bus; used for USB events.
  notifyUser = pkgs.writeShellScript "spark-notify-user" ''
    MSG="''${1:?notification text}"
    USER="sparkuser"
    UID_=$(${pkgs.coreutils}/bin/id -u "$USER" 2>/dev/null) || exit 0
    BUS="/run/user/$UID_/bus"
    [ -S "$BUS" ] || exit 0
    ${pkgs.util-linux}/bin/runuser -u "$USER" -- \
      env DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS" \
          XDG_RUNTIME_DIR="/run/user/$UID_" \
      ${pkgs.libnotify}/bin/notify-send -u critical "Spark USB guard" "$MSG" || true
  '';

  # Policy mount: read-only, noexec, nosuid, nodev; then a background
  # ClamAV scan decides whether the device may stay.
  sparkUsbMount = pkgs.writeShellScript "spark-usb-mount" ''
    set -u
    DEV="''${1:?kernel device name required}"   # e.g. sda1
    [ -b "/dev/$DEV" ] || exit 0

    FSTYPE=$(${pkgs.util-linux}/bin/blkid -o value -s TYPE "/dev/$DEV" 2>/dev/null || true)
    [ -n "$FSTYPE" ] || exit 0                  # No filesystem: nothing to mount.

    # A device mounted already (udev replay, duplicate event) is done.
    if ${pkgs.util-linux}/bin/findmnt -rn -S "/dev/$DEV" | ${pkgs.gnugrep}/bin/grep -q .; then
      exit 0
    fi

    LABEL=$(${pkgs.util-linux}/bin/blkid -o value -s LABEL "/dev/$DEV" 2>/dev/null || true)
    LABEL="''${LABEL:-usb-$DEV}"
    LABEL=$(echo "$LABEL" | ${pkgs.coreutils}/bin/tr -cd '[:alnum:]-_')
    MNT="/media/$LABEL"
    # A different device already owns this mount point: take a suffixed one.
    BASE="$MNT"; N=2
    while ${pkgs.util-linux}/bin/findmnt -rn "$MNT" | ${pkgs.gnugrep}/bin/grep -q .; do
      MNT="$BASE-$N"; N=$((N + 1))
    done

    ${pkgs.coreutils}/bin/mkdir -p "$MNT" /run/spark-usb
    # The policy mount options: no writes, no execution, no suid, no devices.
    if ! ${pkgs.util-linux}/bin/mount -o ro,noexec,nosuid,nodev "/dev/$DEV" "$MNT" 2>/dev/null; then
      ${notifyUser} "USB device $DEV could not be mounted."
      exit 0
    fi
    ${pkgs.coreutils}/bin/touch "/run/spark-usb/$(basename "$MNT").stamp"
    ${notifyUser} "USB device mounted read-only at $MNT. Scanning..."

    # The background scan removes an infected mount; exit code 2 means the
    # scan could not run (e.g. clamd not up yet) and the device stays
    # mounted under the read-only + noexec policy.
    (
      if ${pkgs.clamav}/bin/clamdscan --quiet --no-summary "$MNT" 2>/dev/null; then
        ${notifyUser} "USB device $MNT is clean."
      else
        rc=$?
        if [ "$rc" -eq 1 ]; then
          ${pkgs.util-linux}/bin/umount "$MNT" 2>/dev/null || true
          ${notifyUser} "THREAT FOUND on $MNT - the device was unmounted."
        fi
      fi
    ) &
  '';

  # Reverses the policy mount; run when the device disappears or idles out.
  sparkUsbUnmount = pkgs.writeShellScript "spark-usb-unmount" ''
    set -u
    DEV="''${1:?kernel device name required}"
    MNT=$(${pkgs.util-linux}/bin/findmnt -rn -S "/dev/$DEV" -o TARGET | ${pkgs.coreutils}/bin/head -n1)
    [ -n "$MNT" ] || exit 0
    ${pkgs.util-linux}/bin/umount "$MNT" 2>/dev/null || \
      ${pkgs.util-linux}/bin/umount -l "$MNT" 2>/dev/null || true
    ${pkgs.coreutils}/bin/rm -f "/run/spark-usb/$(basename "$MNT").stamp"
  '';

  # Unmounts every policy mount that has had no open files for 10 minutes.
  sparkUsbIdle = pkgs.writeShellScript "spark-usb-idle-unmount" ''
    for stamp in /run/spark-usb/*.stamp; do
      [ -e "$stamp" ] || continue
      MNT="/media/$(basename "$stamp" .stamp)"
      # Device already gone: drop the stale stamp.
      if ! ${pkgs.util-linux}/bin/findmnt -rn "$MNT" | ${pkgs.gnugrep}/bin/grep -q .; then
        ${pkgs.coreutils}/bin/rm -f "$stamp"
        continue
      fi
      # An open file (copy in progress, active scan) resets the idle clock.
      if ${pkgs.psmisc}/bin/fuser -m "$MNT" >/dev/null 2>&1; then
        ${pkgs.coreutils}/bin/touch "$stamp"
        continue
      fi
      now=$(${pkgs.coreutils}/bin/date +%s)
      at=$(${pkgs.coreutils}/bin/stat -c %Y "$stamp")
      if [ $((now - at)) -gt 600 ]; then
        ${pkgs.util-linux}/bin/umount "$MNT" 2>/dev/null || \
          ${pkgs.util-linux}/bin/umount -l "$MNT" 2>/dev/null || true
        ${pkgs.coreutils}/bin/rm -f "$stamp"
      fi
    done
    exit 0
  '';
in
{
  # UDisks2 stays active: the file manager lists devices and offers
  # "Safely Remove". COSMIC Files performs no automounting, so udisks2 by
  # itself never mounts a device; the only automatic mounts on the system
  # are the Spark policy mounts below, which always carry the security
  # options.
  services.udisks2 = {
    enable = true;
    mountOnMedia = true; # udisks mounts (if any) go under /media/<label>.
  };
  services.dbus.packages = [ pkgs.udisks2 ];

  # udev asks systemd to start the policy mount for every removable USB
  # filesystem, both for partitions and for superfloppy-style whole disks.
  # Devices present at boot are caught by the udev event replay, so the
  # cold path and the hot path are identical. The rules travel through
  # services.udev.extraRules because the udev module owns the merged
  # rules directory and individual files cannot be added next to it.
  # In paranoid USB mode (spark.usbParanoid = true) nothing mounts
  # automatically and these rules are not installed at all.
  services.udev.extraRules = lib.mkIf (!config.spark.usbParanoid) ''
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}="spark-usb-mount@%k.service"
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="disk", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}="spark-usb-mount@%k.service"
  '';

  # The per-device mount unit: bound to the device node, it unmounts the
  # filesystem automatically the moment the stick is pulled out.
  systemd.services."spark-usb-mount@" = {
    description = "Spark policy mount of USB device %I";
    after = [ "dev-%i.device" ];
    unitConfig.BindsTo = "dev-%i.device";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${sparkUsbMount} %i";
      ExecStop = "${sparkUsbUnmount} %i";
    };
  };

  # The idle watchdog: every minute it unmounts devices that had no open
  # file for ten consecutive minutes.
  systemd.services.spark-usb-idle-unmount = {
    description = "Unmount idle USB policy mounts";
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecStart = "${sparkUsbIdle}";
  };
  systemd.timers.spark-usb-idle-unmount = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
    };
  };

  # NTFS and exFAT filesystems mount without extra user action.
  boot.supportedFilesystems = [ "ntfs" "exfat" ];

  # The tools the policy scripts rely on are present on the system.
  environment.systemPackages = [ pkgs.libnotify pkgs.psmisc ];
}
