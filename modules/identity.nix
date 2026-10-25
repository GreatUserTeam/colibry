# Identity module of Skein.
# Rebrands the base system so Skein is a self-contained distribution: the
# os-release identity, the login console greeting and the boot appearance
# carry no upstream distribution name.
{ config, pkgs, lib, ... }:

{
  # The distribution ID feeds /etc/os-release and the default ISO file name;
  # it is the machine-readable identity of the operating system.
  system.nixos.distroId = "skein";

  # The full os-release content is written explicitly so NAME carries the
  # Skein identity instead of any upstream distribution name.
  environment.etc."os-release".text = ''
    NAME="Skein"
    PRETTY_NAME="Skein 0.1"
    ID=skein
    ID_LIKE="nixos"
    VERSION="0.1"
    VERSION_ID="0.1"
    HOME_URL="https://skein.example.org/"
    DOCUMENTATION_URL="https://skein.example.org/docs"
  '';

  # The virtual console greeting shows the Skein identity only.
  services.getty.greetingLine = "Skein 0.1 \\n \\l";
  services.getty.helpLine = "";

  # The bootloader gives no menu and no countdown: the machine starts
  # straight into the operating system.
  boot.loader.timeout = 0;
  boot.loader.systemd-boot.editor = false; # Kernel parameters cannot be edited from the boot screen.

  # Silent boot, both stages. The kernel prints nothing below warning
  # level, the rd.* keys silence the initrd and the plain keys silence the
  # real system after the switch root, so no [OK] lines or unit output ever
  # overwrite the Plymouth splash. The splash parameter makes Plymouth show
  # the graphical theme, and the hidden text cursor avoids a blinking block
  # in the corner of the splash.
  boot.kernelParams = [
    "quiet"
    "splash"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_level=3"
    "vt.global_cursor_default=0"
  ];
}
