{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  electron,
  makeWrapper,
  bash,
  nodejs,
  git,
  curl,
  jq,
  claude-code,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "personal-ai-infrastructure";
  version = "5.0.0";
  src = fetchFromGitHub {
    owner = "danielmiessler";
    repo = "Personal_AI_Infrastructure";
    tag = "v${finalAttrs.version}";
    hash = "sha256-PLNWzWnAzd2O4u+0vNxzfL1AAEbEtoovLB1/gk1Fzx4=";
  };
  patches = [
    ./patches/0001-skip-bun-management-on-nixos.patch
    ./patches/0002-add-linux-support-to-pulse.patch
    ./patches/0003-add-pulse-package-json.patch
    ./patches/0004-nixos-installer-fixes.patch
    ./patches/0005-fix-validator-spurious-failures.patch
    ./patches/0006-fix-pulse-path-case.patch
    ./patches/0007-fix-prompt-classifier-slash-prefix.patch
    ./patches/0008-fix-installer-paidir-misnaming.patch
    ./patches/0009-fix-remaining-mixed-case-paths.patch
    ./patches/0010-fix-installer-home-literal-expansion.patch
    ./patches/0011-fix-system-prompt-placeholder-substitution.patch
    ./patches/0012-fix-hook-registration.patch
    ./patches/0013-fix-generate-telos-summary-parser.patch
    ./patches/0014-fix-repeatdetection-state-timing.patch
    ./patches/0015-add-root-package-json.patch
    ./patches/0016-add-pai-state-producer.patch
    ./patches/0017-fix-observability-telos-schema.patch
    ./patches/0018-fix-telegram-step-skip-event.patch
    ./patches/0019-fix-pulse-deps-before-manage-install.patch
    ./patches/0020-clear-marker-at-install-complete.patch
    ./patches/0021-add-systemd-user-unit-for-pulse-on-linux.patch
  ];
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bun nodejs git curl jq electron claude-code ];
  # No build step — PAI is config files + a Bun/Electron setup wizard.
  dontBuild = true;
  dontConfigure = true;
  installPhase = ''
    runHook preInstall
    # Install the release template into the Nix store.
    install -dm755 $out/share/personal-ai-infrastructure
    cp -r Releases/v${finalAttrs.version}/.claude $out/share/personal-ai-infrastructure/

    # Strip Cursor IDE editor metadata. Upstream PAI v5.0.0 commits .cursor/
    # directories under PULSE/Observability and two skills/*/Tools paths,
    # each containing a relative symlink ../../CLAUDE.md. The wrapper's
    # cp -r + chmod -R rewrites those targets as absolute self-loops in
    # the user's tree, and Bun's fs walk crashes Pulse with ELOOP on first
    # encounter. Editor configs have zero runtime relevance — strip at
    # build time so the user tree never receives them.
    find $out/share/personal-ai-infrastructure -type d -name '.cursor' \
      -exec rm -rf {} + 2>/dev/null || true

    # Defensive: delete any broken symlinks (-xtype l matches symlinks whose
    # target does not resolve). PAI has shipped broken symlinks before
    # (issues #664, #823, #880, plus the v5.0 .cursor case). When the next
    # upstream release introduces a similar relative-target symlink that
    # breaks under cp -r relocation, this catches it at build time and
    # prevents Bun fs.watch / fs.readdir from encountering an ELOOP. Only
    # broken links are removed; valid symlinks stay intact.
    find $out/share/personal-ai-infrastructure -xtype l -delete 2>/dev/null || true

    # Install the wrapper script.
    install -dm755 $out/bin
    cat > $out/bin/pai << 'WRAPPER'
    #!/@bash@/bin/bash
    set -euo pipefail
    export PATH="@bun@/bin:@nodejs@/bin:@git@/bin:@curl@/bin:@jq@/bin:@claude-code@/bin:$PATH"

    # Deterministic NixOS marker. The upstream installer's NixOS-conditional
    # branches read this — replaces the broken `process.env.NIX_STORE` runtime
    # check (NIX_STORE is build-time-only and is empty in user-shell runtime).
    export PAI_NIX_INSTALL=1

    # Version string the patched wizard uses to write `.pai-version` at the
    # install_complete broadcast (patch 0020). Cleanup happens at the
    # logical install-complete moment instead of waiting for the user to
    # close the GUI window. The wrapper's post-install cleanup below stays
    # as an idempotent fallback.
    export PAI_NIX_VERSION="@version@"

    PAI_SHARE="@out@/share/personal-ai-infrastructure/.claude"
    PAI_MARKER="$HOME/.claude/.pai-version"
    PAI_INSTALLING="$HOME/.claude/.pai-installing"

    # Remove stale pai aliases from shell rc files.
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      if [ -f "$rc" ] && grep -q "alias pai=" "$rc"; then
        sed -i '/# PAI alias/d;/alias pai=/d' "$rc"
      fi
    done

    # Auto-install or upgrade if needed.
    pai_install() {
      if [ -f "$PAI_INSTALLING" ]; then
        echo "⚠  A previous PAI install was interrupted."
        echo "   Run 'pai --force-install' to retry, or 'pai --skip-install' to launch anyway."
        exit 1
      fi

      if [ -d "$HOME/.claude" ]; then
        BACKUP="$HOME/.claude-backup-$(date +%Y%m%d-%H%M%S)"
        echo "Backing up existing ~/.claude to $BACKUP"
        mv "$HOME/.claude" "$BACKUP"
      fi

      echo "Installing PAI v@version@ to ~/.claude ..."
      # ── Race-safe install copy ─────────────────────────────────────
      # Why `cp -rT` instead of `cp -r`:
      # The user runs `pai --force-install` from inside a live Claude
      # Code session. Claude Code writes session logs to
      # `~/.claude/projects/<slug>/<uuid>.jsonl` continuously — every
      # tool call and message lands there. If even one write happens
      # in the millisecond window between `mv "$HOME/.claude"
      # "$BACKUP"` above and the next `cp` below, Claude Code
      # silently recreates `~/.claude/projects/<slug>/` to land its
      # next log line. With plain `cp -r SRC DEST`, when DEST exists
      # cp nests: `~/.claude/.claude/install.sh`, `~/.claude/.claude/
      # PAI/PAI-Install/...`, etc. The wizard then can't find
      # `$HOME/.claude/install.sh`, `bash: install.sh: No such file or
      # directory` returns 127, and `.pai-installing` stays behind
      # forever. The user sees "previous install was interrupted" on
      # every launch and has no way out except --force-install — which
      # falls into the exact same race.
      #
      # `cp -rT` (GNU --no-target-directory) treats DEST as a final
      # path, not a parent — copies SRC's contents into DEST whether
      # DEST pre-exists or not. Concurrent claude session writes to
      # `~/.claude/projects/` survive (cp doesn't touch unrelated
      # subtrees) and the release tree lands at the correct depth.
      mkdir -p "$HOME/.claude"
      cp -rT "$PAI_SHARE" "$HOME/.claude"
      chmod -R u+w "$HOME/.claude"

      # ── Expand ''${HOME}/$HOME literals in settings.json ──────────────
      # Claude Code passes settings.json `env` values to subprocesses
      # AS-IS — it does NOT shell-expand ''${HOME} before propagating to
      # statusline / hooks / Bash tool subprocess env. Result: the
      # statusline (cwd = wherever the user launched claude, e.g.
      # /home/ai) reads PAI_DIR="''${HOME}/.claude/PAI" literally and
      # `mkdir -p` creates a literal `''${HOME}` directory in cwd, six
      # characters wide ($, {, H, O, M, E, }). Symptom in the wild:
      # `/home/ai/''${HOME}/.claude/PAI/.quote-cache`, `…/MEMORY/STATE/
      # learning-cache.sh`, model/location/weather-caches.
      #
      # Patch 0010 (upstream #1124) fixes the *installer's* output —
      # but the bug fires from the release-shipped settings.json
      # *before* the installer ever rewrites it (concurrent claude
      # session reading settings.json mid-install, or any post-install
      # subprocess invocation). Pre-expanding here defends every
      # subprocess from the moment cp finishes.
      #
      # Scope: replace `''${HOME}` and `$HOME` (both forms upstream
      # ships) with the user's real home path. Hook command paths
      # also use `$HOME/.claude/hooks/...` — substituting to absolute
      # is benign (Claude Code accepts absolute paths and skips its
      # own expansion step). Other settings tokens (''${PAI_DIR},
      # ''${PROJECTS_DIR}) are not touched.
      sed -i \
        -e "s|\''${HOME}|$HOME|g" \
        -e "s|\$HOME|$HOME|g" \
        "$HOME/.claude/settings.json"

      # ── Reliable install lifecycle ──────────────────────────────────
      # Marker semantics: .pai-installing exists for the duration of the
      # install AND is deliberately preserved on any non-clean exit
      # (install.sh non-zero, signal, crash). It is the "something went
      # wrong, investigate before retrying" signal — clearing it would
      # mask real failures and let bad installs silently re-run on every
      # launch. Only a confirmed-successful install (install.sh exit 0)
      # clears the marker AND writes .pai-version. Recovery from a stuck
      # marker is the explicit `pai --force-install` flag.
      #
      # The bug this design fixes: previously the wrapper ran with
      # `set -euo pipefail` for the entire install body, so if ANY
      # subprocess after install.sh exited non-zero (npm install, bun
      # install, a sed on a hardened rc file), the script aborted before
      # `rm -f $PAI_INSTALLING` ran on the success path. The trap printed
      # "interrupted" but did nothing useful. Net effect: install.sh
      # could complete cleanly yet still leave a stuck marker behind,
      # forcing --force-install on the next launch. The fix is to drop
      # `set -e` for the install body so the success-path cleanup is
      # always reachable, and to gate that cleanup on install.sh's exit.
      touch "$PAI_INSTALLING"
      trap 'echo ""; echo "⚠  Install interrupted. Run pai --force-install to retry."' EXIT

      set +e

      # Install electron JS deps and use Nix-provided electron binary.
      cd "$HOME/.claude/PAI/PAI-Install/electron"
      # Keep stderr visible — a silent npm install failure here means the
      # GUI installer can't load and the user has no idea why.
      npm install --ignore-scripts
      mkdir -p node_modules/electron/dist
      printf "electron" > node_modules/electron/path.txt
      ln -sf "@electron@/bin/electron" node_modules/electron/dist/electron

      # Install root PAI dependencies (yaml for PatternInspector hook, plus
      # shared deps used by skills and tools). Bun's directory-walking
      # resolution picks these up from any importer in the tree.
      # Stderr is intentionally NOT suppressed: a transient registry
      # timeout silently leaves node_modules empty, and downstream
      # symptoms (hooks crashing on `import "yaml"`) are then orders of
      # magnitude harder to diagnose than the original error message.
      cd "$HOME/.claude"
      if ! bun install; then
        echo ""
        echo "⚠  Root dependency install failed — see error above."
        echo "   Some hooks/tools may not work until you run:"
        echo "     cd ~/.claude && bun install"
        echo ""
      fi

      # Install Pulse daemon dependencies. Pulse will not start without
      # smol-toml + grammy + jose + minisearch + yaml — when any of
      # those are missing, manage.sh launches bun, bun crashes on the
      # import, port 31337 stays unbound, and the validator's "Pulse
      # not reachable" check fires. Stderr stays visible AND we verify
      # smol-toml landed (the canary; it's the first import in pulse.ts
      # so its absence is what produces the user-visible error).
      cd "$HOME/.claude/PAI/PULSE"
      if ! bun install; then
        echo ""
        echo "⚠  Pulse dependency install failed — see error above."
        echo "   Pulse will not start. To retry:"
        echo "     cd ~/.claude/PAI/PULSE && bun install"
        echo "     bash ~/.claude/PAI/PULSE/manage.sh restart"
        echo ""
      elif [ ! -d "$HOME/.claude/PAI/PULSE/node_modules/smol-toml" ]; then
        echo ""
        echo "⚠  Pulse dependency install completed but node_modules is incomplete"
        echo "   (smol-toml missing — Pulse will crash on import)."
        echo "   To retry:"
        echo "     cd ~/.claude/PAI/PULSE && rm -rf node_modules && bun install"
        echo "     bash ~/.claude/PAI/PULSE/manage.sh restart"
        echo ""
      fi

      # Drop to a CWD the wizard won't yank out from under us before
      # invoking install.sh. The wizard's `moveExistingClaudeToBackup`
      # (PAI-Install/engine/actions.ts) does `mv ~/.claude →
      # ~/.claude-backup-{ts}` partway through the install. The wrapper
      # has been sitting in `~/.claude/PAI/PULSE` since the previous
      # `bun install` step, so after the mv our CWD is a path that no
      # longer exists. Symptoms: `shell-init: error retrieving current
      # directory: getcwd: cannot access parent directories` warnings
      # printed twice from bash subshells, and — fatally — claude-code's
      # Node entrypoint calls `process.cwd()` early in startup and dies
      # with `Error: ENOENT: process.cwd failed ... uv_cwd` on the very
      # `exec claude` at the end of pai_install. $HOME is the safest
      # destination: it always exists, never moves, and is where any
      # interactive `pai` would naturally start anyway.
      cd "$HOME"

      # Run upstream install.sh; capture its exit code so a failure here
      # is reflected explicitly rather than aborting the wrapper.
      bash "$HOME/.claude/install.sh"
      local install_exit=$?

      # Remove any pai alias install.sh may have written. `|| true`
      # so a read-only rc on a hardened system can't sink the install.
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
          sed -i '/# PAI alias/d;/alias pai=/d' "$rc" 2>/dev/null || true
        fi
      done

      set -e

      if [ "$install_exit" -eq 0 ]; then
        # Confirmed success: write version marker, clear in-progress
        # marker, disarm the EXIT trap (the install completed normally,
        # not "interrupted"). Order matters: write .pai-version BEFORE
        # removing .pai-installing so a SIGKILL between the two never
        # leaves the wrapper in a "no marker, no version" state that
        # would trigger a fresh reinstall on the next launch.
        echo "@version@" > "$PAI_MARKER"
        rm -f "$PAI_INSTALLING"
        trap - EXIT
      else
        # Failure: leave .pai-installing in place so the next launch
        # surfaces the prior failure. Disarm the EXIT trap so we emit
        # our own (more specific) message instead of the generic one.
        trap - EXIT
        echo ""
        echo "⚠  install.sh exited with code $install_exit"
        echo "   .pai-installing left in place; run 'pai --force-install' to retry."
        exit "$install_exit"
      fi
    }

    # Handle flags.
    case "''${1:-}" in
      --force-install)
        rm -f "$PAI_INSTALLING"
        pai_install
        exec claude "''${@:2}"
        ;;
      --skip-install)
        exec claude "''${@:2}"
        ;;
    esac

    if [ ! -f "$PAI_MARKER" ]; then
      pai_install
    elif [ "$(cat "$PAI_MARKER")" != "@version@" ]; then
      echo "PAI upgrade detected ($(cat "$PAI_MARKER") → @version@)"
      pai_install
    fi

    # Launch claude-code with PAI configuration.
    exec claude "$@"
    WRAPPER
    substituteInPlace $out/bin/pai \
      --replace '@out@' "$out" \
      --replace '@bash@' "${bash}" \
      --replace '@bun@' "${bun}" \
      --replace '@nodejs@' "${nodejs}" \
      --replace '@git@' "${git}" \
      --replace '@curl@' "${curl}" \
      --replace '@jq@' "${jq}" \
      --replace '@electron@' "${electron}" \
      --replace '@claude-code@' "${claude-code}" \
      --replace '@version@' "${finalAttrs.version}"
    chmod +x $out/bin/pai
    runHook postInstall
  '';
  meta = with lib; {
    description = "PAI — Life Operating System built on Claude Code";
    longDescription = ''
      Personal AI Infrastructure (PAI) is a Life Operating System for Claude Code.
      It adds persistent memory, skills, event-driven hooks, goal tracking (TELOS),
      a continuous-learning loop, and a Digital Assistant identity layer.
      Run `pai` to get started — it auto-installs on first run, then launches
      Claude Code with all PAI systems active.
    '';
    homepage = "https://ourpai.ai/";
    changelog = "https://github.com/danielmiessler/Personal_AI_Infrastructure/blob/v${finalAttrs.version}/Releases/v${finalAttrs.version}/README.md";
    # PAI itself (bundled tarball) is MIT, copyright Daniel Miessler.
    # The pai-nix packaging contribution (this derivation, patches, ISAs) is
    # AGPL-3.0-only. End users get the combined work.
    license = with licenses; [ mit agpl3Only ];
    platforms = platforms.unix;
    mainProgram = "pai";
  };
})
