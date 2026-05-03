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
      cp -r "$PAI_SHARE" "$HOME/.claude"
      chmod -R u+w "$HOME/.claude"

      touch "$PAI_INSTALLING"
      trap 'echo ""; echo "⚠  Install interrupted. Run \"pai\" again to retry."' EXIT

      # Install electron JS deps and use Nix-provided electron binary.
      cd "$HOME/.claude/PAI/PAI-Install/electron"
      npm install --ignore-scripts 2>/dev/null
      mkdir -p node_modules/electron/dist
      printf "electron" > node_modules/electron/path.txt
      ln -sf "@electron@/bin/electron" node_modules/electron/dist/electron
      # Install root PAI dependencies (yaml for PatternInspector hook, plus
      # shared deps used by skills and tools). Bun's directory-walking
      # resolution picks these up from any importer in the tree.
      cd "$HOME/.claude"
      bun install 2>/dev/null || echo "Warning: root dependency install failed (non-fatal)"
      # Install Pulse daemon dependencies.
      cd "$HOME/.claude/PAI/PULSE"
      bun install 2>/dev/null || echo "Warning: Pulse dependency install failed (non-fatal)"
      # Run upstream install.sh.
      bash "$HOME/.claude/install.sh"

      # Remove any pai alias install.sh may have written.
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
          sed -i '/# PAI alias/d;/alias pai=/d' "$rc"
        fi
      done

      rm -f "$PAI_INSTALLING"
      trap - EXIT
      echo "@version@" > "$PAI_MARKER"
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
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "pai";
  };
})
