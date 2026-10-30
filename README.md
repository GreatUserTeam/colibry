<div align="center">

# Colibry

**A Linux distribution for people who do not want to think about computers.**

</div>

Colibry assumes hostile defaults — the internet, USB sticks, email
attachments — and wraps the whole system in hardening: full-disk LUKS2
encryption, an nftables firewall, a DNS stack with DNSSEC and encrypted
upstreams, a USB device guard, always-on antivirus and mandatory access
control. The user-facing surface stays silent and simple: a graphical
out-of-box wizard, a boot screen with no text anywhere, and updates that
install themselves.

The screen between the firmware and the desktop shows nothing but the
Colibry logo. Every diagnostic travels to the serial console. Every
question a person is usually asked — about security, memory, updates,
backups — is answered by the system, and the answers are explained in
plain language only when it matters.

## Build the installer image

```sh
git clone <repo> && cd colibry
./build.sh            # builds result/iso/colibry-*.iso, prints its sha256, cleans the store
./build.sh run        # build, then boot the ISO in QEMU with a serial log
./build.sh clean      # drop the result link and garbage-collect the store
```

`build.sh` retries the nix build on transient network failures and
syntax-checks every installer script before any nix work starts. `run.sh`
creates a test disk on first use and records the full guest serial log in
`colibry.log` together with the ISO hash it booted.

## Try it

```sh
./run.sh --clear       # wipe the test disk, boot the installer
# or, on real hardware:
dd if=result/iso/colibry-*.iso of=/dev/sdX bs=4M oflag=sync status=progress
```

The wizard runs on the first virtual terminal: language, region, keyboard
layouts, computer name, root password (which is also the disk encryption
passphrase — one secret opens the device and the system), user accounts
with encrypted homes, and the target disk. The installation runs behind
the boot logo and needs no network.

## What ships

- **Silent graphical boot** — between the firmware and the desktop the
  screen shows only the logo on black; LUKS passphrases are entered as
  pixel dots. No status line can render on it.
- **Windows-like disk layout** — a 1 GiB EFI partition and one system
  partition (80 GiB, or 25% of the disk on disks under 320 GiB; `max` or
  a custom size are accepted), the rest of the disk left unallocated for
  the dynamic swap service to grow into.
- **Full-disk encryption** — LUKS2 with AES-XTS-512; the passphrase
  chosen in the wizard is the root password. Keys are wiped on shutdown
  and suspend.
- **Encrypted homes** — every user account is a systemd-homed container
  with its own LUKS volume; passwords are set at first login.
- **Memory without messages** — zram compression is always on; swap
  files inside a dedicated btrfs subvolume grow under pressure and
  shrink when idle.
- **Security by default** — nftables stealth firewall, AppArmor, audit,
  AIDE integrity monitoring, ClamAV with auto-updated signatures, USB
  devices guarded by USBGuard, USB media mounted read-only and scanned,
  MAC randomization, DNS over TLS with DNSSEC.
- **Silent updates** — minor updates build and switch in the background;
  major versions are offered with a plain-language summary and install
  only on confirmation, always ending in a reboot.
- **Compatibility** — Windows executables run through a transparent
  compatibility layer; Android applications live in a system container
  and appear like native ones.
- **Full-text search** — everything is indexed; typing finds files,
  documents and settings across the system.

## Layout

| Path | Purpose |
|---|---|
| `flake.nix` | Pins all inputs; exposes `nixosConfigurations.colibry` and `.colibry-iso` |
| `configuration.nix` | Base identity: kernel, firmware policy, silent boot, diagnostic services |
| `modules/identity.nix` | Operating system identity (os-release, distro id, greeting) |
| `modules/updates.nix` | Update manager: silent minor updates, confirmed major updates |
| `modules/encryption.nix` | LUKS2 policy, key wipe on shutdown, hibernation guard, homed provisioning |
| `modules/security.nix` | Firewall (nftables), dnsmasq + unbound DNS stack, auditd, ClamAV, USBGuard |
| `modules/apparmor.nix` | AppArmor activation and a nix-store abstraction for profiles |
| `modules/plymouth.nix` | Boot screen theme build (logo rasterization, descriptor baking) |
| `modules/sandbox.nix` | Bubblewrap sandboxes for network and document applications |
| `modules/usb.nix` | Read-only USB automount with on-access antivirus scanning |
| `modules/swap.nix` | zram plus dynamically grown btrfs swap files |
| `modules/packages.nix` | Curated desktop application set, codecs, firmware |
| `modules/desktop.nix` | Desktop environment |
| `modules/greeter.nix` | Login screen |
| `modules/nightlight.nix` | Screen color temperature after sunset |
| `modules/shell.nix` | Zsh with friendly, Rust-first tool replacements |
| `modules/recoll.nix` | Full-text search indexing |
| `modules/compat.nix` | Android and Windows executable compatibility layers |
| `iso/iso.nix` | Installer image: OOBE session, locale/keymap baking |
| `iso/efi-image.nix` | Silent UEFI boot image replacing the upstream GRUB banner |
| `iso/oobe-files.nix` | OOBE helper libraries with build-time syntax checking |
| `iso/oobe-session.nix` | Live-session services: the wizard unit, rescue shell |
| `scripts/colibry-oobe.sh` | OOBE wizard (entry point) |
| `scripts/colibry-oobe-term.sh` | Terminal layer of the wizard |
| `scripts/colibry-oobe-widgets.sh` | Widget layer of the wizard |
| `scripts/install-to-disk.sh` | Disk installer: partitioning, LUKS2, btrfs, mounts |
| `scripts/install-system.sh` | System installer: flake copy, config generation, nixos-install |
| `assets/plymouth/colibry/` | Boot screen theme sources (script, descriptor, logo) |
| `build.sh` / `run.sh` | ISO build wrapper with store hygiene / QEMU test runner |

## Design decisions

- **Silent boot**: a custom EFI image whose boot path prints nothing; a
  Plymouth theme that draws only a black stage and the logo; kernel and
  systemd are quiet; the serial port mirrors the full journal for
  debugging. The wizard paints its first frame while Plymouth still owns
  the display and then releases the splash, so neither transition
  renders text.
- **Passwords never touch the disk in plaintext**: the wizard hashes the
  root password (sha512-crypt) and passes the LUKS passphrase only
  through the process environment; user passwords are applied by the
  provisioning services of the installed system and removed.
- **Offline installation**: the installer copies the distribution flake
  (with its lock file) from the live system onto the target and builds
  the system closure against the live store; no network is needed at
  install time.
- **Two contours of updates**: minor updates switch silently without a
  reboot; major updates are detected against the release channel,
  installed only after an explicit confirmation and always end with a
  reboot. Front end: `colibry-update status|check|confirm`.
- **Sandboxing**: network and document applications run inside bubblewrap
  sandboxes mediated by portals; document applications have no network
  access at all.
- **Memory**: zram compression is always on; swap files inside a
  dedicated btrfs subvolume grow under memory pressure.

## Diagnostics

Every Colibry system mirrors its journal to the serial console and runs
a one-shot boot probe (`colibry-boot-diagnostics`) that dumps the kernel
command line, loaded DRM modules, DRM device nodes, Plymouth journal
lines and failed units. When a boot screen does not appear, the answer
is in the serial log — never on the display.

## License

Colibry is distributed under the ILL (Modular Lineage License). See
`NOTICE` for the authorship chain and third-party components.
