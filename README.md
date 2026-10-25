# Skein — security-first NixOS distribution

Skein is a NixOS distribution for people who do not want to think about
computers. It assumes hostile defaults (internet, USB sticks, attachments)
and wraps the whole system in hardening: full-disk LUKS2 encryption, an
nftables firewall, a DNS stack with DNSSEC and encrypted upstreams, USB
device guard, always-on antivirus and mandatory access control — while the
user-facing surface stays silent and simple: a graphical out-of-box
experience wizard, a boot splash with no text, and updates that install
themselves.

## Build the installer ISO

```sh
git clone <repo> && cd skein
./build.sh            # builds result/iso/skein-*.iso, prints its sha256, cleans the store
./build.sh run        # build, then boot the ISO in QEMU with a serial log
./build.sh clean      # drop the result link and garbage-collect the store
```

`build.sh` retries the nix build on transient network failures and
syntax-checks every installer script before any nix work starts. `run.sh`
creates a test disk on first use and records the full guest serial log in
`skein.log` together with the ISO hash it booted.

## Layout

| Path | Purpose |
|---|---|
| `flake.nix` | Pins all inputs; exposes `nixosConfigurations.skein` and `.skein-iso` |
| `configuration.nix` | Base identity: kernel, firmware policy, silent boot, update manager |
| `modules/identity.nix` | Operating system identity (os-release, distro id, greeting) |
| `modules/updates.nix` | Update manager: silent minor updates, confirm-then-reboot major updates |
| `modules/encryption.nix` | LUKS2 policy, key wipe on shutdown, hibernation guard, homed provisioning |
| `modules/security.nix` | Firewall (nftables), dnsmasq + unbound DNS stack, auditd, ClamAV, USBGuard |
| `modules/apparmor.nix` | AppArmor activation and a nix-store abstraction for profiles |
| `modules/plymouth.nix` | Boot splash theme (logo + progress bar) starting in the initrd |
| `modules/sandbox.nix` | nixpak bubblewrap sandboxes for network and document applications |
| `modules/usb.nix` | Read-only USB automount with on-access antivirus scanning |
| `modules/swap.nix` | zram plus dynamically grown btrfs swap files |
| `modules/packages.nix` | Curated desktop application set, codecs, firmware |
| `modules/desktop.nix` | Desktop environment and greeter |
| `modules/greeter.nix` | Login screen |
| `modules/nightlight.nix` | Screen color temperature after sunset |
| `modules/shell.nix` | Zsh with friendly, Rust-first tool replacements |
| `modules/recoll.nix` | Full-text search indexing |
| `modules/compat.nix` | Waydroid (Android) and EXE compatibility layer |
| `iso/iso.nix` | Installer image: OOBE session, locale/keymap baking |
| `iso/efi-image.nix` | Silent UEFI boot image replacing the upstream GRUB banner |
| `iso/oobe-files.nix` | OOBE helper libraries with build-time syntax checking |
| `scripts/skein-oobe*.sh` | OOBE wizard (terminal layer, widgets, session) |
| `scripts/install-to-disk.sh` | Disk installer: partitioning, LUKS2, btrfs, offline nixos-install |
| `build.sh` / `run.sh` | ISO build wrapper with store hygiene / QEMU test runner |

## Design decisions

- **Silent boot**: between the firmware and the desktop the screen shows
  only the Skein logo and a progress bar. The ISO boots through a custom
  EFI image whose GRUB prints nothing; kernel and systemd are quiet, the
  only console is the serial port, which mirrors the full journal for
  debugging.
- **Two contours of updates**: minor updates build from the installed
  flake and switch silently without a reboot; major updates are detected
  against the release channel on the update server, installed only after
  an explicit confirmation, always take the newest release and end with a
  reboot. Front end: `skein-update status|check|confirm`.
- **Passwords never touch the disk in plaintext**: the installer wizard
  hashes the root password (sha512-crypt) and passes the LUKS passphrase
  only through the process environment; user account passwords are set by
  each user at first login.
- **Offline installation**: the installer copies the distro flake (with
  its lock file) from the live system onto the target, builds the system
  closure against the live store before installing and never needs the
  network at install time.
- **Disk layout**: a 1 GiB EFI system partition and one btrfs partition
  (subvolumes `@`, `@home`, `@var`, `@snapshots`, `@swap`) inside LUKS2;
  the rest of the disk stays unallocated, like a factory Windows install.
- **AppArmor on a Nix base**: the kernel activates AppArmor as the system
  LSM, and profiles include a `nix-store` abstraction, because stock
  AppArmor abstractions describe an FHS host and deny legitimate access
  to `/nix/store`.
- **Sandboxing**: network and document applications run inside nixpak
  bubblewrap sandboxes mediated by XDG portals; document applications have
  no network access.
- **Memory**: zram compression is always on; swap files inside a
  dedicated btrfs subvolume grow under memory pressure.
- **Security by default**: USB sticks mount read-only and are scanned,
  plaintext DNS never leaves the machine, and MAC randomization is on.

## License

Skein is distributed under the ILL (Modular Lineage License). See
`NOTICE` for the authorship chain and third-party components.
