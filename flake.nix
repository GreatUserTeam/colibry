# Flake entry point for the Spark NixOS distribution.
# This file pins all inputs, exposes the NixOS system "spark", and defines
# the build apps: the installed system and the installer ISO.
{
  description = "Spark — a security-first NixOS distribution for people who don't want to think about computers.";

  inputs = {
    # NixOS unstable is pinned to a known-good revision.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Nixpak sandboxes desktop applications with bubblewrap portals.
    nixpak = {
      url = "github:nixpak/nixpak";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The graphical app store for Nix (not packaged in nixpkgs).
    nix-software-center = {
      url = "github:snowfallorg/nix-software-center";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Helium browser (not packaged in nixpkgs; the flake repackages the
    # upstream .deb and provides a NixOS module with policy support).
    helium = {
      url = "github:oxcl/nix-flake-helium-browser";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpak, nix-software-center, helium, ... }:
    let
      # System architecture is fixed to x86_64 for the first prototype.
      system = "x86_64-linux";

      # All Spark system modules are shared by the installed system and the
      # installer ISO, so the live session behaves exactly like the target.
      sparkModules = [
        ./configuration.nix
        ./modules/identity.nix
        ./modules/plymouth.nix
        ./modules/greeter.nix
        ./modules/security.nix
        ./modules/encryption.nix
        ./modules/sandbox.nix
        ./modules/usb.nix
        ./modules/nightlight.nix
        ./modules/shell.nix
        ./modules/swap.nix
        ./modules/packages.nix
        ./modules/compat.nix
        ./modules/desktop.nix
        ./modules/recoll.nix
      ];
    in
    {
      # The distribution is exposed as a single installable NixOS system.
      nixosConfigurations.spark = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit nixpak nix-software-center helium; };
        modules = sparkModules;
      };

      # The installer ISO is the same system plus the live-session module,
      # the silent UEFI boot image and the wizard helper libraries.
      nixosConfigurations.spark-iso = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit nixpak nix-software-center helium; };
        modules = sparkModules ++ [
          ./iso/iso.nix
          ./iso/efi-image.nix
          ./iso/oobe-files.nix
        ];
      };

      # The ISO image is exposed as a buildable package.
      packages.${system}.spark-iso =
        self.nixosConfigurations.spark-iso.config.system.build.isoImage;

      # "nix run .#build" builds the ISO.
      apps.${system}.build = {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${system}.writeShellScript "spark-build" ''
          nix build ${self}#packages.${system}.spark-iso --out-link result
          echo "ISO ready:"
          ls -lh result/iso
        '');
      };
    };
}
