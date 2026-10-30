# Plymouth boot splash of the Colibry distribution.
#
# This module assembles the Colibry splash theme from the sources in
# ../assets/plymouth/colibry/ and registers it as the boot splash of
# every Colibry system. For the entire boot the screen shows a black
# background with the white Colibry logo centered on it and nothing
# else: no firmware text, no console output and no status messages can
# bleed through, because Plymouth owns the framebuffer and the theme
# draws a full-screen black stage. Disk encryption passphrases are
# entered as pixel dots on the same stage.
{ config, pkgs, lib, ... }:

let
  # Theme sources: the splash script, the theme descriptor template and
  # the logo artwork. Everything the boot screen shows is defined by
  # these files alone.
  themeSrc = ../assets/plymouth/colibry;

  # The finished theme directory as Plymouth expects it:
  # share/plymouth/themes/colibry/ holding the descriptor, the script
  # and the rasterized logo. The SVG is rendered here, at image build
  # time, so the booted system carries only ready pixels.
  theme = pkgs.runCommand "colibry-plymouth-theme" {
    nativeBuildInputs = [ pkgs.librsvg ];
  } ''
    themeDir=$out/share/plymouth/themes/colibry
    mkdir -p "$themeDir"

    # Rasterize the logo at its natural size (256x256 white star).
    rsvg-convert ${themeSrc}/logo.svg -o "$themeDir/logo.png"

    install -m 0644 ${themeSrc}/colibry.script "$themeDir/colibry.script"

    # Bake the store path into the descriptor so Plymouth resolves the
    # artwork directory without any runtime search.
    sed "s|@themeDir@|$themeDir|g" ${themeSrc}/colibry.plymouth \
      > "$themeDir/colibry.plymouth"
  '';
in
{
  # The graphical splash on every boot; the theme package carries the
  # descriptor, so the script plugin resolves entirely from the Nix store.
  boot.plymouth = {
    enable = true;
    theme = "colibry";
    themePackages = [ theme ];
  };
}
