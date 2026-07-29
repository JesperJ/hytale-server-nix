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
      # hytale-server and hytale-setup are marked `licenses.unfree` because
      # their purpose is running/installing proprietary Hytale binaries.
      # Configure our own pkgs to accept them so `nix flake check` and
      # `nix build .#hytale-server` work without env vars; downstream
      # consumers still need `nixpkgs.config.allowUnfree = true;` in their
      # own systems to import the module.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: builtins.elem
          (nixpkgs.lib.getName pkg)
          [ "hytale-server" "hytale-setup" ];
      };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
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
