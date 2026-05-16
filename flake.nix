{
  description = "NixOS fossil-server cluster: canonical + 2 secondaries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      git-hooks,
      ...
    }@inputs:
    let
      system = "x86_64-linux";

      # Helper: build a full nixosConfiguration for one host.
      # Hardware-config is composed here (not inside the host file) so the
      # eval-test helper below can swap it for a non-throwing fixture.
      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            ./hosts/${name}.nix
            ./hosts/${name}-hardware.nix
          ];
        };

      # Helper: build the bootstrap variant. Reuses common.nix + disko +
      # the throwing hardware-config (which is harmless on first
      # nixos-anywhere install because hardware-config gets regenerated
      # immediately as part of the install). Skips fossil-server, agenix,
      # tailscale, and tmk hashedPasswordFile.
      mkHostBootstrap =
        name:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            ./hosts/${name}-bootstrap.nix
            ./hosts/${name}-hardware.nix
          ];
        };

      # Helper: build an eval-test variant of a host. Imports the host
      # config but with the non-throwing fixture in place of the real
      # hardware-config. Only for verifying that module wiring evaluates;
      # NOT deployable. Because the host file (hosts/<name>.nix) no longer
      # imports its hardware-config directly, we can simply NOT import
      # ./hosts/${name}-hardware.nix here — no disabledModules trickery.
      mkHostEvalTest =
        name:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            ./hosts/${name}.nix
            ./hosts/_fixture-hardware.nix
          ];
        };
    in
    {
      nixosConfigurations = {
        canonical = mkHost "canonical";
        canonical-bootstrap = mkHostBootstrap "canonical";
        secondary-1 = mkHost "secondary-1";
        secondary-1-bootstrap = mkHostBootstrap "secondary-1";
        secondary-2 = mkHost "secondary-2";
        secondary-2-bootstrap = mkHostBootstrap "secondary-2";
        canonical-eval-test = mkHostEvalTest "canonical";
        secondary-1-eval-test = mkHostEvalTest "secondary-1";
        secondary-2-eval-test = mkHostEvalTest "secondary-2";
      };
    };
}
