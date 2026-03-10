{
  description = "Personal AI Infrastructure (PAI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.callPackage ./pkgs/tools/misc/personal-ai-infrastructure { };
        packages.personal-ai-infrastructure = pkgs.callPackage ./pkgs/tools/misc/personal-ai-infrastructure { };

        # Convenience: `nix develop` drops you into a shell with bun + git ready.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.bun pkgs.git ];
        };
      }
    );
}
