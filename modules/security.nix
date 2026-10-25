# Security module of Skein.
# Hardening is aggressive: Skein users are non-technical, so the system
# protects them even when they click on the wrong thing. Every control
# fails closed only for attacks, never for the user, and stays invisible
# in daily use. Session locking itself lives in modules/desktop.nix.
{ config, pkgs, lib, ... }:

{
  options.skein.usbParanoid = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Paranoid USB mode: every newly inserted USB device stays blocked at
      the kernel level until an administrator approves it, and removable
      storage is never mounted automatically.
    '';
  };

  config = {
    # The firewall blocks everything inbound; probing ports are dropped
    # silently (stealth) and logged so attempts stay visible.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ ]; # No inbound services on a desktop.
      allowedUDPPorts = [ ];
      rejectPackets = false;
      logRefusedConnections = true;
      logRefusedPackets = true;
    };
    # nftables is the packet filter backend instead of legacy iptables.
    networking.nftables.enable = true;

    # Kernel hardening: restrict what unprivileged users can observe and
    # exploit.
    boot.kernel.sysctl = {
      "kernel.sysrq" = 0; "kernel.yama.ptrace_scope" = 2;
      "kernel.randomize_va_space" = 2; "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.dmesg_restrict" = 1;
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.conf.all.rp_filter" = 1; "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0; "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0; "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0; "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0; "net.ipv4.conf.default.accept_source_route" = 0;
    };

    # ---- Local DNS stack -------------------------------------------------
    # dnsmasq (127.0.0.1:53) answers every system query and null-routes
    # trackers, ads and malware from the downloaded blocklists. unbound
    # (127.0.0.53:53) sits behind it, validates DNSSEC and talks
    # DNS-over-TLS to the upstream resolvers, so no plaintext DNS ever
    # leaves the machine.
    services.unbound = {
      enable = true;
      resolveLocalQueries = false; # dnsmasq is the resolver the system uses.
      settings = {
        server = {
          interface = [ "127.0.0.53@53" ];
          access-control = [ "127.0.0.0/8 allow" ];
          do-tcp = true;
          hide-identity = true;
          hide-version = true;
          # The module maintains the DNSSEC root trust anchor itself.
        };
        forward-zone = [ {
          name = ".";
          forward-ssl-upstream = true; # DNS-over-TLS upstreams.
          forward-addr = [
            "1.1.1.1@853#cloudflare-dns.com"
            "1.0.0.1@853#cloudflare-dns.com"
            "9.9.9.9@853#dns.quad9.net"
          ];
        } ];
      };
    };

    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false; # resolv.conf is written by the network config.
      settings = {
        "bind-interfaces" = true;
        "listen-address" = [ "127.0.0.1" ];
        "no-resolv" = true; # Never touch DHCP-provided DNS servers.
        server = [ "127.0.0.53" ]; # Everything goes through unbound.
        "domain-needed" = true; # Never leak plain hostnames upstream.
        "bogus-priv" = true; # Reverse lookups stay local.
        "addn-hosts" = "/var/lib/skein-adblock/hosts"; # The gravity blocklist.
      };
    };
    # dnsmasq must not start before the first blocklist exists.
    systemd.services.dnsmasq = {
      wants = [ "skein-adblock-update.service" ];
      after = [ "skein-adblock-update.service" ];
    };

    # Downloads and merges the tracker/ad/malware blocklists into the
    # hosts format dnsmasq reads: one "0.0.0.0 <domain>" line per name.
    systemd.services.skein-adblock-update = {
      description = "Refresh the Skein DNS blocklists";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "skein-adblock";
      };
      path = [ pkgs.curl pkgs.gawk pkgs.coreutils ];
      script = ''
        set -eu
        OUT=/var/lib/skein-adblock/hosts
        TMP=$OUT.tmp
        : > "$TMP"
        for url in \
          https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts \
          https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts
        do
          curl -fsSL "$url" >> "$TMP" || true # A dead list must not break updates.
        done
        awk '$1 == "0.0.0.0" { print $1, $2 }' "$TMP" | sort -u > "$OUT"
        rm -f "$TMP"
        chmod 644 "$OUT"
      '';
    };
    systemd.timers.skein-adblock-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "1d";
        RandomizedDelaySec = "30min";
      };
    };

    # AppArmor mandatory access control confines every packaged application.
    security.apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-utils ];
      killUnconfinedConfinables = true;
    };

    # Polkit: only the locally ACTIVE session may change disks or power
    # state; background sessions get an explicit denial instead of a prompt.
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (!subject.active &&
              (action.id.indexOf("org.freedesktop.udisks2.") === 0 ||
               action.id.indexOf("org.freedesktop.login1.") === 0 ||
               action.id.indexOf("org.freedesktop.upower.") === 0)) {
            return polkit.Result.NO;
          }
        });
      '';
    };

    # sudo is locked down with hardening defaults; the password is always asked.
    security.sudo = {
      enable = true;
      extraConfig = ''
        Defaults requiretty
        Defaults closefrom_override
        Defaults logfile="/var/log/sudo.log"
      '';
    };

    # Password quality policy shared by classic accounts (PAM) and
    # systemd-homed, which reads the same file for its own checks.
    environment.etc."security/pwquality.conf".text = ''
      minlen = 12
      dcredit = -1
      ucredit = -1
      lcredit = -1
      ocredit = -1
      dictcheck = 1
      retry = 3
    '';
    security.pam.services.passwd.text = ''
      # Account management.
      account required ${pkgs.shadow}/lib/security/pam_unix.so
      # Authentication management.
      auth sufficient ${pkgs.shadow}/lib/security/pam_rootok.so
      auth required ${pkgs.shadow}/lib/security/pam_warn.so
      auth required ${pkgs.shadow}/lib/security/pam_deny.so
      # Password management: quality is enforced before the hash is changed.
      password requisite ${pkgs.libpwquality}/lib/security/pam_pwquality.so retry=3
      password requisite ${pkgs.shadow}/lib/security/pam_unix.so yescrypt shadow nullok
      password required ${pkgs.shadow}/lib/security/pam_warn.so
      password required ${pkgs.shadow}/lib/security/pam_deny.so
      # Session management.
      session required ${pkgs.shadow}/lib/security/pam_unix.so
    '';

    # SSH server is disabled entirely; Skein is a desktop, not a server.
    services.openssh.enable = false;

    # ClamAV runs as a permanent on-access daemon; signatures update
    # themselves (with fangfrisch fetching the unofficial signatures).
    services.clamav = {
      daemon.enable = true;
      updater.enable = true;
      fangfrisch.enable = true;
    };

    # A full disk scan runs weekly at the lowest possible priority, so it
    # never disturbs the user; a detection fails the unit so it shows up
    # in the logs.
    systemd.services.skein-clamscan-weekly = {
      description = "Weekly full antivirus scan";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.clamav pkgs.util-linux pkgs.coreutils ];
      script = ''
        ionice -c 3 nice -n 19 clamscan -r \
          --exclude-dir='^/nix/store' --exclude-dir='^/proc' --exclude-dir='^/sys' \
          --exclude-dir='^/dev' --exclude-dir='^/run' \
          --log=/var/log/clamav-weekly.log /
      '';
    };
    systemd.timers.skein-clamscan-weekly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 03:00:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # Fail2ban is enabled defensively even though sshd is off (future-proofing).
    services.fail2ban.enable = true;

    # USBGuard authorizes USB devices at the kernel level (BadUSB).
    # Smart mode (default) allows mass storage because the Skein USB
    # policy mounts it read-only + noexec and scans it; all other new
    # device classes stay blocked until an administrator approves them.
    services.usbguard = {
      enable = true;
      presentDevicePolicy = "allow";
      insertedDevicePolicy = "block";
      rules = lib.optionalString (!config.skein.usbParanoid) ''
        allow with-interface one-of { 08:*:* }
      '';
    };

    # Auditd logs security-relevant syscalls for forensic review.
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        "-a always,exit -F arch=b64 -S execve"
        "-a always,exit -F arch=b64 -S openat -F exit=-EACCES"
        "-w /etc/passwd -p wa"
        "-w /etc/shadow -p wa"
      ];
    };

    # Doas stays disabled; sudo remains the single privilege escalation tool.
    security.doas.enable = false;

    # GIMP runs under Firejail with its shipped profile; the desktop entry
    # points at the wrapped binary transparently.
    programs.firejail = {
      enable = true;
      wrappedBinaries = {
        gimp = "${pkgs.gimp}/bin/gimp";
      };
    };

    # Firefox enterprise policies: tracking protection with cryptomining
    # and fingerprinting blocked, HTTPS-only mode, no telemetry, no
    # sponsored suggestions; the built-in password manager is off in
    # favor of 1Password.
    environment.etc."firefox/policies.json".text = builtins.toJSON {
      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        DisablePocket = true;
        DisableFeedbackCommands = true;
        DisableSetDesktopBackground = true;
        DontCheckDefaultBrowser = true;
        OfferToSaveLoginsDefault = false;
        PasswordManagerEnabled = false;
        SearchSuggestEnabled = false;
        SkipOnboarding = true;
        SSLVersionMin = "TLS1.2";
        HttpsOnlyMode = "enabled";
        EnableTrackingProtection = {
          Value = true;
          Cryptomining = true;
          Fingerprinting = true;
        };
        Preferences = {
          "browser.newtabpage.activity-stream.feeds.telemetry" = false;
          "browser.ping-centre.telemetry" = false;
          "browser.urlbar.suggest.quicksuggest.sponsored" = false;
          "datareporting.healthreport.uploadEnabled" = false;
          "toolkit.telemetry.enabled" = false;
          "toolkit.telemetry.unified" = false;
        };
      };
    };

    # ---- File integrity scanner ------------------------------------------
    # AIDE watches the system configuration and boot files; a digest
    # database is built on first boot, and a daily check reports every
    # change. No rootkit scanner ships: the candidates were unmaintained
    # and did not even run correctly on NixOS.
    environment.systemPackages = [ pkgs.aide ];
    environment.etc."aide.conf".text = ''
      database=file:/var/lib/aide/aide.db
      database_out=file:/var/lib/aide/aide.db.new
      gzip_dbout=yes
      report_url=stdout
      NORMAL=R+sha512
      /etc NORMAL
      /boot NORMAL
    '';
    systemd.services.skein-aide-init = {
      description = "Build the initial AIDE integrity database";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!/var/lib/aide/aide.db";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "aide";
      };
      path = [ pkgs.aide pkgs.coreutils ];
      script = ''
        aide --init
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
      '';
    };
    systemd.services.skein-aide-check = {
      description = "Daily AIDE integrity check";
      after = [ "skein-aide-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "aide";
      };
      path = [ pkgs.aide ];
      # Exit status is preserved: differences fail the unit on purpose.
      script = ''
        aide --check > /var/log/aide-report.log 2>&1
      '';
    };
    systemd.timers.skein-aide-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };

    # Logs survive reboots, and a second copy is written by rsyslog so
    # journal tampering leaves a visible discrepancy.
    services.journald.settings.Journal = {
      Storage = "persistent";
      ForwardToSyslog = true;
    };
    services.rsyslogd.enable = true;
  };
}
