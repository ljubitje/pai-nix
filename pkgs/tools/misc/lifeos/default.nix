# lifeos-nix — packages upstream LifeOS v7.1.1 as a Nix derivation.
# Rebased from the v5.0.0 PAI packaging. Privacy-hardened + reproducible-vendored.
# System of record: pai-nix/ISA.md. Privacy-hardened (F4: ElevenLabs + self-update egress
# killed) on top of the vendored-deps skeleton + f2 deps-model patch.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  makeWrapper,
  bash,
  nodejs,
  git,
  claude-code,
}:
let
  version = "7.40.4.0"; # <upstream LifeOS version>.<lifeos-nix packaging patch level>; .0 = fresh upstream base (7.1.1.1 → 7.40.4 migration, patches re-triaged: 19→13, 6 DISSOLVE dropped)
  src = fetchFromGitHub {
    owner = "danielmiessler";
    repo = "LifeOS";
    rev = "be9e8ef889f00a29f4fd677dee4772fdf32e07ce"; # v7.40.4 release tag (2026-08-27 migration re-pin from v7.1.1 a4e8e74)
    hash = "sha256-+tgdaJuKQx2uPIS0xWiQWu7hLNRcVV/rfACSr7OcaXU=";
  };

  # ── (b) reproducible-vendored deps ──────────────────────────────────────────
  # One fixed-output derivation per package.json tree. --ignore-scripts (no
  # postinstall beacons, invisible to the hash), --frozen-lockfile (no float),
  # NEXT_TELEMETRY_DISABLED (next build phones home). Lockless trees (root/tools/
  # tokenxray) get a committed lock injected; pulse/obs carry their own in src.
  # Hashes captured x86_64-linux, reproducibility-verified (vendor-locks/HASHES.txt).
  vendorTree = { name, subdir, hash, lockFile ? null }: stdenvNoCC.mkDerivation {
    name = "lifeos-deps-${name}";
    inherit src;
    nativeBuildInputs = [ bun ];
    buildPhase = ''
      export HOME=$TMPDIR NEXT_TELEMETRY_DISABLED=1
      ( cd LifeOS/install/${subdir}
        ${lib.optionalString (lockFile != null) "cp ${lockFile} bun.lock"}
        bun install --frozen-lockfile --ignore-scripts )
    '';
    installPhase = "cp -r LifeOS/install/${subdir}/node_modules $out";
    # Keep raw bun output: patchShebangs would inject build-host store refs
    # (FOD-illegal) and pin shebangs to the builder — non-portable for a shipped tree.
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = hash;
  };
  deps = {
    root      = vendorTree { name = "root";      subdir = ".";                          hash = "sha256-PAJAbFNw7jFdQDuguSUfNOFRGJzL49P05r1fZEoiO3c="; lockFile = ./vendor-locks/root.bun.lock; };
    tools     = vendorTree { name = "tools";     subdir = "LIFEOS/TOOLS";               hash = "sha256-FIBTFDHuFW6WyDSlNXr6QMi76eaFLaxKZgKwNMay5/E="; lockFile = ./vendor-locks/tools.bun.lock; };
    pulse     = vendorTree { name = "pulse";     subdir = "LIFEOS/PULSE";               hash = "sha256-2zjzLOg6UPkQa86IMj+OPiB69IQOHZhuhtuZPanKU+o="; };
    obs       = vendorTree { name = "obs";       subdir = "LIFEOS/PULSE/Observability"; hash = "sha256-dzvmq20UIVDwc9Ui0nrPzckwIH9zT5pADgYaeTI/aRk="; };
    tokenxray = vendorTree { name = "tokenxray"; subdir = "LIFEOS/TOOLS/TokenXray";      hash = "sha256-VZFZ8RyMavdtBaUnkswSlv2tBcPEteCO5EOqb60HJlI="; lockFile = ./vendor-locks/tokenxray.bun.lock; };
    # Skill-tool trees whose .ts run IN-PLACE (direct package imports) — vendored so they work under Nix.
    # (7.40.4 migration: of 8 candidate skill trees, only these 2 import deps in-place; Telos Dashboard/Report +
    #  Remotion are runtime-instantiated templates [cp + `bun install`], LifeOS/install is the installer path — none need baking.)
    evals     = vendorTree { name = "evals";     subdir = "skills/Evals";                     hash = "sha256-bssfF6GwCBLgE9EiYAdS5EEccnc+MU00ONHheRKqG1E="; lockFile = ./vendor-locks/evals.bun.lock; };
    prompting = vendorTree { name = "prompting"; subdir = "skills/Prompting/Templates/Tools";  hash = "sha256-q7zyO94vL/Rw7KfF06YDbTb1E7ed0DFFa3tVeqNTnXU="; };
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "lifeos";
  inherit version src;

  patches = [
    ./patches/f2-deploycore-skip-npm.patch       # RedTeam CR-3: stop runtime bun install (deps vendored+bridged)
    ./patches/f4-a-neutralize-update-check.patch # f4-A: no external update-check (updates via Nix)
    ./patches/f4-b-elevenlabs-killswitch.patch   # Klemen B: ElevenLabs egress dead regardless of key
    ./patches/f4-c-pulse-disable-default-active.patch # RedTeam (a) + LOS-recon: 6 egress modules default-off (voice/telegram/morning-brief + local_intelligence/airgradient-poll/memory-consolidation)
    ./patches/0029-fix-pulse-graceful-shutdown-on-sigterm.patch # F3 re-cut: Pulse graceful SIGTERM (no 60s hang / mid-op SIGKILL)
    ./patches/f-derived-watch-wire.patch    # f-derived-watch: wire DerivedWatch (inotify on-change regen) into pulse.ts loadModules
    ./patches/f-derived-watch-config.patch  # f-derived-watch: [derived_watch] enabled=true in base PULSE.toml
    ./patches/f-launcher-cwd-default.patch  # f-launcher-cwd: `lifeos` stays in cwd by default (dev-first); --claude-dir/-c opts into ~/.claude
    ./patches/f-mergesettings-preserve-hooks.patch # f-mergesettings: MergeSettings re-attaches hooks from canonical hooks/hooks.json (else user overlay → SessionStart array dropped 5→0)
    ./patches/f-pulse-unit-nixos-skip.patch # f-pulse-unit: on NixOS skip installer unit-gen; nix module owns com.lifeos.pulse.service (correct PATH — else jobs ENOENT /bin/bash)
    ./patches/f-projects-dormant.patch # f-projects-dormant: do not force-load USER/PROJECTS.md (unbounded growth → ~53% startup ctx); opt-in via manual uncomment, on-demand via ContextSearch
    ./patches/f-projects-no-memory-writes.patch # f-projects-no-mem-writes: retire memory machinery around PROJECTS.md (reviewer proposals/tier-b/GC/freshness) — companion to dormant
    ./patches/f-mergesettings-hooks-overlay.patch # f-mergesettings-hooks-overlay: compose LIFEOS/USER/CONFIG/hooks.user.json over official hooks.json (our hooks leave the official file → syncs cleanly, no B∩C)
  ];

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bun nodejs bash git claude-code ]; # electron/curl/jq dropped
  dontBuild = true;
  dontConfigure = true;
  # Ship the skill tree with upstream's portable `#!/usr/bin/env bun` shebangs intact.
  # Without this, stdenv's fixupPhase auto-runs patchShebangs over $out and rewrites
  # them to a builder store path (…/bun-X.Y.Z/bin/bun). That path dies on the next bun
  # bump + `nix-collect-garbage`, ENOENT-ing on-demand skill tools mid-run. env-bun
  # resolves against PATH and stays valid across bumps. The $out/bin/lifeos launcher is
  # substitute-pinned below (@bash@ → ${bash}), not shebang-patched, so it is unaffected.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    # 1) Store-copy the LifeOS skill+runtime payload.
    install -dm755 $out/share/lifeos
    cp -r LifeOS $out/share/lifeos/
    chmod -R u+w $out/share/lifeos

    # 1b) DerivedWatch — Linux event-driven regen module (launchd WatchPaths equivalent).
    # Not in upstream (macOS uses launchd); shipped by lifeos-nix, wired into pulse.ts
    # loadModules via the derived-watch patch. inotify + debounce, runs in the Pulse process.
    install -m 0644 ${./files/derived-watch.ts} \
      $out/share/lifeos/LifeOS/install/LIFEOS/PULSE/modules/derived-watch.ts

    # 1c) payload-sync — lifeos-nix store→live durability tool. Deploy is copy-missing-only,
    # so a rebuilt store never refreshes EXISTING live files; this classifies each and, with
    # --apply, deterministically syncs changes into ~/.claude (backup + verify). lifeos-nix-
    # specific (vanilla edits live directly, no store↔live split) → shipped, not patched.
    install -m 0755 ${./files/payload-sync.ts} \
      $out/share/lifeos/LifeOS/install/LIFEOS/TOOLS/payload-sync.ts

    # 2) Place vendored node_modules per tree (bridged into $CFG at runtime).
    cp -r ${deps.root}      $out/share/lifeos/LifeOS/install/node_modules
    cp -r ${deps.pulse}     $out/share/lifeos/LifeOS/install/LIFEOS/PULSE/node_modules
    cp -r ${deps.obs}       $out/share/lifeos/LifeOS/install/LIFEOS/PULSE/Observability/node_modules
    cp -r ${deps.tools}     $out/share/lifeos/LifeOS/install/LIFEOS/TOOLS/node_modules
    cp -r ${deps.tokenxray} $out/share/lifeos/LifeOS/install/LIFEOS/TOOLS/TokenXray/node_modules
    # Skill-tool trees that run in-place (7.40.4 vendor pass — Evals + Prompting tools import deps directly).
    cp -r ${deps.evals}     $out/share/lifeos/LifeOS/install/skills/Evals/node_modules
    cp -r ${deps.prompting} $out/share/lifeos/LifeOS/install/skills/Prompting/Templates/Tools/node_modules
    chmod -R u+w $out/share/lifeos

    # 2b) Build the Observability dashboard → static export (out/), fully offline
    # (proven: the build exits 0 inside a deny-all netns). The SWC native binary is
    # vendored, there is no next/font/google fetch, telemetry is disabled. Pin the
    # build ID — upstream's Date.now()-based generateBuildId would make the output
    # non-reproducible — and drop the .next cache so only the static `out/` ships.
    substituteInPlace $out/share/lifeos/LifeOS/install/LIFEOS/PULSE/Observability/next.config.ts \
      --replace-fail 'build-''${Date.now()}' 'build-lifeos'
    ( cd $out/share/lifeos/LifeOS/install/LIFEOS/PULSE/Observability
      export HOME=$TMPDIR NEXT_TELEMETRY_DISABLED=1 PATH=${nodejs}/bin:${bun}/bin:$PATH
      # Run next's JS entrypoint directly with store node — the vendored `.bin/next`
      # shebang is `/usr/bin/env node`, which the pure build sandbox lacks, and we
      # deliberately do NOT patchShebangs the shipped tree (would pin builder refs).
      ${nodejs}/bin/node node_modules/next/dist/bin/next build
      rm -rf .next tsconfig.tsbuildinfo )

    # 3) Editor-junk / broken-symlink / *.orig strip (retained from v5.0).
    find $out/share/lifeos -type d -name '.cursor' -exec rm -rf {} + 2>/dev/null || true
    find $out/share/lifeos -xtype l -delete 2>/dev/null || true
    find $out/share/lifeos -name '*.orig' -delete 2>/dev/null || true

    # 3b) Normalize bash shebangs to env-portable form (companion to dontPatchShebangs +
    # the upstream `#!/usr/bin/env bun` policy). NixOS has NO /bin/bash; upstream ships some
    # .sh with `#!/bin/bash`, which ENOENTs for DIRECTLY-executed scripts (ContextReduction.hook.sh
    # via CC hook, LIFEOS_StatusLine.sh via statusLine). /usr/bin/env is guaranteed and bash is on
    # the CC-inherited PATH (more reliable than the env-bun already trusted). Scope *.sh only —
    # `#!/bin/bash` also appears in Fabric pattern DATA (content, never executed). Cross-platform safe
    # (macOS keeps working). Council-ratified 2026-08-24 (#1: sed + loud-fail assertion).
    find $out/share/lifeos -type f -name '*.sh' \
      -exec sed -i '1s@^#!/bin/bash$@#!/usr/bin/env bash@' {} +
    # Loud fail-safe: fail the build if any executed .sh still ships a dead /bin/bash shebang.
    # errexit-independent (explicit `exit 1`, NOT `! grep` — bash exempts `!`-negation from set -e),
    # and LINE-1 scoped to match the sed above (an unanchored grep would false-fail on a `#!/bin/bash`
    # that legitimately appears mid-file, e.g. a heredoc that emits a bootstrap script).
    bad=$(find $out/share/lifeos -type f -name '*.sh' \
      -exec sh -c 'head -1 "$1" | grep -q "^#!/bin/bash$" && echo "$1"; true' _ {} \; || true)
    if [ -n "$bad" ]; then
      echo "ERROR: dead /bin/bash shebang survived normalization (NixOS has no /bin/bash):" >&2
      printf '%s\n' "$bad" >&2
      exit 1
    fi

    # 3c) MANIFEST.sha256 — official-file fingerprints for payload-sync A/C detection (B2).
    # payload-sync distinguishes official files (safe to sync store→live) from ours (leave/
    # merge) by hash: on the list → official, off it → ours. Comprehensive: EVERY shipped
    # payload file EXCEPT vendored deps, generated build output, and the user-data zone
    # (USER/MEMORY are scaffolded per-install, never synced). MUST be the last payload
    # mutation so hashes reflect the final bytes (post-shebang-normalization). Reproducible:
    # %P (no leading ./) + LC_ALL=C sort → stable order; standard `sha256sum` format (-c verifiable).
    ( cd $out/share/lifeos/LifeOS/install
      find . -type f \
        ! -path '*/node_modules/*' ! -path '*/Observability/out/*' ! -path '*/.next/*' \
        ! -path './USER/*' ! -path '*/USER/*' ! -path '*/MEMORY/*' \
        ! -name MANIFEST.sha256 \
        -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256 )

    # 4) The `lifeos` launcher on PATH (no rc mutation, no alias).
    install -dm755 $out/bin
    cat > $out/bin/lifeos << 'WRAP'
    #!@bash@/bin/bash
    set -euo pipefail
    export PATH="@bun@/bin:@nodejs@/bin:@git@/bin:@claude-code@/bin:$PATH"
    export NEXT_TELEMETRY_DISABLED=1
    SKILL="@out@/share/lifeos/LifeOS"
    CFG="''${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    WANT="$(cat "$SKILL/install/LIFEOS/VERSION")"
    MARKER="$CFG/LIFEOS/VERSION"

    # FREEZE-GUARD: refuse a pre-7.x PAI/LifeOS tree (structurally protects a 5.0.0 dev box).
    if [ -e "$CFG/.pai-version" ] || [ -d "$CFG/PAI" ]; then
      echo "lifeos: refusing — a pre-7.x PAI/LifeOS tree exists at $CFG (install would clobber it)." >&2
      exit 3
    fi

    bridge_node_modules() {
      ln -sfn "$SKILL/install/node_modules"                            "$CFG/node_modules"
      ln -sfn "$SKILL/install/LIFEOS/PULSE/node_modules"               "$CFG/LIFEOS/PULSE/node_modules"
      ln -sfn "$SKILL/install/LIFEOS/PULSE/Observability/node_modules" "$CFG/LIFEOS/PULSE/Observability/node_modules"
      ln -sfn "$SKILL/install/LIFEOS/TOOLS/node_modules"               "$CFG/LIFEOS/TOOLS/node_modules"
      ln -sfn "$SKILL/install/LIFEOS/TOOLS/TokenXray/node_modules"     "$CFG/LIFEOS/TOOLS/TokenXray/node_modules"
      # In-place skill trees whose .ts import deps directly (7.40.4 vendor pass). Bridged
      # here so their vendored node_modules resolve offline — DeployCore's per-tree install
      # is neutralized (f2 step e), so this symlink is the sole delivery path.
      ln -sfn "$SKILL/install/skills/Evals/node_modules"                     "$CFG/skills/Evals/node_modules"
      ln -sfn "$SKILL/install/skills/Prompting/Templates/Tools/node_modules" "$CFG/skills/Prompting/Templates/Tools/node_modules"
    }

    install_core() {
      bun "$SKILL/Tools/DeployCore.ts"      --skill-root "$SKILL" --config-root "$CFG" --apply
      bun "$SKILL/Tools/ScaffoldUser.ts"    --skill-root "$SKILL" --config-root "$CFG" --apply
      bun "$SKILL/Tools/LinkUser.ts"        --skill-root "$SKILL" --config-root "$CFG" --apply
      [ -e "$CFG/CLAUDE.md" ] || install -m 0644 "$SKILL/install/CLAUDE.template.md" "$CFG/CLAUDE.md"
      bun "$SKILL/Tools/InstallSettings.ts" --skill-root "$SKILL" --config-root "$CFG" --apply
      bun "$SKILL/Tools/InstallHooks.ts"    --skill-root "$SKILL" --config-root "$CFG" --apply
      bun "$SKILL/Tools/ActivateImports.ts" --skill-root "$SKILL" --config-root "$CFG" --apply
      bridge_node_modules
      bun "$SKILL/Tools/DeployComponents.ts" --config-root "$CFG" --components statusline,tooltips,spinnerverbs,agents,commands --apply || true
      # Files copied out of the store keep its read-only 444 mode; BOTH write targets —
      # the config-root and the XDG user-config dir ScaffoldUser populates (95 files incl.
      # LIFEOS_CONFIG.toml + CREDENTIALS) — must be user-writable, or config edits and
      # ActivateImports' CLAUDE.md rewrite EACCES. chmod -R ignores symlinks, so the
      # store node_modules bridges stay untouched.
      USERCFG="''${LIFEOS_CONFIG_DIR:-$HOME/.config/LIFEOS}"
      chmod -R u+w "$CFG"
      [ -d "$USERCFG" ] && chmod -R u+w "$USERCFG" || true
      bash "$CFG/LIFEOS/PULSE/manage.sh" install || true
      bun "$CFG/LIFEOS/TOOLS/Doctor.ts" decline voice      || true
      bun "$CFG/LIFEOS/TOOLS/Doctor.ts" decline cloudflare  || true
      bun "$CFG/LIFEOS/TOOLS/Doctor.ts"                     || true
    }

    if [ ! -f "$MARKER" ]; then
      install_core
    elif [ "$(cat "$MARKER" 2>/dev/null || true)" != "$WANT" ]; then
      echo "lifeos: package updated ($(cat "$MARKER") -> $WANT). Upstream migration plan:"
      timeout 30 bun "$CFG/LIFEOS/TOOLS/LifeosUpgrade.ts" --dry-run 2>/dev/null || true
      echo "  (apply wired at the next upstream bump — see ISA F-upgrade.)"
    fi

    exec bun "$CFG/LIFEOS/TOOLS/lifeos.ts" -s "$CFG/LIFEOS/LIFEOS_SYSTEM_PROMPT.md" "$@"
    WRAP
    substituteInPlace $out/bin/lifeos \
      --replace '@bash@' "${bash}" \
      --replace '@bun@' "${bun}" \
      --replace '@nodejs@' "${nodejs}" \
      --replace '@git@' "${git}" \
      --replace '@claude-code@' "${claude-code}" \
      --replace '@out@' "$out"
    chmod +x $out/bin/lifeos

    runHook postInstall
  '';

  meta = with lib; {
    description = "LifeOS — the Life Operating System, packaged for Nix (privacy-hardened, reproducible)";
    homepage = "https://ourlifeos.ai/";
    changelog = "https://github.com/danielmiessler/LifeOS/releases/tag/v${finalAttrs.version}";
    license = with licenses; [ mit agpl3Only ]; # MIT LifeOS + AGPL packaging
    platforms = [ "x86_64-linux" ];              # hash is x86_64-linux-specific; friend is NixOS
    mainProgram = "lifeos";
  };
})
