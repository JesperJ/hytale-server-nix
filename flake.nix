{
  description = "NixOS module and packages for running a Hytale dedicated server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = rec {
          hytale-server = pkgs.callPackage ./package.nix { };
          hytale-setup = pkgs.callPackage ./setup.nix { };
          default = hytale-server;
        };
      })
    // {
      nixosModules.default = import ./module.nix;
      nixosModules.hytale-server = import ./module.nix;
    };
}
