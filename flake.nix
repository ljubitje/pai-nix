{
  description = "lifeos-nix — LifeOS (the Life Operating System) packaged for Nix, privacy-hardened and reproducible";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    let
      # nixosModule that installs the lifeos package system-wide.
      lifeosModule = { pkgs, system ? pkgs.stdenv.hostPlatform.system, ... }: {
        environment.systemPackages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        claude-code = pkgs.claude-code;
        lifeos = pkgs.callPackage ./pkgs/tools/misc/lifeos {
          inherit claude-code;
        };
      in
      {
        packages.claude-code = claude-code;
        packages.lifeos = lifeos;
        packages.default = lifeos;
        # Convenience: `nix develop` drops you into a shell with bun + git ready.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.bun pkgs.git ];
        };
      }
    ) // {
      nixosModules.lifeos = lifeosModule;
    };
}
