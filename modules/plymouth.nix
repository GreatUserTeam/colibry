# Plymouth module of Spark.
# The boot splash is a fully custom theme: a black screen, the Spark logo
# centered, and a thin progress bar at the bottom edge in place of boot
# messages. The artwork ships as SVG sources; the theme derivation renders
# them to PNG, because Plymouth loads PNG images only.
{ config, pkgs, lib, ... }:

let
  # The Spark Plymouth theme ships its script and the SVG artwork; the
  # descriptor is generated here. rsvg-convert (shipped in librsvg)
  # rasterizes the artwork to PNG during the build, so the runtime theme
  # directory contains only files Plymouth can load.
  sparkTheme = pkgs.runCommand "spark-plymouth-theme"
    { nativeBuildInputs = [ pkgs.librsvg ]; }
    ''
      themeDir=$out/share/plymouth/themes/spark
      mkdir -p $themeDir

      cp ${../assets/plymouth/spark/spark.script} $themeDir/spark.script
      rsvg-convert -w 256 ${../assets/plymouth/spark/logo.svg} -o $themeDir/logo.png
      rsvg-convert ${../assets/plymouth/spark/bar.svg}     -o $themeDir/bar.png
      rsvg-convert ${../assets/plymouth/spark/bar-dim.svg} -o $themeDir/bar-dim.png

      # Fill the ImageDir and ScriptFile placeholders with the path of this
      # very derivation. Plymouth resolves the descriptor paths literally,
      # and the NixOS Plymouth module rewrites store paths inside the
      # descriptor when it copies the theme into the initrd; a path outside
      # the store would survive the rewrite but would not exist at boot,
      # leaving Plymouth with no images and a plain gray screen.
      substitute ${../assets/plymouth/spark/spark.plymouth} $themeDir/spark.plymouth \
        --replace-fail @themeDir@ "$themeDir"
    '';
in
{
  # Plymouth draws the splash; the Spark theme replaces the default one.
  boot.plymouth = {
    enable = true;
    theme = "spark";
    themePackages = [ sparkTheme ];
  };
}
