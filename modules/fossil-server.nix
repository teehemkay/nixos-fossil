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
    # populated by subsequent tasks
  };
}
