# Desktop module of Skein.
# Session: COSMIC on Wayland. COSMIC is a Rust desktop environment
# (compositor, dock, panel, applets, settings) that is driven entirely by
# mouse and touch, and it ships its own file manager, text editor,
# terminal and store, so the system carries no GNOME or KDE utilities at
# all. COSMIC is the interim desktop of Skein and gives way to the custom
# shell of the distribution later.
{ config, pkgs, lib, ... }:

let
  # The Skein wallpaper is installed into the standard backgrounds
  # directory; the path inside the system profile is stable across
  # rebuilds, so references to it never break.
  skeinWallpaper = pkgs.runCommand "skein-wallpaper" { } ''
    mkdir -p $out/share/backgrounds/skein
    cp ${../assets/wallpaper.jpg} $out/share/backgrounds/skein/wallpaper.jpg
  '';
in
{
  # COSMIC is the desktop environment of the session. The COSMIC module
  # provides the session package, the compositor, the applets, the
  # settings application and the COSMIC portal.
  services.desktopManager.cosmic.enable = true;

  # The X stack is brought up so XWayland serves legacy X11 applications
  # inside the COSMIC session.
  services.xserver.enable = true;

  # greetd (modules/greeter.nix) is the only display manager on the
  # system; GDM stays disabled so the session starts from the greeter.
  services.displayManager.gdm.enable = false;

  # COSMIC Store duplicates the curated app store of Skein (Nix Software
  # Center) and is the only COSMIC application excluded from the session.
  environment.cosmic.excludePackages = [ pkgs.cosmic-store ];

  # The Skein wallpaper is installed system-wide.
  environment.systemPackages = [ skeinWallpaper ];

  # First-boot defaults for every account created after this profile is
  # installed: both systemd-homed and useradd seed a new home directory
  # from /etc/skel, so a file dropped into /etc/skel lands in every new
  # Skein home exactly once, at creation time.

  # Wallpaper entry of cosmic-bg, read from the per-output key "all".
  # The RON struct below carries exactly the fields cosmic-bg accepts;
  # the image path points into the system profile so the wallpaper
  # survives every rebuild of the system.
  environment.etc."skel/.config/cosmic/com.system76.CosmicBackground/v1/all".text = ''
    (
        output: "all",
        source: Path("/run/current-system/sw/share/backgrounds/skein/wallpaper.jpg"),
        filter_by_theme: false,
        rotation_frequency: 86400,
        filter_method: Lanczos,
        scaling_mode: Zoom,
        sampling_method: Alphanumeric,
    )
  '';

  # Idle power policy of cosmic-idle, stored in RON option syntax:
  # the displays blank after five idle minutes, the machine suspends
  # after twenty minutes on battery power, and it never suspends on AC
  # power. Waking from suspend always re-authenticates through the
  # greeter, so a parked machine re-locks itself.
  environment.etc."skel/.config/cosmic/com.system76.CosmicIdle/v1/screen_off_time".text = "Some(300000)";
  environment.etc."skel/.config/cosmic/com.system76.CosmicIdle/v1/suspend_on_battery_time".text = "Some(1200000)";
  environment.etc."skel/.config/cosmic/com.system76.CosmicIdle/v1/suspend_on_ac_time".text = "None";

  # Session lock driven by the compositor-agnostic idle protocol: after
  # five idle minutes the session manager is asked to lock, and the
  # compositor answers with its own lock screen. Screen blanking and
  # suspend stay with cosmic-idle; this service owns only the lock.
  systemd.user.services.skein-idle-lock = {
    description = "Lock the session after five idle minutes";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStart = toString (pkgs.writeShellScript "skein-idle-lock" ''
        exec ${pkgs.swayidle}/bin/swayidle -w \
          timeout 300 '${pkgs.systemd}/bin/loginctl lock-session "''${XDG_SESSION_ID}"'
      '');
    };
  };
}
