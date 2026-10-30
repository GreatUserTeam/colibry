# Silent UEFI boot image for the Colibry installer ISO.
#
# The base ISO module builds its EFI boot image around the upstream GRUB
# template, which paints a text banner on the screen on every boot. Colibry
# boots must show nothing between the firmware screen and the Plymouth
# splash, so this module builds its own minimal FAT boot image around a
# wordless GRUB configuration and grafts it over the upstream one in the
# ISO tree: while the image staging tree is assembled, a later entry of
# isoImage.contents overwrites an earlier entry at the same target path,
# and lib.mkAfter pins these entries to the end of the list.
{ config, pkgs, lib, ... }:

let
  inherit (pkgs) buildPackages;

  grub2Efi = buildPackages.grub2_efi;

  # The kernel and initrd of this image sit in the ISO tree at
  # /boot/<store path>, exactly where the base module places them; both
  # paths are computed from the system configuration, so they can never
  # drift from what the image actually contains.
  kernelImage =
    "/boot/${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrdImage =
    "/boot/${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";

  # The kernel command line mirrors the base module's own entries: the
  # stage-2 init of the live system closure followed by this image's
  # kernel parameters, so both boot paths start the system identically.
  kernelParams = lib.concatStringsSep " " (
    [ "init=${config.system.build.toplevel}/init" ]
    ++ config.boot.kernelParams
  );

  # The complete GRUB configuration of the UEFI path. Not a single line
  # is printed on any terminal: no banner, no menu (timeout 0, single
  # entry), no video mode switch. The only work is locating the ISO9660
  # filesystem through the marker file the base module leaves in the ISO
  # tree and handing over to the kernel.
  grubCfg = pkgs.writeText "colibry-grub.cfg" ''
    set timeout=0
    set default=0

    search --set=root --file /EFI/nixos-installer-image

    menuentry "Colibry" --id colibry {
      linux ${kernelImage} ${kernelParams}
      initrd ${initrdImage}
    }
  '';

  # The FAT boot image of the UEFI path: a standalone GRUB EFI binary
  # plus the configuration itself. UEFI firmware loads
  # \EFI\BOOT\BOOTX64.EFI from this image when booting the ISO through
  # the El Torito record.
  #
  # The filesystem is built exactly the way the base module builds its
  # own (same mkfs.vfat invariants, fixed timestamps, verification pass),
  # with two deliberate choices:
  #
  #   * FAT12 on a 4 MiB volume. Firmware loads the whole boot image into
  #     memory before executing it, and every megabyte of the image is a
  #     second of the pre-boot phase on emulated and physical drives
  #     alike; FAT12 keeps the volume as small as the payload allows, and
  #     UEFI firmware reads FAT12 on boot devices.
  #   * A 4 MiB floor under the payload-derived size, so the volume stays
  #     valid even as the GRUB payload grows, without manual retuning.
  #
  # The module list handed to grub-mkimage is exactly the set this
  # configuration uses: iso9660 and fat read the ISO tree and this
  # filesystem, search with search_fs_file resolves the marker file,
  # linux loads the kernel, and normal parses the configuration.
  efiImg = pkgs.runCommand "colibry-efi-image" {
    nativeBuildInputs = [
      pkgs.mtools
      pkgs.libfaketime
      pkgs.dosfstools
    ];
  } ''
    mkdir -p contents/EFI/BOOT
    ${grub2Efi}/bin/grub-mkimage \
      --directory=${grub2Efi}/lib/grub/${grub2Efi.grubTarget} \
      -o contents/EFI/BOOT/BOOTX64.EFI \
      -p /EFI/BOOT \
      -O ${grub2Efi.grubTarget} \
      iso9660 fat search search_fs_file linux normal
    cp ${grubCfg} contents/EFI/BOOT/grub.cfg

    find contents -exec touch --date=2000-01-01 {} +
    usage_size=$(( $(du -s --block-size=1M --apparent-size contents | cut -f1) * 1024 * 1024 ))
    image_size=$(( (usage_size * 110) / 100 ))
    min_size=$((4 * 1024 * 1024))
    (( image_size < min_size )) && image_size=$min_size
    block_size=$((1024 * 1024))
    image_size=$(( (image_size / block_size + 1) * block_size ))
    truncate --size=$image_size efi.img
    mkfs.vfat --invariant -F 12 -i 12345678 -n EFIBOOT efi.img
    faketime "2000-01-01 00:00:00" mmd -i efi.img ::/EFI ::/EFI/BOOT
    faketime "2000-01-01 00:00:00" mcopy -pvm -i efi.img contents/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
    faketime "2000-01-01 00:00:00" mcopy -pvm -i efi.img contents/EFI/BOOT/grub.cfg ::/EFI/BOOT/grub.cfg
    fsck.vfat -vn efi.img
    mv efi.img $out
  '';
in
{
  isoImage.contents = lib.mkAfter [
    # The El Torito boot image itself: replacing it makes the firmware
    # load the silent loader above instead of the upstream banner one.
    { source = efiImg; target = "/boot/efi.img"; }
    # The copy used when the ISO is written to a USB stick and the
    # firmware reads the loader straight from the ISO9660 tree.
    { source = grubCfg; target = "/EFI/BOOT/grub.cfg"; }
  ];
}
