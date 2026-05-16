{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  # Hardware-config import is composed by flake.nix's helpers, not here.
  imports = [
    ../modules/common.nix # users (no password), ssh, sudo, sysctl, firewall, autoUpgrade, etc.
    ../modules/disko.nix
  ];

  networking.hostName = "canonical";

  system.stateVersion = "26.05";
}
