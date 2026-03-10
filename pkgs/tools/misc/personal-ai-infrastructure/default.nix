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
  claude-code,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "personal-ai-infrastructure";
  version = "4.0.3-nixos";
  src = fetchFromGitHub {
    owner = "ljubitje";
    repo = "Personal_AI_Infrastructure";
    tag = "v${finalAttrs.version}";
    hash = "sha256-muM6Y+lyEqTpgkkJNxy6NzxROaG9uvJTdQwOWzC0eJM=";
  };
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bun nodejs git curl electron claude-code ];
  # No build step — PAI is config files + a Bun setup wizard.
  dontBuild = true;
  dontConfigure = true;
  installPhase = ''
    runHook preInstall
    # Install the release template into the Nix store so users can reference it.
    install -dm755 $out/share/personal-ai-infrastructure
    cp -r Releases/v4.0.3/.claude $out/share/personal-ai-infrastructure/
    # Install the wrapper script.
    install -dm755 $out/bin
    # pai: auto-installs on first run, then launches claude-code with deps on PATH.
    cat > $out/bin/pai << 'WRAPPER'
    #!/@bash@/bin/bash
    set -euo pipefail
    export PATH="@bun@/bin:@nodejs@/bin:@git@/bin:@curl@/bin:@claude-code@/bin:$PATH"

    PAI_SHARE="@out@/share/personal-ai-infrastructure/.claude"
    PAI_MARKER="$HOME/.claude/.pai-version"
    PAI_INSTALLING="$HOME/.claude/.pai-installing"

    # Auto-install or upgrade if needed.
    pai_install() {
      # Guard against re-entering a stuck install; let the user bypass.
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

      # Patch ALL bare "bun" references to use the Nix store path.
      # Covers install scripts, electron launcher, PAI-Install engine,
      # hook handlers, PAI tools, and shebangs.
      BUN="@bun@/bin/bun"
      for f in $(find "$HOME/.claude" -type f \( -name '*.sh' -o -name '*.ts' -o -name '*.js' \) ! -path '*/node_modules/*'); do
        sed -i \
          -e "s|exec bun |exec $BUN |g" \
          -e "s|#!/usr/bin/env bun|#!$BUN|g" \
          -e "s|spawn(\"bun\"|spawn(\"$BUN\"|g" \
          -e "s|spawn('bun'|spawn('$BUN'|g" \
          -e "s|spawnSync(\\[\"bun\"|spawnSync([\"$BUN\"|g" \
          -e "s|nodeSpawn('bun'|nodeSpawn('$BUN'|g" \
          -e "s|tryExec(\"bun |tryExec(\"$BUN |g" \
          -e "s|alias pai='bun |alias pai='$BUN |g" \
          "$f"
      done

      # Lock file so we can detect interrupted installs.
      touch "$PAI_INSTALLING"
      trap 'echo ""; echo "⚠  Install interrupted. Run \"pai\" again to retry."' EXIT

      # Install electron JS deps and use Nix-provided electron binary.
      cd "$HOME/.claude/PAI-Install/electron"
      npm install --ignore-scripts 2>/dev/null
      mkdir -p node_modules/electron/dist
      printf "electron" > node_modules/electron/path.txt
      ln -sf "@electron@/bin/electron" node_modules/electron/dist/electron
      # Run upstream install.sh (handles banner, checks, and launcher).
      bash "$HOME/.claude/install.sh"

      # Post-install patches: fix anything install.sh generated/overwrote.
      # Patch hook commands in settings.json.
      if [ -f "$HOME/.claude/settings.json" ]; then
        sed -i "s|\"command\": \"bun |\"command\": \"$BUN |g" "$HOME/.claude/settings.json"
      fi
      # Replace the shell alias to use the Nix pai wrapper instead of bare bun.
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
          sed -i "s|alias pai='.*bun.*/pai\\.ts'|alias pai='@out@/bin/pai'|g" "$rc"
        fi
      done

      # Install succeeded — remove lock, write version marker.
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

    # Launch claude-code, forwarding all arguments.
    exec claude "$@"
    WRAPPER
    # Substitute the real store paths.
    substituteInPlace $out/bin/pai \
      --replace '@out@' "$out" \
      --replace '@bash@' "${bash}" \
      --replace '@bun@' "${bun}" \
      --replace '@nodejs@' "${nodejs}" \
      --replace '@git@' "${git}" \
      --replace '@curl@' "${curl}" \
      --replace '@electron@' "${electron}" \
      --replace '@claude-code@' "${claude-code}" \
      --replace '@version@' "${finalAttrs.version}"
    chmod +x $out/bin/pai
    runHook postInstall
  '';
  meta = with lib; {
    description = "Agentic AI infrastructure for Claude Code — skills, memory, hooks, and goal tracking";
    longDescription = ''
      Personal AI Infrastructure (PAI) is a modular configuration system for Claude Code.
      It adds persistent memory, a skill system, event-driven hooks, goal tracking (TELOS),
      and a continuous-learning loop on top of Claude Code's agentic capabilities.
      Run `pai` to get started — it auto-installs on first run, then launches Claude Code
      with all PAI hooks and tools active.
    '';
    homepage = "https://github.com/danielmiessler/Personal_AI_Infrastructure";
    changelog = "https://github.com/danielmiessler/Personal_AI_Infrastructure/blob/v${finalAttrs.version}/Releases/v4.0.3/README.md";
    license = licenses.mit;
    maintainers = with maintainers; [
      ljubitje
    ];
    platforms = platforms.unix;
    mainProgram = "pai";
  };
})
