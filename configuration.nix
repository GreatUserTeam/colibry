# Main system configuration of the Skein distribution.
# This file wires together all modules and defines the base system identity.
# Values that the installer collects in the OOBE wizard are defaults here
# and are overridden by the generated local.nix.
{ config, pkgs, lib, ... }:

let
  # One-shot boot probe: writes the exact kernel command line, the loaded
  # DRM modules, the DRM device nodes and every Plymouth/DRM journal line
  # of the current boot to the serial port. The installer image is
  # debugged through the serial log, and this probe is the single place
  # that answers why the graphical boot animation does or does not appear.
  bootDiagnostics = pkgs.writeShellScript "skein-boot-diagnostics" ''
    exec > /dev/ttyS0 2>&1
    echo "=== skein boot diagnostics: begin ==="
    echo "--- kernel command line:"
    cat /proc/cmdline
    echo "--- loaded drm/gpu modules:"
    lsmod | grep -iE 'virtio_gpu|bochs|vmwgfx|drm' || echo "(no drm module loaded)"
    echo "--- drm device nodes:"
    ls -l /dev/dri 2>&1 || true
    echo "--- plymouth/drm journal lines:"
    journalctl -b -o cat --no-pager | grep -iE 'plymouth|drm|virtio_gpu' | tail -n 40 || true
    echo "=== skein boot diagnostics: end ==="
  '';
in
{
  # The installer generates hardware-configuration.nix, installed-boot.nix
  # and local.nix next to this file on the installed system; during the ISO
  # build these files do not exist and the import lists stay empty.
  imports = lib.optionals (builtins.pathExists ./hardware-configuration.nix) [ ./hardware-configuration.nix ]
       ++ lib.optionals (builtins.pathExists ./installed-boot.nix) [ ./installed-boot.nix ]
       ++ lib.optionals (builtins.pathExists ./local.nix) [ ./local.nix ];

  # The distribution identifies itself as "skein".
  networking.hostName = lib.mkDefault "skein";

  # The desktop kernel. linux-zen carries the scheduling and latency
  # patches tuned for interactive desktop workloads (better input and
  # window responsiveness under load), while staying close to the
  # mainline kernel ABI, so every module and driver of the system keeps
  # working unchanged.
  boot.kernelPackages = pkgs.linuxPackages_zen;

  # The display driver modules must exist in the initrd, not only in the
  # final system: Plymouth starts inside the initrd, and without these
  # modules it finds no DRM device, silently falls back to the text
  # console and every status line becomes visible on the screen. The
  # list covers the virtual GPUs of common hypervisors (virtio-vga,
  # std-vga/bochs, vmware); on hardware without these devices the
  # modules find nothing and the native GPU driver takes over later in
  # the boot.
  boot.initrd.kernelModules = [ "virtio_gpu" "bochs" "vmwgfx" ];

  # Firmware, microcode and driver blobs carry unfree licenses (Broadcom,
  # Intel, Realtek, Apple, NVIDIA, ...). Skein ships them deliberately;
  # everything else stays free-only, so no random proprietary application
  # can enter the system.
  nixpkgs.config.allowUnfreePredicate = pkg:
    let name = lib.getName pkg;
    in lib.hasInfix "firmware" name
       || lib.hasInfix "ucode" name        # Intel and AMD microcode images.
       || lib.hasInfix "calibration" name  # facetimehd camera calibration data.
       || lib.hasInfix "-sta" name         # Broadcom wl driver.
       || lib.hasInfix "nvidia" name       # Proprietary NVIDIA driver stack.
       || lib.hasInfix "1password" name;   # 1Password (user-picked password manager).

  system.stateVersion = "24.11"; # Fixed for reproducibility of the first prototype.

  # Nix daemon hardening and quality-of-life settings.
  nix = {
    settings = {
      trusted-users = [ "root" ];
      auto-optimise-store = true;
      # The nix command and flakes are required by the update manager
      # of the installed system (modules/updates.nix) and by every
      # flake workflow a Skein user meets on the command line.
      experimental-features = [ "nix-command" "flakes" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # The human user account is created on the installed system by the homed
  # provisioning service (modules/encryption.nix) with an encrypted home;
  # it is intentionally not declared here. The password change at first
  # login is enforced by that service as well.

  # Silent boot of every Skein system, installed machines included. The
  # screen belongs to the boot animation and the wizard; the serial port
  # is the diagnostic channel. tty0 is a kernel console purely so the
  # framebuffer text console initializes and the wizard can paint the
  # screen; printk is gated to emergency level, so nothing from the kernel
  # reaches the display.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=tty0"
    "splash"
    "quiet"
    "loglevel=0"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_level=3"
    "vt.global_cursor_default=0"
  ];

  # The kernel printk console level: 0 forwards only emergency messages,
  # keeping even error-level kernel chatter off the screen.
  boot.consoleLogLevel = 0;

  # The serial port is the only diagnostic channel, and it is fed
  # directly: a dedicated service streams the live journal straight into
  # /dev/ttyS0, including the last 400 lines of the current boot, so the
  # early boot messages of every daemon (Plymouth included) are visible
  # even though they precede the service start. Journald's own console
  # forwarding is deliberately left off, because /dev/console fans writes
  # out to every registered console, which would put the full journal
  # (and every error in it) on the screen.
  systemd.services.skein-serial-journal = {
    description = "Mirror the boot journal to the serial debug port";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-journald.service" ];
    serviceConfig = {
      ExecStart = "/bin/sh -c 'exec ${pkgs.systemd}/bin/journalctl -f -n 400 -o short-precise > /dev/ttyS0'";
      Restart = "always";
      RestartSec = "1s";
    };
  };

  # Boot probe (see the let binding above): runs once per boot right
  # after the journal mirror starts and dumps the display-boot facts to
  # the serial port. It exists to make the graphical boot debuggable
  # from the serial log alone.
  systemd.services.skein-boot-diagnostics = {
    description = "Log boot display diagnostics to the serial debug port";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-journald.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${bootDiagnostics}";
    };
  };

  # Time, locale and console defaults; the OOBE wizard replaces them in
  # local.nix on installed systems.
  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = lib.mkDefault "us";
  };

  # All firmware (Wi-Fi, Bluetooth, cameras, microphones, ...) ships by default.
  hardware.enableAllFirmware = true;

  # Full hardware acceleration and media support ship by default.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  services.pulseaudio.enable = false; # PipeWire replaces PulseAudio entirely.

  # Skein root filesystems are btrfs (never ZFS); foreign ZFS pools are never
  # force-imported, which protects against accidental pool hijacks.
  boot.zfs.forceImportRoot = false;

  # Printing and scanning work out of the box.
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # The Nix build users of the live/installer profile sit above UID 1000;
  # user creation is driven by the Skein provisioning service, so the
  # systemd-userdb heuristic warning is acknowledged and silenced.
  services.userdbd.silenceHighSystemUsers = true;

  # The local dnsmasq resolver is the only DNS the system uses; NetworkManager
  # must not write DHCP-provided servers into resolv.conf.
  networking.networkmanager = {
    enable = true;
    dns = "none";
  };
  networking.useDHCP = lib.mkDefault true;
  # /etc/resolv.conf always points at the local dnsmasq stub.
  networking.nameservers = [ "127.0.0.1" ];
}
