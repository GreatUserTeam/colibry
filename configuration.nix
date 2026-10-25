# Main system configuration of the Skein distribution.
# This file wires together all modules and defines the base system identity.
# Values that the installer collects in the OOBE wizard are defaults here
# and are overridden by the generated local.nix.
{ config, pkgs, lib, ... }:

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
  # machine's own screen stays silent until the greeter: splash activates
  # the Plymouth theme, quiet and the show_status pair keep every status
  # line off the screen, loglevel=3 and the udev log levels keep kernel
  # and udev chatter below warning level, vt.global_cursor_default=0 hides
  # the blinking cursor block.
  #
  # The FIRST console is the serial port: /dev/console (kernel messages,
  # emergency shells, everything journald forwards) goes to ttyS0 and
  # nowhere else. The screen is not a console at all. A machine without a
  # connected serial cable loses nothing - the writes are discarded by the
  # UART - while any supervisor (QEMU with "-serial file:", a serial
  # logger on real hardware) receives the complete boot log as a file on
  # the host. This is the error-tracing channel of the system.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "splash"
    "quiet"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_level=3"
    "vt.global_cursor_default=0"
  ];

  # The kernel printk console level: 3 shows warnings and errors only.
  boot.consoleLogLevel = 3;

  # journald forwards every log line to the system console, which is the
  # serial port (see boot.kernelParams): the full boot and runtime journal
  # is mirrored to whatever listens on the other end of the line, while
  # the on-disk journal in /var/log/journal remains the primary store.
  services.journald.settings.Journal = {
    ForwardToConsole = true;
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
