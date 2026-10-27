# Installer image of the Skein distribution.
#
# This module turns the installed system into the live installer ISO. It
# pins the ISO identity (volume label, file name, squashfs codec), keeps
# both boot-loader paths (UEFI and BIOS) visually silent, fixes the exact
# kernel command line of the live boot, ships the distro flake into the
# image for the offline installer, bakes the locale and keyboard lists the
# wizard offers, and extends the image store with the source trees of every
# locked flake input so the installer can evaluate the target flake without
# network access. The wizard session itself lives in ./oobe-session.nix;
# the wizard and installer scripts live in ./oobe-files.nix.
{ config, pkgs, lib, modulesPath, nixpkgs, nixpak, nix-software-center, helium, ... }:

let
  # The distro flake shipped inside the live system at /etc/skein/flake;
  # the installer copies it onto the target and builds the installed
  # system from it. Test disks, build results, VCS data and logs are build
  # artifacts of the development machine and never belong into the image.
  flakeSource = lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let base = baseNameOf path;
      in ! (lib.hasSuffix ".qcow2" base
            || base == "result"
            || base == ".git"
            || base == ".github"
            || lib.hasPrefix "skein.log" base
            || lib.hasSuffix ".iso" base
            || lib.hasSuffix ".img" base);
  };

  # The languages the wizard offers, one locale code per line. The
  # terminal layer maps every code to a human-readable native name for
  # the picker; codes outside the table still work and show their code.
  locales = [
    "en_US.UTF-8" "en_GB.UTF-8" "ru_RU.UTF-8" "de_DE.UTF-8"
    "fr_FR.UTF-8" "es_ES.UTF-8" "pt_BR.UTF-8" "pt_PT.UTF-8"
    "it_IT.UTF-8" "nl_NL.UTF-8" "pl_PL.UTF-8" "uk_UA.UTF-8"
    "be_BY.UTF-8" "cs_CZ.UTF-8" "sk_SK.UTF-8" "sl_SI.UTF-8"
    "hr_HR.UTF-8" "sr_RS.UTF-8" "bs_BA.UTF-8" "bg_BG.UTF-8"
    "mk_MK.UTF-8" "sq_AL.UTF-8" "lt_LT.UTF-8" "lv_LV.UTF-8"
    "et_EE.UTF-8" "fi_FI.UTF-8" "sv_SE.UTF-8" "nb_NO.UTF-8"
    "da_DK.UTF-8" "is_IS.UTF-8" "hu_HU.UTF-8" "ro_RO.UTF-8"
    "el_GR.UTF-8" "tr_TR.UTF-8" "he_IL.UTF-8" "ar_EG.UTF-8"
    "fa_IR.UTF-8" "ur_PK.UTF-8" "ja_JP.UTF-8" "ko_KR.UTF-8"
    "th_TH.UTF-8" "vi_VN.UTF-8" "id_ID.UTF-8" "ms_MY.UTF-8"
    "hi_IN.UTF-8" "bn_BD.UTF-8" "ta_IN.UTF-8" "te_IN.UTF-8"
    "ml_IN.UTF-8" "pa_IN.UTF-8" "ne_NP.UTF-8" "si_LK.UTF-8"
    "my_MM.UTF-8" "ka_GE.UTF-8" "hy_AM.UTF-8" "az_AZ.UTF-8"
    "kk_KZ.UTF-8" "uz_UZ.UTF-8" "zh_CN.UTF-8" "zh_TW.UTF-8"
  ];

  # The keyboard layouts the wizard offers, one xkb layout name per
  # line. The installer writes the first layout to the console keymap
  # and the xkb layout, several layouts gain the Alt+Shift switch.
  keymaps = [
    "us" "ru" "de" "fr" "es" "it" "pt" "br" "pl" "uk"
    "by" "cz" "sk" "si" "hr" "rs" "bg" "tr" "gr" "il"
    "ar" "no" "se" "fi" "dk" "is" "hu" "ro" "lt" "lv"
    "et" "al" "mk" "ba" "ge" "am" "az" "kk" "uz" "jp"
    "kr" "cn" "tw" "th" "vn" "id" "in" "my" "dvorak" "colemak"
  ];
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-graphical-base.nix") ];

  # The image file name is derived from image.baseName (image.fileName
  # defaults to "baseName.extension"); mkForce overrides the value the
  # upstream ISO module sets for itself.
  image.baseName = lib.mkForce "skein-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";

  # The exact kernel command line of the live boot. mkForce replaces
  # every other module's kernel parameter list for the installer image,
  # so the boot is fully deterministic: serial console first, the screen
  # console second, Plymouth graphical splash, and every source of text
  # output silenced or confined to the serial port.
  boot.kernelParams = lib.mkForce [
    "console=ttyS0,115200n8"
    "console=tty0"
    "splash"
    "quiet"
    "loglevel=0"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_level=3"
    "vt.global_cursor_default=0"
  ];

  isoImage = {
    volumeID = "SKEIN";
    squashfsCompression = "zstd -Xcompression-level 19";
    makeEfiBootable = true;
    makeUsbBootable = true;

    # BIOS boot path: syslinux paints every pixel black and never opens a
    # menu, so a firmware booting the image in legacy mode sees the same
    # silent screen as the UEFI path. The option has plain string type:
    # the text is inlined into the isolinux configuration, so it must be
    # a string, not a store derivation.
    syslinuxTheme = ''
      SERIAL 0 115200
      PROMPT 0
      TIMEOUT 1
      UI menu.c32
      MENU TITLE Skein
      MENU BACKGROUND
      MENU RESOLUTION 1024 768
      MENU COLOR screen      37;40   #00000000 #00000000 none
      MENU COLOR border      37;40   #00000000 #00000000 none
      MENU COLOR title       37;40   #00000000 #00000000 none
      MENU COLOR unsel       37;40   #00000000 #00000000 none
      MENU COLOR hotkey      37;40   #00000000 #00000000 none
      MENU COLOR sel         37;40   #00000000 #00000000 none
      MENU COLOR hotsel      37;40   #00000000 #00000000 none
      MENU COLOR disabled    37;40   #00000000 #00000000 none
      MENU COLOR scrollbar   37;40   #00000000 #00000000 none
      MENU COLOR tabmsg      37;40   #00000000 #00000000 none
      MENU COLOR cmdmark     37;40   #00000000 #00000000 none
      MENU COLOR cmdline     37;40   #00000000 #00000000 none
      MENU COLOR pwdborder   37;40   #00000000 #00000000 none
      MENU COLOR pwdtitle    37;40   #00000000 #00000000 none
      MENU COLOR pwdentry    37;40   #00000000 #00000000 none
      MENU COLOR timeout_msg 37;40   #00000000 #00000000 none
      MENU COLOR timeout     37;40   #00000000 #00000000 none
      MENU COLOR help        37;40   #00000000 #00000000 none
      MENU MARGIN 0
      MENU ROWS 1
      MENU VSHIFT 0
      MENU HSHIFT 0
      MENU WIDTHPAD 0
      MENU AUTOBOOT Skein
    '';
  };

  # The boot loader never waits and never draws a menu. mkForce is
  # required: the upstream ISO module defines this option with a plain
  # value (10) that a same-priority definition would conflict with.
  boot.loader.timeout = lib.mkForce 0;

  # Tools of the installation runtime. jq parses the JSON answers handover
  # (both the wizard and install-to-disk.sh depend on it), openssl computes
  # the sha512-crypt root password hash the wizard puts into the answers
  # document. They are installer-only tools, so they are added to the live
  # image here instead of the installed system's package set.
  environment.systemPackages = [ pkgs.jq pkgs.openssl ];

  # The wizard offers these lists; they are baked at image build time so
  # the picker never spawns a subprocess and works without any network.
  environment.etc."skein/locales".text = lib.concatStringsSep "\n" locales + "\n";
  environment.etc."skein/keymaps".text = lib.concatStringsSep "\n" keymaps + "\n";

  # The installed system evaluates this flake offline on the target; the
  # image store therefore carries the exact source trees the lock file
  # references, so no input ever needs to be downloaded at install time.
  # List-valued options merge, so the upstream module's own additions to
  # system.extraDependencies stay in effect alongside these.
  system.extraDependencies = [
    nixpkgs.outPath
    nixpak.outPath
    nix-software-center.outPath
    helium.outPath
  ];

  # The distro flake of the live system; the installer copies it onto the
  # target byte-identically (see scripts/install-to-disk.sh).
  environment.etc."skein/flake".source = flakeSource;

  # The live session is driven by the wizard alone; the manual of the
  # generic installer image is not needed.
  documentation.nixos.enable = false;

  # The generic live image defines a password for the "nixos" maintenance
  # account; the value is inherited here unchanged.
  users.users.nixos.initialPassword = "nixos";
}
