# Greeter module of Spark.
# The display manager is greetd running wlgreet inside the kiosk
# compositor cage. The greeter carries the Spark identity: dark
# background, centered prompt and a single password field. No user list
# is shown anywhere. After authentication greetd starts the COSMIC
# session directly.
{ config, pkgs, lib, ... }:

{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        # The greeter runs as an unprivileged system user.
        user = "greeter";
        # cage is a kiosk Wayland compositor; wlgreet draws the login UI
        # on it. The session type variables are set explicitly because
        # greetd, unlike a full display manager, does not provide them,
        # and cosmic-session requires them to start the compositor on
        # Wayland.
        command = ''
          ${pkgs.cage}/bin/cage -s -- \
            ${pkgs.wlgreet}/bin/wlgreet \
              --command 'env XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=cosmic XDG_CURRENT_DESKTOP=COSMIC ${pkgs.cosmic-session}/bin/cosmic-session' \
              --style /etc/spark/wlgreet.css
        '';
      };
    };
  };

  # The greeter user exists only to host the greeter session; it owns no
  # files and cannot log in interactively.
  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
    extraGroups = [ "video" "input" "render" ];
  };
  users.groups.greeter = { };

  # The Spark stylesheet for wlgreet is installed system-wide.
  environment.etc."spark/wlgreet.css".source = ../assets/wlgreet.css;
}
