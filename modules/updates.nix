# Update manager of the Skein system.
#
# Skein updates come in two kinds with different rules:
#
#   * Minor updates refresh the packages of the running system. A daily
#     timer downloads the lock file of the newest tested input set from
#     the update server and, only when it differs from the installed
#     lock, switches the system to it: services are restarted, userland
#     is replaced in place, the session is never interrupted and no
#     reboot ever happens. When the switch fails, the previous lock is
#     restored untouched. The kernel of the running system keeps serving
#     until the machine reboots for any other reason; the new kernel
#     activates with that next boot.
#
#   * Major updates move the system to a new release line. A periodic
#     check reads the metadata of the major channel on the update
#     server - a flake archive whose tip is always the newest release -
#     and only records that a newer release exists; it never installs
#     anything. Installing is one explicit confirmation through
#     "skein-update confirm", it always takes the tip of the major
#     channel (there is deliberately no version picker), and it ends
#     with a reboot, because a release line change always ships a new
#     kernel and core runtime.
#
# The installed major revision is recorded in /etc/skein/major-installed;
# the check compares the channel tip against that file. The pending
# marker lives in /run and is rebuilt by the periodic check after every
# boot.
#
# Minor updates only run where an installed system flake exists: the
# service carries a path condition, so the live session of the
# installer image silently skips it.
{ config, pkgs, lib, ... }:

let
  cfg = config.skein.updates;
  stateDir = "/run/skein";
  pendingFile = "${stateDir}/major-pending";
  installedFile = "/etc/skein/major-installed";
