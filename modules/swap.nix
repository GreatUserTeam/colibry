# Swap module of Colibry.
# Memory pressure is absorbed by a compressed zram device first, like the
# compressed memory of other desktop operating systems; a btrfs swap file
# grows on demand in 2 GiB steps when zram alone is not enough. The swap
# file never holds a hibernation image: when the installer enables
# hibernation, it creates a dedicated swap partition for that.
{ config, pkgs, lib, ... }:

{
  # zram: half of RAM as a zstd-compressed swap device. Typical compression
  # is 2x and more, so this adds real headroom without touching the disk.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100; # zram is always used before any disk swap file.
  };

  # With a nearly free zram device the kernel should hand pages over
  # eagerly; 100 is the recommended value for zram-backed swap.
  boot.kernel.sysctl."vm.swappiness" = 100;

  # Re-activates swap files created by earlier growth rounds at boot (the
  # base /swap/swapfile is activated by the fstab entry from the hardware
  # configuration).
  systemd.services.colibry-swap-activate = {
    description = "Activate additional Colibry swap files";
    wantedBy = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    path = [ pkgs.util-linux pkgs.coreutils ];
    script = ''
      [ -d /swap ] || exit 0
      for f in /swap/swapfile.*; do
        [ -f "$f" ] || continue
        if ! swapon --show=NAME --noheadings | grep -qx "$f"; then
          swapon -p 10 "$f" || true
        fi
      done
    '';
  };

  # Growth watchdog: once a minute, when total swap usage stays above 70%,
  # a fresh 2 GiB swap file is created and activated. Growth stops at 8
  # additional files and always leaves at least 4 GiB of filesystem space.
  systemd.services.colibry-swap-grow = {
    description = "Grow the btrfs swap files under memory pressure";
    after = [ "colibry-swap-activate.service" ];
    path = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils pkgs.gnugrep ];
    script = ''
      set -u
      [ -d /swap ] || exit 0

      # Total and used swap in kB from the kernel table.
      TOTAL=0; USED=0
      while read -r _ _ SIZE U _; do
        TOTAL=$((TOTAL + SIZE)); USED=$((USED + U))
      done < /proc/swaps
      [ "$TOTAL" -gt 0 ] || exit 0
      if [ $((USED * 100)) -lt $((TOTAL * 70)) ]; then exit 0; fi

      # Pick the next free swap file index.
      IDX=1
      while swapon --show=NAME --noheadings | grep -qx "/swap/swapfile.$IDX"; do
        IDX=$((IDX + 1))
      done
      [ "$IDX" -le 8 ] || exit 0

      # Refuse to eat the last bytes of the root filesystem.
      FREE_B=$(btrfs filesystem usage -b /swap | while read -r a b c _; do
        [ "$a $b" = "Free (estimated):" ] && echo "$c"
      done)
      [ -n "$FREE_B" ] || exit 0
      if [ "$FREE_B" -le $((4 * 1024 * 1024 * 1024)) ]; then exit 0; fi

      # btrfs mkswapfile creates a correctly sized NOCOW swap file.
      btrfs filesystem mkswapfile --size 2G "/swap/swapfile.$IDX" || exit 0
      chmod 600 "/swap/swapfile.$IDX"
      swapon -p 10 "/swap/swapfile.$IDX" || true
    '';
  };
  systemd.timers.colibry-swap-grow = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1min";
    };
  };
}
