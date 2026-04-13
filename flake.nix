{
  description = "Personal AI Infrastructure (PAI)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        claude-code = pkgs.claude-code;
      in
      {
        packages.claude-code = claude-code;
        packages.default = pkgs.callPackage ./pkgs/tools/misc/personal-ai-infrastructure {
          inherit claude-code;
        };
        packages.personal-ai-infrastructure = pkgs.callPackage ./pkgs/tools/misc/personal-ai-infrastructure {
          inherit claude-code;
        };
        # Convenience: `nix develop` drops you into a shell with bun + git ready.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.bun pkgs.git ];
        };
      }
    ) // {
      nixosModules.pai = { pkgs, system ? pkgs.stdenv.hostPlatform.system, ... }: {
        environment.systemPackages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
      };
    };
}
