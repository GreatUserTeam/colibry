# Compatibility module of Colibry.
# Foreign application formats run natively: Windows executables launch
# through Proton (UMU-Launcher, no Steam) via the kernel binfmt hook, so
# ./app.exe just works; Android packages install into Waydroid through a
# double click in the file manager or the colibry-apk-install command.
{ config, pkgs, lib, ... }:

let
  # Handler invoked by the binfmt_misc hook for every PE executable: UMU
  # sets up the per-user Proton prefix on first use and downloads the
  # runtime automatically.
  colibryExeRun = pkgs.writeShellScriptBin "colibry-exe-run" ''
    if [ $# -lt 1 ]; then
      echo "usage: colibry-exe-run <program.exe> [arguments]" >&2
      exit 2
    fi
    exec ${pkgs.umu-launcher}/bin/umu-run "$@"
  '';

  # Installs an Android package into Waydroid; the user session is started
  # first when it is not running yet.
  colibryApkInstall = pkgs.writeShellScriptBin "colibry-apk-install" ''
    set -u
    APK="''${1:?usage: colibry-apk-install <app.apk>}"
    if ! ${pkgs.waydroid}/bin/waydroid status 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "Session:.*RUNNING"; then
      ${pkgs.waydroid}/bin/waydroid session start >/dev/null 2>&1 &
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        ${pkgs.waydroid}/bin/waydroid status 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "Session:.*RUNNING" && break
        sleep 1
      done
    fi
    exec ${pkgs.waydroid}/bin/waydroid app install "$APK"
  '';

  # File manager handlers: double-clicking a foreign package runs it.
  exeDesktop = pkgs.writeTextDir "share/applications/colibry-exe.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Run Windows Program
    Exec=${colibryExeRun}/bin/colibry-exe-run %f
    MimeType=application/x-ms-dos-executable;
    NoDisplay=true
    Terminal=false
  '';
  apkDesktop = pkgs.writeTextDir "share/applications/colibry-apk.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Install Android App
    Exec=${colibryApkInstall}/bin/colibry-apk-install %f
    MimeType=application/vnd.android.package-archive;
    NoDisplay=true
    Terminal=false
  '';
in
{
  # Windows executables: the kernel binfmt_misc dispatcher hands every file
  # starting with "MZ" (the DOS header of every PE binary) to the Proton
  # wrapper, so ./app.exe starts the program without any prefix command.
  boot.binfmt.registrations.colibry-exe = {
    recognitionType = "magic";
    magicOrExtension = "\\x4d\\x5a"; # "MZ".
    mask = "\\xff\\xff";
    interpreter = "${colibryExeRun}/bin/colibry-exe-run";
    # The handler is invoked with the file path as an argument.
    fixBinary = false;
  };

  # Android applications: Waydroid runs a full Android container on the
  # Wayland session of the desktop.
  virtualisation.waydroid.enable = true;

  # Waydroid downloads its Android system image once, on the first boot.
  systemd.services.colibry-waydroid-init = {
    description = "Initialize the Waydroid Android container";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ]; # The image download needs the network.
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.waydroid}/bin/waydroid init";
    };
    # Skip when the container is already initialized.
    unitConfig.ConditionPathExists = "!/var/lib/waydroid/waydroid.cfg";
  };

  environment.systemPackages = [
    colibryExeRun
    colibryApkInstall
    exeDesktop
    apkDesktop
  ];

  # System-wide MIME defaults: .apk files install into Waydroid, .exe files
  # run through Proton.
  environment.etc."xdg/mimeapps.list".text = ''
    [Default Applications]
    application/vnd.android.package-archive=colibry-apk.desktop
    application/x-ms-dos-executable=colibry-exe.desktop
  '';
}
