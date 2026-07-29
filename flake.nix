{
  description = "NixOS module and packages for running a Hytale dedicated server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      hytaleModule = import ./module.nix;
    in
    {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in rec {
          hytale-server = pkgs.callPackage ./package.nix { };
          hytalectl = pkgs.callPackage ./console.nix { };
          default = hytale-server;
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # Hytale's downloader zip only ships hytale-downloader-linux-amd64,
          # so the bootstrap installer is x86_64-only. hytale-server and
          # hytalectl remain multi-arch.
          hytale-setup = pkgs.callPackage ./setup.nix { };
        });

      nixosModules.hytale-server = hytaleModule;
      nixosModules.default = hytaleModule;
    };
}
