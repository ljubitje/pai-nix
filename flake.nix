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

        # Pulse runs as a per-user systemd service. Upstream's manage.sh generates
        # a ~/.config/systemd/user unit at install time with a macOS/Ubuntu PATH
        # (__HOME__/.bun/bin:/usr/local/bin:/usr/bin:/bin) that has NO bash/bun on
        # NixOS → Bun.which("bash") fails, the "/bin/bash" fallback is absent, and
        # every cron job that shells out dies with ENOENT '/bin/bash' (observed
        # 2026-08-11: cost-aggregation/healthcheck/poller stuck since migration).
        # We own the unit declaratively instead: %h keeps it user-agnostic, and
        # `path` puts the real store paths in PATH. The companion manage.sh patch
        # (f-pulse-unit-nixos-skip) makes the installer defer to this on NixOS so
        # a ~/.config unit never shadows it.
        systemd.user.services."com.lifeos.pulse" = {
          description = "LifeOS Pulse — unified daemon (cron, voice, observability, hooks)";
          # (no `after = network.target` — it is a system target, absent from the
          # per-user manager, so the ordering dep would be silently ignored.)
          wantedBy = [ "default.target" ];
          # claude-code included so Pulse cron jobs' Bun.which("claude") resolves
          # under the unit's (replaced, not appended) PATH — ISC-45 for the Pulse consumer.
          path = [ pkgs.bash pkgs.bun pkgs.git pkgs.coreutils pkgs.curl self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code ];
          serviceConfig = {
            Type = "simple";
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/.claude/LIFEOS/PULSE/logs";
            ExecStart = "${pkgs.bun}/bin/bun run pulse.ts";
            WorkingDirectory = "%h/.claude/LIFEOS/PULSE";
            Restart = "on-failure";
            RestartSec = 30;
            TimeoutStopSec = 5;
            Environment = "NEXT_TELEMETRY_DISABLED=1";
            StandardOutput = "append:%h/.claude/LIFEOS/PULSE/logs/pulse-stdout.log";
            StandardError = "append:%h/.claude/LIFEOS/PULSE/logs/pulse-stderr.log";
          };
        };
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        # SoT: lifeos-nix owns the claude-code version pin (vendored derivation +
        # manifest.json), not raw nixpkgs. Bump: ./pkgs/tools/misc/claude-code/update.sh <version>.
        claude-code = pkgs.callPackage ./pkgs/tools/misc/claude-code { };
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
