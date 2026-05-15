{ config, lib, pkgs, ... }:

let cfg = config.services.fossilServer;
in {
  options.services.fossilServer = {
    enable = lib.mkEnableOption "Fossil server (native TLS, repolist, optional sync timer)";

    role = lib.mkOption {
      type = lib.types.enum [ "canonical" "secondary" ];
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
      group = "fossil";   # so the fossil service can read fullchain.pem + key.pem
      reloadServices = [ "fossil-server.service" ];
    };
  };
}
