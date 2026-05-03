{
  description = "g602 userspace input interposer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/1267bb4920d0fc06ea916734c11b0bf004bbe17e";

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
        packages.hid-logitech-dj-patched = pkgs.linuxPackages.callPackage ./nix/hid-logitech-dj.nix {};

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
