{
  description = "Personal AI Infrastructure (PAI)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pinned solely for claude-code 2.1.170 (Fable 5 model gate). nixos-unstable
    # channel still ships 2.1.161 (master landed 2.1.170 on 2026-06-09); this rev
    # is the exact "claude-code: 2.1.161 -> 2.1.170" bump commit. When the channel
    # catches up to >= 2.1.170, drop this input and revert claude-code to
    # `pkgs.claude-code`.
    nixpkgs-claude.url = "github:NixOS/nixpkgs/5900fe6cf8eca7dc124309029a50c7f80e90b6c9";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, nixpkgs-claude, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        claude-code = (import nixpkgs-claude { inherit system; config.allowUnfree = true; }).claude-code;
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
