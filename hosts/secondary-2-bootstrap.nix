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

  networking.hostName = "secondary-2";
  disko.devices.disk.disk1.device = "/dev/vda";

  system.stateVersion = "26.05";
}
