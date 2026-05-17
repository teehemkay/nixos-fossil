{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  # NOTE: hardware-config import (./canonical-hardware.nix or the fixture
  # used for eval-test) is composed in flake.nix by the helpers `mkHost`
  # / `mkHostBootstrap` / `mkHostEvalTest`, NOT here. This keeps the
  # throwing placeholder file out of imports so eval-test can substitute
  # a non-throwing fixture without the throw firing during module load.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
    ../modules/fossil-server.nix
  ];

  networking.hostName = "canonical";

  # Hetzner Cloud instances mount the OS disk at /dev/sda — the default
  # in modules/disko.nix. DigitalOcean uses /dev/vda; that override is
  # in secondary-2.nix.

  # Agenix-decrypted secrets this host consumes. All entries here MUST
  # have the canonical host's pubkey in their `publicKeys` list in
  # secrets/secrets.nix.
  age.secrets = {
    fossil-sync = {
      file = ../secrets/fossil-sync.age;
      # Make fossil-sync readable by the fossil group (consumed by
      # bin/new-repo.sh's sudo -u fossil invocations).
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
    tmk-password.file = ../secrets/tmk-password.age;
    "tailscale-authkey-canonical".file = ../secrets/tailscale-authkey-canonical.age;
  };

  # Tailscale: agenix-decrypted auth key, auto-connects on first boot.
  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets."tailscale-authkey-canonical".path;
  };

  # tmk's breaking-glass console password.
  users.users.tmk.hashedPasswordFile = config.age.secrets.tmk-password.path;

  # Fossil cluster role.
  services.fossilServer = {
    enable = true;
    role = "canonical";
    domain = "fossil.exidia.com";
    # No healthcheckUrlFile — canonical isn't monitored (no sync timer).
  };

  # NixOS state version: pinned to the release this host was first
  # installed against. Do not change after first deploy.
  system.stateVersion = "26.05";
}
