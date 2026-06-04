{
  description = "rgpeach10 homelab — NixOS configurations for all hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # The flake reference each host pulls from for auto-upgrades.
      # Hosts converge on whatever is locked on `main` after CI passes.
      flakeUrl = "github:ryanpeach-homelab/homelab";

      # Map of host -> system architecture.
      # Adjust the architecture if a host's CPU differs from the default below.
      hosts = {
        rgpeach10-mini = "x86_64-linux";
        rgpeach10-pi1 = "aarch64-linux";
      };

      mkHost =
        name: system:
        lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs flakeUrl; };
          modules = [
            ./modules/common.nix
            ./hosts/${name}
            { networking.hostName = name; }
          ];
        };
    in
    {
      # `nixos-rebuild`/auto-upgrade target: .#nixosConfigurations.<host>
      nixosConfigurations = lib.mapAttrs mkHost hosts;

      # CI builds every host's system closure through these checks.
      # checks.<system>.<host> = <toplevel derivation>
      checks = lib.genAttrs (lib.unique (lib.attrValues hosts)) (
        system:
        lib.mapAttrs (name: _: self.nixosConfigurations.${name}.config.system.build.toplevel) (
          lib.filterAttrs (_: s: s == system) hosts
        )
      );
    };
}
