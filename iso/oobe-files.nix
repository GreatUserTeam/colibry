# OOBE wizard files of the installer image.
#
# The wizard session (./oobe-session.nix) runs /etc/skein/oobe.sh, and
# the wizard later invokes the disk installer as /etc/skein/install.sh.
# Both scripts, plus the two UI libraries they source, are baked into the
# image here. Every script is parse-checked at image build time: a script
# corrupted in transfer fails the build with the file name instead of
# dying silently inside the virtual machine.
{ config, pkgs, lib, ... }:

let
  # checkedScript NAME TEXT: parses the script with bash -n during the
  # image build and installs the text at /etc/skein/NAME. A syntax
  # error aborts the build; the parse check costs milliseconds here and
  # saves a half-hour VM cycle.
  checkedScript = name: text:
    let checked = pkgs.runCommand "skein-${name}-checked" { } ''
      printf '%s' ${lib.escapeShellArg text} > script
      ${pkgs.bash}/bin/bash -n script || {
        echo "skein-oobe-files: $name does not parse" >&2
        exit 1
      }
      cp script $out
    '';
    in lib.nameValuePair "skein/${name}" { source = checked; };

  installer = builtins.readFile ../scripts/install-to-disk.sh;
  oobe      = builtins.readFile ../scripts/skein-oobe.sh;
  term      = builtins.readFile ../scripts/skein-oobe-term.sh;
  widgets   = builtins.readFile ../scripts/skein-oobe-widgets.sh;
in
{
  environment.etc = lib.listToAttrs [
    (checkedScript "install.sh" installer)
    (checkedScript "oobe.sh" oobe)
    (checkedScript "skein-oobe-term.sh" term)
    (checkedScript "skein-oobe-widgets.sh" widgets)
  ];
}
