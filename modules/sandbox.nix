# Sandbox module of Spark.
# Network-facing and secret-bearing desktop applications are wrapped with
# nixpak: a bubblewrap sandbox with XDG portal permissions, similar to
# Flatpak but built natively from Nix packages.
{ config, pkgs, lib, nixpak, ... }:

{
  # An overlay swaps the real packages for the sandboxed builds everywhere
  # in the system configuration, so the app launcher starts sandboxes
  # transparently.
  nixpkgs.overlays = [
    # prev holds the package set BEFORE this overlay runs; building sandboxes
    # from prev breaks the recursion (building from pkgs/firefox would wrap
    # the overlay output in itself forever).
    (final: prev:
      let
        # Build a nixpak sandbox around a package with Spark's default policy:
        # no host filesystem access except portals, isolated network namespace
        # except for the applications that genuinely need the network.
        sandboxed = pkg: extraSloth: nixpak.lib.nixpak { inherit lib; pkgs = prev; } {
          config = { sloth, ... }: {
            app.package = pkg;
            app.binPath = "bin";
            # The sandbox gets its own D-Bus session filtered through
            # xdg-dbus-proxy; only the portal bus is reachable.
            dbus.policies."org.freedesktop.portal.*" = "talk";
            # Bubblewrap flags are extended per application.
            bubblewrap = {
              network = false;        # Offline by default; enabled per app below.
              shareIpc = true;        # Shared IPC namespace for Wayland clients.
              bind = {
                rw = [ ];             # No writable host mounts at all.
                ro = [ ];             # No direct read-only host mounts; portals only.
              };
            } // extraSloth sloth;
          };
        };
      in
      {
        # nixpak.lib.nixpak returns a lib.evalModules result: config.env is the
        # application package with the sandbox wrapper replacing its binary.
        # Browsers, mail and media players get network access; KeePassXC stays
        # offline so the password database never meets the network stack.
        firefox     = (sandboxed prev.firefox     (sloth: { network = true; })).config.env;
        thunderbird = (sandboxed prev.thunderbird (sloth: { network = true; })).config.env;
        vlc         = (sandboxed prev.vlc         (sloth: { network = true; })).config.env;
        keepassxc   = (sandboxed prev.keepassxc   (sloth: { })).config.env;
      })
  ];

  # XDG portals mediate every file open/save dialog so sandboxed apps never
  # touch host paths directly. The COSMIC portal (added by the COSMIC
  # desktop module) is the native implementation for the session; the GTK
  # portal stays as the fallback for sandboxed GTK applications.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "cosmic" "gtk" ];
  };

  # nixpak sandboxes are dbus-activated; the user bus must be available.
  services.dbus.implementation = "broker";
}
