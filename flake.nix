{
  description = "Personal AI Infrastructure (PAI)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    let
      # Compat alias (F6): /etc/nixos imports `pai.nixosModules.pai`. The old name
      # stays pointing at the same module so a downstream flake update never breaks.
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
        # Compat alias (F6): old output name kept so pinned consumers keep resolving.
        packages.personal-ai-infrastructure = lifeos;
        # Convenience: `nix develop` drops you into a shell with bun + git ready.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.bun pkgs.git ];
        };
      }
    ) // {
      nixosModules.lifeos = lifeosModule;
      nixosModules.pai = lifeosModule; # compat alias (F6)
    };
}
