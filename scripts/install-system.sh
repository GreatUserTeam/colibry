# Colibry disk installer - system phase.
#
# Continuation of install-to-disk.sh: copies the distribution flake onto
# the target, generates the per-machine NixOS configuration from the
# wizard's answers, builds the system closure offline against the live
# store, installs it with nixos-install and plants the first-boot
# handover files. This file is sourced by install-to-disk.sh, never run
# directly; it shares the trace fd, the log() function and every
# variable of the disk phase.

# The distribution flake ships inside the installer image; copying it to
# the target makes the installed system self-contained and updatable
# without the network.
FLAKE_SRC=/etc/colibry/flake
TARGET=/mnt/etc/nixos/colibry
mkdir -p "$(dirname "$TARGET")"
cp -R "$FLAKE_SRC" "$TARGET"

# hardware-configuration.nix is generated from the mounted target; it
# captures every active mount (btrfs subvolumes, ESP, swap file) into
# fileSystems/swapDevices entries. The generated file must not pin the
# opened LUKS mapping (the mapping only exists in the installer), so the
# luks stanza is stripped here and the boot device is declared
# explicitly in local.nix instead.
nixos-generate-config --root /mnt
sed -i '/boot.initrd.luks.devices/d' /mnt/etc/nixos/hardware-configuration.nix
mv /mnt/etc/nixos/hardware-configuration.nix "$TARGET/"

# installed-boot.nix pins the loader behaviour of the installed system:
# silent systemd-boot with the editor disabled.
cat > "$TARGET/installed-boot.nix" <<'EOF'
{ ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.consoleMode = "max";
  boot.loader.systemd-boot.editor = false;
  boot.loader.timeout = 0;
}
EOF

# local.nix carries every value the wizard collected; it overrides the
# distribution defaults of configuration.nix on the installed machine.
# Updates start disabled (the update manager of modules/updates.nix
# takes over once the machine is registered to a channel).
{
  cat > "$TARGET/local.nix" <<EOF
{ config, pkgs, lib, ... }:
{
  networking.hostName = lib.mkForce "$HOSTNAME";
  time.timeZone = lib.mkForce "$TIMEZONE";
  i18n.defaultLocale = lib.mkForce "$LOCALE";
  console.keyMap = lib.mkForce "$CONSOLE_KEYMAP";
  services.xserver.xkb = {
    layout = lib.mkForce "$XKB_LAYOUT";
    options = lib.mkForce "$XKB_OPTIONS";
  };
  colibry.updates.enable = false;
EOF
  if [ "$ENCRYPT" = true ]; then
    cat >> "$TARGET/local.nix" <<'EOF'
  boot.initrd.luks.devices."colibry-root" = {
    device = "/dev/disk/by-partlabel/COLIBRY-ROOT";
    preLVM = true;
  };
EOF
  fi
  echo '}' >> "$TARGET/local.nix"
}

# Handover files for the first boot of the installed system: the user
# accounts with their plaintext passwords (consumed and removed by the
# provisioning service of modules/encryption.nix) and the first-boot
# marker that gates the integrity database build.
install -d -m 0755 /mnt/etc/colibry
install -m 0600 "$OOBE_USERS_FILE" /mnt/etc/colibry/homed-users
touch /mnt/etc/colibry/firstboot

# Preflight: build the system closure offline against the live store, so
# nixos-install never touches the network. The build uses the target's
# flake with the generated configuration; its output stays unlinked,
# the real profile is created by nixos-install below.
log "building the system closure (offline)"
nix build "$TARGET#colibry" \
  --option substitute false \
  --option eval-cache false \
  --no-link

# Install the closure to the target. --no-root-passwd keeps the root
# account locked; the wizard's password is applied from the root-password
# handover by the provisioning service, the human users log in with
# their own passwords.
log "installing the system to /mnt"
nixos-install --flake "$TARGET#colibry" --no-root-passwd --no-channel-copy

log "installation complete"
