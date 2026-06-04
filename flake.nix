{
  description = "rgpeach10 homelab — NixOS configurations for all hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Secrets management (encrypted with age/sops, decrypted on the host).
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      inherit (nixpkgs) lib;

      systems = lib.unique (lib.attrValues hosts);
      forEachSystem = lib.genAttrs systems;

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
            inputs.sops-nix.nixosModules.sops
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
      checks = forEachSystem (
        system:
        lib.mapAttrs (name: _: self.nixosConfigurations.${name}.config.system.build.toplevel) (
          lib.filterAttrs (_: s: s == system) hosts
        )
      );

      # `nix develop` provides the secrets + linting tooling and installs the
      # git pre-commit hook. CI uses this same shell so local and CI match.
      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.pre-commit
              pkgs.go # builds the published gitleaks pre-commit hook
              pkgs.gitleaks
              pkgs.statix
              pkgs.deadnix
              pkgs.sops
              pkgs.age
              pkgs.ssh-to-age
              pkgs.nixfmt-rfc-style
            ];
            shellHook = ''
              pre-commit install --install-hooks >/dev/null 2>&1 || true
            '';
          };
        }
      );
    };
}
