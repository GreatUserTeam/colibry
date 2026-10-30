# Live-session services of the Colibry installer image.
#
# The OOBE wizard is the display manager of the live session: it owns
# tty1 as a kiosk, there is no login prompt anywhere on the screen, and
# Plymouth stays alive until the wizard has drawn its first frame - the
# wizard writes its first frame into the console buffer while Plymouth
# still holds the display, then releases the splash itself, so the
# handover from the boot animation to the wizard renders no intermediate
# text. The wizard unit deliberately orders nothing behind Plymouth: the
# wizard is the component that releases the splash, so waiting for any
# Plymouth unit would be a deadlock once Plymouth holds a DRM device.
# The serial port remains the only diagnostic channel. When the wizard
# session dies before the installation finished, a bare root shell on
# tty2 replaces the splash as the last resort.
{ config, pkgs, lib, ... }:

{
  # The wizard session takes the role of the display manager; the greeter
  # of the installed system never starts inside the installer image.
  systemd.services.display-manager.enable = false;

  # Plymouth must not release the screen when the graphical target is
  # reached: the wizard quits the splash after painting its first frame
  # (see the frame() wrapper in oobe.sh), and re-arms it while the disk
  # installer runs. Keeping plymouth-quit inert is what makes both
  # handovers text-free.
  systemd.services.plymouth-quit.wantedBy = lib.mkForce [ ];

  # No login prompt may fight the wizard for a virtual terminal.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # The serial console stays the diagnostic channel, but it challenges
  # for a login like every other console: an autologin there would hand
  # an unauthenticated session of the maintenance account to anything
  # attached to the serial port. The empty first element resets the
  # ExecStart list; the second element is a plain agetty that always
  # asks for credentials.
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    serviceConfig.ExecStart = lib.mkForce [
      ""
      "${pkgs.util-linux}/sbin/agetty --login-program ${pkgs.shadow}/bin/login --keep-baud 115200,38400,9600 %I $TERM"
    ];
  };

  # The wizard session: owns tty1, restarts on unexpected exits, and
  # hands every failure to the rescue shell below. The entry point is
  # /etc/colibry/oobe.sh (installed and parse-checked by ./oobe-files.nix);
  # the sibling term/widgets files are libraries it sources, and the disk
  # installer it later runs lives at /etc/colibry/install.sh.
  systemd.services.colibry-oobe = {
    description = "Colibry OOBE installer session";
    documentation = [ "file:/etc/colibry/oobe.sh" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-user-sessions.service" ];
    conflicts = [ "display-manager.service" ];
    unitConfig.OnFailure = "colibry-oobe-fail.service";
    serviceConfig = {
      ExecStart = "/run/current-system/sw/bin/bash /etc/colibry/oobe.sh";
      TTYPath = "tty1";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = false;
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      UtmpIdentifier = "tty1";
      Restart = "always";
      RestartSec = "1s";
      TimeoutStopSec = "5s";
    };
  };

  # Last-resort rescue: releases the splash and drops to a root shell on
  # tty2. The leading dash ignores the failure of a Plymouth that has
  # already quit. The wizard creates /run/colibry-oobe.done at the end of
  # a successful installation, so this shell never covers a finished run.
  systemd.services.colibry-oobe-fail = {
    description = "Colibry OOBE rescue shell";
    unitConfig.ConditionPathExists = "!/run/colibry-oobe.done";
    serviceConfig = {
      ExecStartPre = "-${pkgs.plymouth}/bin/plymouth quit";
      ExecStart = "/run/current-system/sw/bin/bash";
      TTYPath = "tty2";
      TTYReset = true;
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      UtmpIdentifier = "tty2";
    };
  };

  # Debug builds only: a booted system with the kernel command line
  # "colibry.debug" mirrors the full journal onto tty1 behind the wizard.
  systemd.services.colibry-oobe-journal-mirror = {
    description = "Mirror the boot journal onto tty1 (debug builds only)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionKernelCommandLine = "colibry.debug";
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/bin/journalctl -f -o cat";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "tty1";
      TTYReset = false;
      TTYVHangup = false;
    };
  };
}
