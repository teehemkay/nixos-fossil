{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fossilServer;
in
{
  options.services.fossilServer = {
    enable = lib.mkEnableOption "Fossil server (native TLS, repolist, optional sync timer)";

    role = lib.mkOption {
      type = lib.types.enum [
        "canonical"
        "secondary"
      ];
      description = "Cluster role. Only secondaries run the sync timer.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "fossil.exidia.com";
      description = "DNS name fossil serves. ACME requests a cert for this.";
    };

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fossil/museum";
      description = "Directory holding the .fossil files served by --repolist.";
    };

    # NOTE: there was a syncCredentialFile option here in earlier plan
    # drafts. It was removed because the module never read it — the sync
    # password is consumed by bin/new-repo.sh and the rotation runbook,
    # which read it on the host from /run/agenix/fossil-sync
    # (i.e. config.age.secrets.fossil-sync.path after activation, the
    # only consumer of the path). Same shape as the canonicalUrl removal.

    syncInterval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "systemd OnCalendar expression for the sync timer.";
    };

    healthcheckUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the agenix-decrypted file containing the healthchecks.io
        ping URL (one line). null disables monitoring.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.fossil = { };
    users.users.fossil = {
      isSystemUser = true;
      group = "fossil";
      # Home is /var/lib/fossil so fossil's $HOME/.fossil global config
      # (the "all repositories" list) lives at /var/lib/fossil/.fossil.
      # Without an explicit home, NixOS would default to /var/empty and
      # `fossil all add` would fail silently. createHome ensures the dir
      # exists with right ownership on first activation.
      home = "/var/lib/fossil";
      createHome = true;
      # Non-login user — no shell, no SSH access.
      shell = pkgs.shadow + "/bin/nologin";
    };

    # Ensure the repolist dir exists. We don't strictly need this on top
    # of createHome (because repoDir is under the home), but being explicit
    # keeps the mode/owner enforced by NixOS' systemd-tmpfiles.
    systemd.tmpfiles.rules = [
      "d ${cfg.repoDir} 0750 fossil fossil -"
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = "tmk@fastmail.fm";
    };
    security.acme.certs.${cfg.domain} = {
      dnsProvider = "cloudflare";
      # The credentials file is sourced as a shell env file. agenix
      # decrypts cloudflare-dns.age to this path; its contents must be:
      #
      #     CLOUDFLARE_DNS_API_TOKEN=<your-token>
      #
      # (See docs/setup.org for token-scope guidance.)
      environmentFile = config.age.secrets.cloudflare-dns.path;
      group = "fossil"; # so the fossil service can read fullchain.pem + key.pem
      reloadServices = [ "fossil-server.service" ];
    };

    systemd.services.fossil-server = {
      description = "Fossil SCM server (native TLS)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "acme-${cfg.domain}.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        # Must start as root to bind :443. Fossil reads --cert and --pkey
        # then chroots into the repoDir and setuids to the fossil user.
        User = "root";
        ExecStart =
          let
            certDir = "/var/lib/acme/${cfg.domain}";
          in
          ''
            ${pkgs.fossil}/bin/fossil server \
              --port 443 \
              --cert ${certDir}/fullchain.pem \
              --pkey ${certDir}/key.pem \
              --repolist \
              --baseurl https://${cfg.domain}/ \
              --jsmode bundled \
              ${cfg.repoDir}
          '';
        # Notes on the argument shape (verified against fossil's
        # src/main.c:2976 — `find_option("repolist", 0, 0)`):
        #   - `--repolist` is a BOOLEAN flag (no value), enabling
        #     directory-listing behavior when the positional REPOSITORY
        #     argument is a directory.
        #   - The REPOSITORY (or directory) is the trailing POSITIONAL
        #     argument — `${cfg.repoDir}` at the end.

        Restart = "always";
        RestartSec = 3;

        # systemd hardening: blocks setuid-up, allows fossil's setuid-down.
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/fossil" ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
      };
    };

    # Secondaries pull (and push back local writes) every syncInterval.
    # The systemd timer fires the service; the service runs as the fossil
    # user (so $HOME=/var/lib/fossil is set automatically from passwd) and
    # exits when sync completes. On success, ping healthchecks.io.
    systemd.timers.fossil-sync = lib.mkIf (cfg.role == "secondary") {
      description = "Fossil cluster sync (pull + push) every ${cfg.syncInterval}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.syncInterval;
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };

    systemd.services.fossil-sync = lib.mkIf (cfg.role == "secondary") {
      description = "Fossil cluster sync (oneshot)";
      after = [
        "network-online.target"
        "fossil-server.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "fossil";
        Group = "fossil";
        # `fossil all sync -u` walks the user's "all" list (in
        # /var/lib/fossil/.fossil) and syncs each repo against its stored
        # remote URL. -u also syncs unversioned content.
        ExecStart = "${pkgs.fossil}/bin/fossil all sync -u";
        # On success, ping healthchecks.io if a URL file is provided.
        # `cat` reads the agenix-decrypted file; -fsSL keeps curl quiet
        # but reports failure exit codes.
        ExecStartPost = lib.mkIf (cfg.healthcheckUrlFile != null) (
          pkgs.writeShellScript "fossil-sync-healthcheck" ''
            url=$(${pkgs.coreutils}/bin/cat ${cfg.healthcheckUrlFile})
            ${pkgs.curl}/bin/curl -fsSL -m 10 --retry 3 "$url" || true
          ''
        );
      };
    };
  }; # end of `config = lib.mkIf cfg.enable { ... }`
} # end of the module function
