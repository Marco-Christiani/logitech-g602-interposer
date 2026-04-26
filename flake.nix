{
  description = "g602 userspace input interposer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        ./nix/devshells.nix
      ];

      perSystem = {
        system,
        pkgs,
        ...
      }: {
        _module.args = {
          pkgs = import inputs.nixpkgs {inherit system;};
        };

        packages.default = pkgs.callPackage ./nix/package.nix {};

        formatter = pkgs.alejandra;
      };

      flake.nixosModules.default = {
        lib,
        pkgs,
        ...
      }: {
        imports = [./nix/module.nix];
        services.g602.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
    };
}