in
{
  options.skein.updates = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the Skein update manager: silent minor updates and the
        confirm-then-reboot flow for major updates.
      '';
    };
    flake = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos/skein";
      description = ''
        Flake reference of the installed system. Minor updates switch
        the running system to the lock file served for it.
      '';
    };
    systemAttr = lib.mkOption {
      type = lib.types.str;
      default = "skein";
      description = "Flake output attribute of the system configuration.";
    };
    server = lib.mkOption {
      type = lib.types.str;
      default = "https://skein.gusteam.net/update";
      description = ''
        Base URL of the Skein update server. It serves "minor.lock" (the
        tested lock file for minor updates) and "major.tar.gz" (the flake
        archive of the newest release).
      '';
    };
    majorFlake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${cfg.server}/major.tar.gz";
      description = ''
        Flake reference of the major channel: a moving pointer whose tip
        is always the newest Skein release. When null, the major update
        flow is inactive.
      '';
    };
    minorInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd calendar expression for minor update runs.";
    };
    majorCheckInterval = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "systemd calendar expression for major update checks.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    # --- minor updates: silent switch, never a reboot ----------------------
    systemd.services.skein-update-minor = {
      description = "Skein minor update (silent switch, no reboot)";
      path = [ pkgs.nixos-rebuild pkgs.curl pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        # Only an installed system has the flake; the live session of the
        # installer image skips this service silently.
        ConditionPathExists = cfg.flake;
        ExecStart = pkgs.writeShellScript "skein-minor-update" ''
          set -euo pipefail
          export NIX_CONFIG="experimental-features = nix-command flakes"
          lock_url=${cfg.server}/minor.lock
          lock=${cfg.flake}/flake.lock
          tmp=$(${pkgs.coreutils}/bin/mktemp)
          # An unreachable update server is not an error: the system
          # keeps its current, fully functional lock file.
          ${pkgs.curl}/bin/curl -fsSL "$lock_url" -o "$tmp" || exit 0
          # Nothing new: stay silent and skip the switch entirely.
          ${pkgs.coreutils}/bin/cmp -s "$tmp" "$lock" && exit 0
          ${pkgs.coreutils}/bin/cp "$lock" "$lock.bak" 2>/dev/null || true
          ${pkgs.coreutils}/bin/cp "$tmp" "$lock"
          if ! ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ${cfg.flake}#${cfg.systemAttr}; then
            # Roll the lock back so the next run retries cleanly.
            ${pkgs.coreutils}/bin/mv "$lock.bak" "$lock" 2>/dev/null || true
            exit 1
          fi
          ${pkgs.coreutils}/bin/rm -f "$lock.bak" "$tmp"
        '';
      };
      # Success is silent by design; failures land in the journal and the
      # next timer run retries.
    };
    systemd.timers.skein-update-minor = {
      description = "Daily minor update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.minorInterval;
        RandomizedDelaySec = "45m";
        Persistent = true;
      };
    };

    # --- major update check: detect, never install ---------------------------
    systemd.services.skein-update-major-check = lib.mkIf (cfg.majorFlake != null) {
      description = "Skein major update check";
      path = [ pkgs.nix pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "skein-major-check" ''
          set -euo pipefail
          export NIX_CONFIG="experimental-features = nix-command flakes"
          latest="$(${pkgs.nix}/bin/nix flake metadata --json ${cfg.majorFlake} | ${pkgs.jq}/bin/jq -r '.locked.rev // .locked.narHash')"
          installed="$(cat ${installedFile} 2>/dev/null || echo none)"
          if [ "$latest" != "$installed" ]; then
            printf '%s\n' "$latest" > ${pendingFile}
          else
            rm -f ${pendingFile}
          fi
        '';
      };
    };
    systemd.timers.skein-update-major-check = lib.mkIf (cfg.majorFlake != null) {
      description = "Periodic major update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.majorCheckInterval;
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # --- major update apply: one confirmation, tip of the channel, reboot --
    systemd.services.skein-update-major-apply = lib.mkIf (cfg.majorFlake != null) {
      description = "Install the latest Skein major update and reboot";
      path = [ pkgs.nix pkgs.jq pkgs.nixos-rebuild ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "skein-major-apply" ''
          set -euo pipefail
          export NIX_CONFIG="experimental-features = nix-command flakes"
          latest="$(${pkgs.nix}/bin/nix flake metadata --json ${cfg.majorFlake} | ${pkgs.jq}/bin/jq -r '.locked.rev // .locked.narHash')"
          ${pkgs.nixos-rebuild}/bin/nixos-rebuild boot --flake ${cfg.majorFlake}#${cfg.systemAttr}
          mkdir -p /etc/skein
          printf '%s\n' "$latest" > ${installedFile}
          rm -f ${pendingFile}
          ${pkgs.systemd}/bin/systemctl reboot
        '';
      };
    };

    # --- command line front end ----------------------------------------------
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "skein-update" ''
        # skein-update: front end of the Skein update manager.
        #
        #   status   Show the update state: last minor update result and
        #            whether a major update is waiting for confirmation.
        #   confirm  Install the LATEST major update (the tip of the major
        #            channel; no version picker exists) and reboot.
        #   check    Refresh the major update detection right now.
        set -euo pipefail
        export NIX_CONFIG="experimental-features = nix-command flakes"

        pending=${pendingFile}
        installed=${installedFile}
        channel=${if cfg.majorFlake != null then "'${cfg.majorFlake}'" else ""}

        cmd=''${1:-status}
        case "$cmd" in
          status)
            printf 'minor updates: %s\n' "$(${pkgs.systemd}/bin/systemctl show skein-update-minor.service -p Result --value 2>/dev/null || echo unknown)"
            if [ -n "$channel" ]; then
              printf 'major channel: %s\n' "$channel"
              printf 'installed major: %s\n' "$(cat "$installed" 2>/dev/null || echo none)"
              if [ -f "$pending" ]; then
                printf 'major update available: %s (confirm with: skein-update confirm)\n' "$(cat "$pending")"
              else
                printf 'major updates: none pending\n'
              fi
            else
              printf 'major updates: no major channel configured\n'
            fi
            ;;
          check)
            [ -n "$channel" ] || { echo "skein-update: no major channel configured" >&2; exit 1; }
            exec ${pkgs.systemd}/bin/systemctl start skein-update-major-check.service
            ;;
          confirm)
            [ -n "$channel" ] || { echo "skein-update: no major channel configured" >&2; exit 1; }
            echo "skein-update: installing the latest major update from $channel"
            echo "skein-update: the system will reboot when the installation finishes"
            exec ${pkgs.systemd}/bin/systemctl start skein-update-major-apply.service
            ;;
          *)
            echo "usage: skein-update [status|check|confirm]" >&2
            exit 2
            ;;
        esac
      '')
    ];
  };
}
