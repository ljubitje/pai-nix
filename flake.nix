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
        environment.systemPackages = [
          self.packages.${pkgs.stdenv.hostPlatform.system}.default
          # LifeOS ships ~600 .ts files (hooks, LIFEOS/TOOLS, skill tools) that bun
          # executes by stripping types — so nothing ever type-checks them unless a
          # checker exists. Without this, `tsc` is absent and the only way to run one
          # is `bunx tsc`, which refetches typescript over the network per invocation.
          # Found 2026-09-06: on a live install 612 .ts files, 84 under any tsconfig,
          # and the first check ever run surfaced an already-dead tool.
          pkgs.typescript

          # `fabric -y <url>` is the documented transcript path across six skills in sixteen
          # files (Research, which names it Tier-1 for YouTube even when YOUTUBE_API_KEY is
          # set, plus ExtractWisdom, Fabric, Aphorisms, Prompting and Remotion), and in one
          # tool, LIFEOS/TOOLS/GetTranscript.ts, which execFileSyncs the bare name. Counted
          # 2026-09-10, after a first pass of this comment missed Remotion and filed the tool
          # as a skill. Upstream ships the pattern DATA but never the binary, so on this
          # install every one of those paths died at ENOENT and the fallback was scraping the
          # YouTube page — which the Fabric skill explicitly forbids. Measured 2026-09-10:
          # `which fabric` empty, no store path, transcript unobtainable for a plain video.
          # The attr is `fabric-ai` (Go, same author as LifeOS upstream); `pkgs.fabric` does
          # not exist in this pin, and mainProgram is `fabric`, which is the name every call
          # site uses. No API key is needed for the `-y`/`-u` legs, which read captions and
          # never call an LLM, but the config FILE still has to exist; the tmpfiles rule
          # below creates it, and that block explains why.
          pkgs.fabric-ai
          # yt-dlp is the keyless floor under the same need: `--write-auto-subs --skip-download`
          # pulls captions without touching the media, so subtitle extraction survives fabric
          # breaking on a YouTube player change (its usual failure mode) and covers the sites
          # fabric has no extractor for. Also the only path to AudioEditor/Tools/Transcribe.ts
          # (Whisper) for a video with no published captions, which needs the audio on disk.
          pkgs.yt-dlp
        ];

        # fabric refuses to run without ~/.config/fabric/.env, INCLUDING the `-y`
        # transcript leg, which reads captions and needs no credential at all. Measured
        # 2026-09-10 on 1.4.459: absent file + stdin at /dev/null exits 1 with
        # "error loading .env file"; an empty file makes the same call exit 0 with a
        # 14 KB transcript. So the floor for a fresh install is the file existing, not
        # any key being in it, and nothing in LifeOS's own setup creates it.
        #
        # tmpfiles `f` (not `f+`) creates only when absent and leaves an existing file
        # untouched — calibrated both ways rather than trusted: `f` over a 15-byte .env
        # left all 15 bytes, and over a deleted one produced an empty 0600 file. So a
        # user who already has keys in there keeps them across every rebuild. 0600
        # because upstream's own use of this file is API keys.
        #
        # Scope: the missing-config error only. A SECOND, UNFIXED defect was measured the
        # same day and is left standing deliberately, so it is recorded here rather than
        # rediscovered: with stdin left open, fabric drains fd 0 to EOF before doing
        # anything and blocks forever, zero bytes on stdout AND stderr, with or without
        # .env. A tty is a character device, so an interactive user never sees it; every
        # programmatic caller does. Workaround at any call site: give it `< /dev/null`.
        #
        # A patch narrowing that read to "no explicit -y/-u/-q source given" was written,
        # built, and REVERTED on evidence, because piping content alongside a source flag
        # is a real fabric capability and the patch ate it silently. Measured on 1.4.459,
        # `printf 'MARKER' | fabric -y URL --dry-run`:
        #   unpatched -> exit 0, MARKER present, 14516 bytes, goes through the model
        #   patched   -> exit 0, MARKER gone,    14282 bytes, model never called
        # With Message left empty, IsChatRequest() flips false and fabric prints the raw
        # text and exits 0. That is the same class of silent failure the patch set out to
        # remove, so it was the wrong trade. A correct fix bounds the WAIT rather than
        # skipping the read (poll fd 0 with a deadline), and needs a timing constant chosen
        # in upstream's terms, not ours; Klemen's cut 2026-09-10 was to drop it and keep
        # this note.
        systemd.user.tmpfiles.rules = [ "f %h/.config/fabric/.env 0600 - - -" ];

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
