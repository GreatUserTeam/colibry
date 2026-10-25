# Night light module of Skein.
# The screen color temperature follows the sun: warm after sunset, neutral
# during the day. The user never has to think about it.
{ config, pkgs, lib, ... }:

let
  # Schedule parameters are declared here and passed to wlsunset as flags.
  dayTemp       = 6500;    # Neutral daylight temperature in Kelvin.
  nightTemp     = 3500;    # Warm candle-like temperature after sunset in Kelvin.
  transitionSec = 3600;    # The day/night transition stretches over one hour.
  latitude      = 55.75;   # Geographic latitude used to compute sunrise/sunset.
  longitude     = 37.62;   # Geographic longitude; the installer sets the region.
in
{
  # The night light binary ships with the system.
  environment.systemPackages = [ pkgs.wlsunset ];

  # A user service runs wlsunset inside the graphical session and restarts
  # it automatically when it crashes.
  systemd.user.services.wlsunset = {
    description = "Night light screen color temperature manager";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      # wlsunset drives wlr-gamma-control-unstable-v1, which Hyprland
      # implements natively; flags carry the whole schedule.
      ExecStart = ''
        ${pkgs.wlsunset}/bin/wlsunset \
          -t ${toString dayTemp} \
          -T ${toString nightTemp} \
          -d ${toString transitionSec} \
          -l ${toString latitude} \
          -L ${toString longitude}
      '';
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
