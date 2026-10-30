# OOBE wizard files of the installer image.
#
# The wizard session (./oobe-session.nix) runs /etc/colibry/oobe.sh and
# later invokes the disk installer as /etc/colibry/install.sh, whose
# system phase continues in /etc/colibry/install-system.sh. All scripts,
# plus the two UI libraries the wizard sources, are baked into the image
# here. Every script is parse-checked at image build time: a script
# corrupted in transfer fails the build with the file name instead of
# dying silently inside the virtual machine.
{ config, pkgs, lib, ... }:

let
  # checkedScript NAME TEXT: parses the script with bash -n during the
  # image build and installs the text at /etc/colibry/NAME. A syntax
  # error aborts the build; the parse check costs milliseconds here and
  # saves a half-hour VM cycle.
  checkedScript = name: text:
    let checked = pkgs.runCommand "colibry-${name}-checked" { } ''
      printf '%s' ${lib.escapeShellArg text} > script
      ${pkgs.bash}/bin/bash -n script || {
        echo "colibry-oobe-files: $name does not parse" >&2
        exit 1
      }
      cp script $out
    '';
    in lib.nameValuePair "colibry/${name}" { source = checked; };

  installer = builtins.readFile ../scripts/install-to-disk.sh;
  system    = builtins.readFile ../scripts/install-system.sh;
  oobe      = builtins.readFile ../scripts/colibry-oobe.sh;
  term      = builtins.readFile ../scripts/colibry-oobe-term.sh;
  widgets   = builtins.readFile ../scripts/colibry-oobe-widgets.sh;
in
{
  environment.etc = lib.listToAttrs [
    (checkedScript "install.sh" installer)
    (checkedScript "install-system.sh" system)
    (checkedScript "oobe.sh" oobe)
    (checkedScript "colibry-oobe-term.sh" term)
    (checkedScript "colibry-oobe-widgets.sh" widgets)
  ];
}
