# Spark — security-first NixOS distribution (prototype v0.1)

Spark is a NixOS distribution for people who do not want to think about
computers. It assumes hostile defaults (internet, USB sticks, attachments)
and wraps the whole system in hardening, while exposing a purely
mouse-driven Hyprland desktop with a macOS-like dock.

## Build

```sh
git clone https://github.com/spark-distro/spark && cd spark
nixos-rebuild switch --flake .#spark        # or: nix build .#nixosConfigurations.spark.config.system.build.toplevel
```

## Layout

| File | Purpose |
|---|---|
| `flake.nix` | Pins nixpkgs, Hyprland, quckshell, nixpak; exposes system `spark` |
| `configuration.nix` | Base system: user, auto-updates, firmware, auto-login |
| `modules/security.nix` | Firewall (nftables, stealth drops), DNS-over-TLS, AppArmor, auditd, USBGuard, ClamAV, sysctl hardening |
| `modules/encryption.nix` | LUKS2 policy, key wipe on shutdown, 72-hour hibernation guard, gocryptfs home encryption for inactive users |
| `modules/sandbox.nix` | nixpak bubblewrap sandboxes for all network/document apps, XDG portals |
| `modules/usb.nix` | Boot-time USB automount, UDisks2, NTFS/exFAT support |
| `modules/nightlight.nix` | gammastep screen color temperature manager (GeoClue location) |
| `modules/shell.nix` | Zsh replaces bash; macOS-style prompt; friendly aliases |
| `modules/packages.nix` | Drivers (all firmware, PipeWire), codecs, friendly tool replacements, ConvertX |
| `modules/desktop.nix` | Hyprland 0.55+ with the Lua config: shadows, inactive dimming, SUPER/ALT keybindings |
| `hypr/hyprland.lua` | Compositor config: window actions on SUPER, everything else on ALT |
| `qs/shell.qml` | quckshell prototype: dock (pinned/frequent/recent/running/minimized/stack/trash), window titles, overview, launcher |
| `qs/*.qml` | Dock components and persistence stores |

## Design decisions

- **Mouse only**: no keybindings in the shell; windows are moved/resized by
  dragging with the mouse, the dock lives on the bottom edge, title pills
  carry minimize/maximize/close dots. A parallel sysadmin layer adds
  SUPER (windows) and ALT (everything else) keybindings.
- **Inactive dimming, not transparency**: `dim_inactive` applies a mask
  over every pixel; windows never become see-through.
- **Sandboxing**: every GUI app (Firefox, Thunderbird, VLC, LibreOffice,
  GIMP, KeePassXC) runs inside a nixpak bubblewrap sandbox mediated by XDG
  portals; document apps have no network access.
- **Encryption**: LUKS2 with key wiping at shutdown, hibernation over 72
  hours re-locks the disk, inactive users' homes are encrypted with gocryptfs.
- **Night light**: gammastep warms the screen after sunset using GeoClue location.
- **Friendly replacements**: nano instead of vim, fd instead of find,
  bat instead of cat, eza instead of ls, ripgrep instead of grep,
  btop instead of top, duf/dust, gping, zsh with a clean macOS-like prompt.
- **ConvertX**: packaged as `buildNpmPackage` and run as a sandboxed user
  service on `127.0.0.1:3055` (never exposed to the LAN by the firewall).
```

Пояснения по новым частям:

- **nixpak** — это именно то, что вы имели в виду: `github:nixpak/nixpak`, оборачивает пакеты в bubblewrap-сандбоксы с порталами как у Flatpak. Здесь все сетевые и документные приложения заменены сандбоксированными сборками через overlay — док ничего не замечает, документные приложения (LibreOffice, GIMP, KeePassXC) вообще без сети.
- **Шифрование**: LUKS2 как единственный разрешённый layout; при выключении/перезагрузке юнит делает `cryptsetup luksSuspend` (ключи вытираются из RAM); при гибернации метка времени пишется на `/boot`, а при пробуждении, если прошло больше 72 часов, — блокировка сессий, повторный `luksSuspend` и выключение, то есть следующая загрузка потребует пароль. Домашние каталоги неактивных пользователей шифруются gocryptfs: расшифровка монтируется только пока есть активная сессия.
- **Честные оговорки**: PAM-фрагмент в `encryption.nix` и точный API `nixpak.lib.nixpak` — прототипный уровень, их надо сверить с актуальным nixpak при первой сборке; UUID диска — плейсхолдер, который подставляет инсталлятор.
