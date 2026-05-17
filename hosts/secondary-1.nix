{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  # See hosts/canonical.nix for the rationale.
  imports = [
    ../modules/common.nix
    ../modules/disko.nix
    ../modules/fossil-server.nix
  ];

  networking.hostName = "secondary-1";

  # Agenix-decrypted secrets this host consumes.
  age.secrets = {
    fossil-sync = {
      file = ../secrets/fossil-sync.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
    tmk-password.file = ../secrets/tmk-password.age;
    "tailscale-authkey-secondary-1".file = ../secrets/tailscale-authkey-secondary-1.age;
    "healthchecks-secondary-1" = {
      file = ../secrets/healthchecks-secondary-1.age;
      owner = "fossil";
      group = "fossil";
      mode = "0440";
    };
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.age.secrets."tailscale-authkey-secondary-1".path;
  };

  users.users.tmk.hashedPasswordFile = config.age.secrets.tmk-password.path;

  services.fossilServer = {
    enable = true;
    role = "secondary";
    domain = "fossil1.exidia.com";
    healthcheckUrlFile = config.age.secrets."healthchecks-secondary-1".path;
  };

  system.stateVersion = "26.05";
}
