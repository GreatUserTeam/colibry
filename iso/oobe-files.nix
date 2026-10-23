# Wizard helper libraries of the Spark installer ISO.
#
# The OOBE session runs /etc/spark/oobe.sh (installed by the base ISO
# module), and that script sources the terminal and widget libraries
# below from /etc/spark. They ship as separate store files so that every
# source file of the project stays inside the line budget.
#
# Every library passes through parse-checking before it is allowed into
# the image: a library that bash cannot parse would leave the wizard
# without its widgets, and the failure would surface only inside the
# virtual machine. A syntax error here fails the ISO build with the
# parser message instead, which keeps broken scripts from ever reaching
# a boot.
{ pkgs, ... }:

let
  # parse-checked INSTALLABLE: runs bash in no-execute parse mode over
  # the source and only copies it through when the whole file parses.
  checked = name: src:
    pkgs.runCommand "spark-oobe-${name}-checked" {
      nativeBuildInputs = [ pkgs.bash ];
    } ''
      bash -n ${src}
      cp ${src} $out
    '';
in
{
  environment.etc."spark/spark-oobe-term.sh".source =
    checked "term" ../scripts/spark-oobe-term.sh;
  environment.etc."spark/spark-oobe-widgets.sh".source =
    checked "widgets" ../scripts/spark-oobe-widgets.sh;
}
