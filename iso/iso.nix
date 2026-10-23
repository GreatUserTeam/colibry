# ISO image module of Spark.
# This file turns the Spark system into the bootable installer image.
# The image boots straight into the Spark boot splash and from there into
# the OOBE wizard: neither boot loader shows a menu, no log output ever
# reaches the screen, and no login terminal exists anywhere on the
# system. The full journal is mirrored to the serial console (the
# error-tracing channel, see configuration.nix) and the journal mirror on
# tty1 exists only in spark.debug builds.
{ config, pkgs, lib, modulesPath, ... }:

let
  # The boot loader background of both boot paths is a plain black screen.
  # It is rendered at build time from an inline SVG, so the image carries
  # no binary artwork asset and no upstream boot artwork is ever visible
  # behind a loader menu. librsvg is already in the build closure, so
  # rendering adds no new dependency.
  blackBackgroundSvg = pkgs.writeText "spark-black-background.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080"><rect width="1920" height="1080" fill="#000000"/></svg>
  '';
  blackBackground = pkgs.runCommand "spark-black-background" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    rsvg-convert ${blackBackgroundSvg} -o $out
  '';
in
{
  # The graphical installation CD base provides the live session skeleton
  # (hybrid BIOS/UEFI boot loader, squashfs image, installer tools).
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-graphical-base.nix" ];

  # The installer image must install the distro flake with its lock file:
  # the installed system builds against the exact inputs pinned in
  # flake.lock, all of which are already present in the live store. A
  # missing lock file turns the installation into a floating network
  # fetch of every flake input and fails on machines without a working
  # network at install time.
  #
  # The check runs in the Nix pure-evaluation mode of `nix build`, which
  # only sees git-tracked files inside a git worktree: an untracked
  # flake.lock fails this assertion even though it exists on disk, so
  # the message names the git index requirement explicitly.
  assertions = [
    {
      assertion = builtins.pathExists ../flake.lock;
      message = "flake.lock must exist next to flake.nix AND be tracked by git: `nix build` evaluates in pure mode and sees only tracked files; run `git add flake.lock`. The installer copies the distro flake to the target disk and builds it against the pinned inputs of the live store.";
    }
  ];

  # The live session overrides the installed system's hostname.
  networking.hostName = lib.mkForce "spark-live";

  # The live session boots through the same Spark Plymouth splash as the
  # installed system (modules/plymouth.nix); only the handover from the
  # splash to the wizard differs: plymouth-quit yields the console to the
  # OOBE session on tty1.
  boot.plymouth.enable = lib.mkForce true;

  # The complete silent-boot command line, forced as a whole. Both boot
  # loaders embed exactly this list into their kernel command line. The
  # screen stays silent (splash paints the Spark theme, quiet, the
  # show_status pair, loglevel=3, the udev levels, hidden cursor); the
  # FIRST console is the serial port, so the whole boot journal of the
  # live session is traceable from the host the machine runs on.
  boot.kernelParams = lib.mkForce [
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

  # The kernel printk console level for both consoles: 3 shows warnings and
  # errors only, so nothing interrupts the splash before the wizard.
  boot.consoleLogLevel = 3;

  isoImage = {
    volumeID = "SPARK";
    makeEfiBootable = true;  # UEFI systems boot from the stick.
    makeUsbBootable = true;  # Legacy BIOS systems boot from the stick as well.
    squashfsCompression = "zstd -Xcompression-level 19"; # Smaller image, faster decompression.

    # The splash images of both boot paths are the rendered black
    # background: the ISOLINUX BIOS path shows it behind the (hidden) menu,
    # and the UEFI GRUB path shows it when no GRUB theme is configured.
    splashImage = blackBackground;    # BIOS (ISOLINUX) background.
    efiSplashImage = blackBackground; # UEFI (GRUB) background.

    # The ISO builder normally draws the NixOS GRUB theme on the UEFI boot
    # path; a null theme leaves only the black splash image behind.
    grubTheme = null;

    # A firmware whose language is not English passes that language to
    # GRUB, and GRUB then looks up its message catalog on the ISO; the
    # catalog for the one language this was observed with (Russian) is
    # shipped at the exact path GRUB searches, so the lookup succeeds and
    # the "error: file not found" line never reaches the screen. English
    # needs no catalog at all: it is compiled into the GRUB binary and the
    # grub package ships no en/ locale directory, so an en entry would
    # reference a store path that does not exist and abort the ISO build.
    contents = [
      {
        source = "${pkgs.grub2}/share/locale/ru/LC_MESSAGES/grub.mo";
        target = "/boot/grub/locale/ru.gmo";
      }
    ];

    # The ISOLINUX menu is never shown. The ISO module assembles
    # isolinux.cfg from a fixed template: it emits SERIAL and TIMEOUT lines
    # first, then inserts this theme text verbatim, then the DEFAULT and
    # LABEL entries. ISOLINUX processes the configuration top to bottom,
    # so the directives below override the earlier ones:
    #   * TIMEOUT 10 replaces the timeout derived from boot.loader.timeout
    #     (which is 0 for this image: instant and menu-less on the UEFI GRUB
    #     path, but on the BIOS vesamenu path a zero timeout would wait
    #     forever at an invisible prompt). One second is short enough to be
    #     unnoticed and long enough for the automatic boot to fire reliably.
    #   * MENU HIDDEN skips the menu completely and boots the DEFAULT entry
    #     after that timeout. Pressing any key during the one-second window
    #     reveals the menu for rescue boots.
    # The MENU COLOR lines re-skin the revealed menu with the Spark colors
    # (black background, light text) instead of the upstream color scheme.
    syslinuxTheme = lib.mkForce ''
      TIMEOUT 10
      MENU HIDDEN

      MENU COLOR SCREEN       37;40      #FF000000    #FF000000   none
      MENU COLOR BORDER       30;44      #00000000    #00000000   none
      MENU COLOR TITLE        1;36;44    #FFFFFFFF    #FF000000   none
      MENU COLOR UNSEL        37;44      #FFFFFFFF    #FF000000   none
      MENU COLOR SEL          7;37;40    #FF000000    #FFFFFFFF   std
      MENU COLOR TABMSG       31;40      #80000000    #FF000000   none
      MENU COLOR TIMEOUT      1;37;40    #FF000000    #FF000000   none
      MENU COLOR TIMEOUT_MSG  37;40      #FF000000    #FF000000   none
      MENU COLOR CMDMARK      1;36;40    #FF000000    #FF000000   none
      MENU COLOR CMDLINE      37;40      #FF000000    #FF000000   none
      MENU COLOR HELP         37;40      #FF000000    #FF000000   none
      MENU COLOR HELPTEXT     37;40      #FF000000    #FF000000   none
    '';
  };

  # The output file keeps the distro name and the NixOS version.
  image.fileName = "spark-${config.system.nixos.version}.iso";

  # Zero is perfect for the UEFI path (GRUB boots its default entry
  # immediately without drawing a menu) and is kept for the BIOS path as
  # well: the ISOLINUX-specific TIMEOUT in syslinuxTheme above overrides it
  # to one second before vesamenu would wait on it.
  boot.loader.timeout = lib.mkForce 0;

  # The X server module enables LightDM by default whenever no other
  # display manager is active - the kiosk must not have any display
  # manager at all, so LightDM is switched off explicitly.
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;

  # No automatic login anywhere on the installer. The installation CD base
  # enables getty autologin for its demo account; on Spark the serial
  # console is a debugging channel and must ask for a login like every
  # other terminal.
  services.getty.autologinUser = lib.mkForce null;

  # The Xen guest tools ship in the installation CD base for Xen hosts. On
  # any other hypervisor the daemon dies immediately; the condition keeps
  # the units inert instead of failing during the silent boot.
  systemd.services.xe-daemon.unitConfig.ConditionVirtualization = "xen";
  systemd.services.xe-linux-distribution.unitConfig.ConditionVirtualization = "xen";

  # The live session uses a classic local account with an empty password;
  # encrypted systemd-homed accounts exist only on installed systems. The
  # account exists so files inside the live system have an owner; the OOBE
  # session itself runs as root.
  users.users.sparkuser = {
    isNormalUser = true;
    description = "Spark User";
    extraGroups = [ "networkmanager" "video" "audio" "input" "wheel" ];
    password = "";
    shell = pkgs.zsh;
  };

  # No greeter and no desktop session in the installer: the OOBE wizard is
  # the only interactive surface.
  services.greetd.enable = lib.mkForce false;

  # No login terminals anywhere on the installer. The getty@ template
  # supplies the fixed consoles and the autovt@ template supplies consoles
  # auto-spawned by logind when a virtual terminal is switched to
  # (Ctrl+Alt+F2 and friends); with both templates off there is no shell to
  # fall into, and tty1 belongs to the OOBE wizard alone. The serial getty
  # instantiated by systemd-getty-generator from the console= kernel
  # parameter is the debug channel and stays available.
  systemd.services."getty@".enable = false;
  systemd.services."autovt@".enable = false;

  # Debug surface, gated behind the spark.debug kernel parameter: the
  # on-screen boot journal mirror. A normal boot has nothing extra: nothing
  # is ever printed for the user.
  systemd.services.spark-boot-console = {
    description = "Mirror the boot journal onto tty1 (debug builds only)";
    wantedBy = [ "sysinit.target" ];
    unitConfig.ConditionKernelCommandLine = "spark.debug";
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      StandardInput = "null";
      TTYPath = "/dev/tty1";
      StandardOutput = "tty";
      StandardError = "tty";
      ExecStart = "${pkgs.systemd}/bin/journalctl -f -b -p info --no-pager -o short-precise";
    };
  };

  # The OOBE session on tty1. The service mirrors the proven getty wiring:
  # TTYPath plus StandardInput=tty makes systemd provide /dev/tty1 as the
  # controlling terminal of the script, so every interactive tool has a
  # real /dev/tty. The script is invoked through bash explicitly: files
  # from the Nix store carry no executable bit, so executing the script by
  # path would fail with a permission error.
  #
  # Ordering: the unit starts strictly AFTER plymouth-quit.service. The
  # wizard draws on tty1, and Plymouth holds tty1 in graphics mode until it
  # quits; starting earlier means drawing into a framebuffer-owned terminal
  # whose reads and writes fail, which both kills the wizard and wedges the
  # console (every later ioctl on the terminal then returns EIO).
  #
  # Diagnostics: StandardError goes to the journal instead of the terminal.
  # The wizard's own screen drawing uses descriptor 3 and stays on tty1, but
  # interpreter error messages and the wizard's stderr markers travel
  # through journald, which mirrors every line to the serial console - so
  # the exact failure is visible in the host-side boot log after every run,
  # with no interaction needed inside the guest.
  #
  # Restarting: the done-marker condition prevents any restart of the
  # wizard once the installation has started; the unit restarts in two
  # seconds if the wizard dies before that, and it resumes at the last
  # finished step. Only the terminal reset travels with the restart: the
  # hangup and VT deallocation options are deliberately omitted, because
  # cycling them on a restarting service is what wedges the console.
  systemd.services.spark-oobe = {
    description = "Spark OOBE installer session";
    wantedBy = [ "multi-user.target" ];
    wants = [ "plymouth-quit.service" ];
    after = [ "plymouth-quit.service" ];
    unitConfig.ConditionPathExists = "!/etc/spark/oobe-done";
    # If the session crashes, the failure surface unit below paints the
    # error on tty1 instead of leaving a silent black screen.
    unitConfig.OnFailure = "spark-oobe-fail.service";
    # The wizard calls timedatectl, lsblk and the core file tools by name;
    # they are added to the unit PATH because a TTY service has no login
    # shell profile. The installer script itself re-exports the full system
    # profile PATH before calling the disk tools.
    path = with pkgs; [
      bash
      systemd
      util-linux
      gnugrep
      gnused
      gawk
      coreutils
    ];
    serviceConfig = {
      Type = "idle";
      # A bare TTY service has no terminal environment; TERM and LANG are
      # set explicitly so the frames and UTF-8 labels render correctly.
      Environment = [ "TERM=linux" "LANG=C.UTF-8" "HOME=/root" ];
      TTYPath = "/dev/tty1";
      TTYReset = true; # The terminal is reset before every (re)start.
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      ExecStart = "${pkgs.bash}/bin/bash /etc/spark/oobe.sh";
      Restart = "always";
      RestartSec = "2";
    };
  };

  # Crash surface for the OOBE session. With Restart=always a dying wizard
  # would otherwise loop invisibly; this unit runs once per transition into
  # the failed state. It paints the tail of the wizard trace log onto tty1
  # (the screen the wizard owns) and mirrors the same tail to stderr, which
  # goes to the journal and from there to the serial console - so a broken
  # session leaves readable evidence both on the screen and in the
  # host-side boot log.
  systemd.services.spark-oobe-fail = {
    description = "Surface OOBE session failures on tty1";
    serviceConfig = {
      Type = "oneshot";
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      Environment = [ "TERM=linux" "LANG=C.UTF-8" ];
      ExecStart = toString (pkgs.writeShellScript "spark-oobe-fail" ''
        printf '\033[2J\033[H'
        printf 'The Spark installer session crashed and will retry.\n\n'
        printf -- '--- /var/log/spark-oobe.log (command trace) ---\n'
        tail -n 30 /var/log/spark-oobe.log 2>/dev/null
        printf -- '\n--- journal (spark-oobe) ---\n'
        journalctl -u spark-oobe -n 30 --no-pager 2>/dev/null
        printf '\nRetrying in a few seconds...\n'
        # The same trace tail goes to stderr: the unit sends it to the
        # journal, and journald mirrors it to the serial console.
        {
          printf -- '--- spark-oobe trace tail ---\n'
          tail -n 30 /var/log/spark-oobe.log 2>/dev/null
          printf -- '--- end of trace tail ---\n'
        } >&2
      '');
    };
  };

  # The AIDE database builder belongs to installed systems. On the
  # throwaway live session there is nothing to attest and the unit would
  # only print a [FAILED] line during the silent boot.
  systemd.services.spark-aide-init.enable = false;

  # The OOBE wizard and the disk installer ship inside the live system.
  environment.etc."spark/oobe.sh".source = ../scripts/spark-oobe.sh;
  environment.etc."spark/install.sh".source = ../scripts/install-to-disk.sh;

  # The list of UTF-8 locales is baked into the image at build time:
  # reading it at runtime would need LOCALE_ARCHIVE, which a bare TTY service
  # does not have. glibcLocales carries the full archive.
  environment.etc."spark/locales".source = pkgs.runCommand "spark-locale-list" { } ''
    LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive \
      ${pkgs.glibc.bin}/bin/locale -a \
      | grep -iE 'utf-?8$' | sort > $out
  '';

  # The list of console keyboard layouts is baked into the image at build
  # time as well: the layouts ship inside the kbd package in the Nix
  # store, and the localectl tool cannot enumerate them there - it only
  # reads the /usr/share/kbd directory, which does not exist on a NixOS
  # system. The wizard reads this file instead of calling localectl. Every
  # *.map.gz under the keymaps directory becomes one entry named like the
  # console keyMap values of the installed system ("us", "ru", "de-latin1", ...).
  environment.etc."spark/keymaps".source = pkgs.runCommand "spark-keymap-list" { } ''
    find ${pkgs.kbd}/share/keymaps -type f -name '*.map.gz' \
      | sed 's|.*/||; s|\.map\.gz$||' \
      | sort -u > $out
  '';

  # The full distro flake ships inside the live system; the installer copies
  # it to the target disk and substitutes machine-specific values into the
  # copy. Build-time junk never ships: the filter drops test disks, the
  # result symlink and VCS metadata. The flake.lock ships with the flake
  # and pins every input (see the assertion above).
  environment.etc."spark/flake".source = lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let base = baseNameOf path;
      in !(lib.hasSuffix ".qcow2" base || base == "result" || base == ".git");
  };

  # Every disk tool the installer shells out to, kept in the system profile
  # so the installer finds them on PATH no matter which unit PATH it is
  # started with. btrfs-progs and e2fsprogs cover mkfs.btrfs and chattr,
  # which the base installer profile does not guarantee.
  environment.systemPackages = [
    pkgs.parted
    pkgs.cryptsetup
    pkgs.dosfstools
    pkgs.btrfs-progs
    pkgs.e2fsprogs
    (pkgs.writeShellScriptBin "spark-install" ''
      # The wrapper runs the installer with root privileges from the live session.
      exec sudo bash /etc/spark/install.sh "$@"
    '')
  ];

  # The live system still runs the full firewall; no extra ports are opened.
  system.stateVersion = "24.11";
}
