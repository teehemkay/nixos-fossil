# Test fixture — provides the minimum NixOS needs for a host config to
# evaluate without performing a real hardware scan. Not for deployment.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  # Disko declares the filesystem layout; we only need to satisfy the
  # boot loader and any imports that look at boot.initrd here.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];
}
