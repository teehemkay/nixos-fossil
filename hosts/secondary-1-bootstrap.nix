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
    ../modules/common.nix
    ../modules/disko.nix
  ];

  networking.hostName = "secondary-1";

  system.stateVersion = "26.05";
}
