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
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "personal-ai-infrastructure";
  version = "4.0.3-nixos";
  src = fetchFromGitHub {
    owner = "ljubitje";
    repo = "Personal_AI_Infrastructure";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Kbo9Hnm4LxCIVZTxO8VNEC2LES3syjTYPcm6C9sTsqU=";
  };
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bun nodejs git curl electron ];
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
    # pai-install: copies the .claude template into $HOME and then runs the wizard.
    cat > $out/bin/pai-install << 'EOF'
    #!/@bash@/bin/bash
    set -euo pipefail
    export PATH="@bun@/bin:@nodejs@/bin:@git@/bin:@curl@/bin:$PATH"
    PAI_SHARE="@out@/share/personal-ai-infrastructure/.claude"
    if [ -d "$HOME/.claude" ]; then
      BACKUP="$HOME/.claude-backup-$(date +%Y%m%d-%H%M%S)"
      echo "Backing up existing ~/.claude to $BACKUP"
      mv "$HOME/.claude" "$BACKUP"
    fi
    echo "Installing PAI v4.0.3 to ~/.claude ..."
    cp -r "$PAI_SHARE" "$HOME/.claude"
    chmod -R u+w "$HOME/.claude"
    # Install electron JS deps and use Nix-provided electron binary
    cd "$HOME/.claude/PAI-Install/electron"
    npm install --ignore-scripts 2>/dev/null
    mkdir -p node_modules/electron/dist
    printf "electron" > node_modules/electron/path.txt
    ln -sf "@electron@/bin/electron" node_modules/electron/dist/electron
    # Hand off to upstream install.sh (handles banner, checks, and launcher)
    exec bash "$HOME/.claude/install.sh"
    EOF
    # Substitute the real store paths.
    substituteInPlace $out/bin/pai-install \
      --replace '@out@' "$out" \
      --replace '@bash@' "${bash}" \
      --replace '@bun@' "${bun}" \
      --replace '@nodejs@' "${nodejs}" \
      --replace '@git@' "${git}" \
      --replace '@curl@' "${curl}" \
      --replace '@electron@' "${electron}"
    chmod +x $out/bin/pai-install
    runHook postInstall
  '';
  meta = with lib; {
    description = "Agentic AI infrastructure for Claude Code — skills, memory, hooks, and goal tracking";
    longDescription = ''
      Personal AI Infrastructure (PAI) is a modular configuration system for Claude Code.
      It adds persistent memory, a skill system, event-driven hooks, goal tracking (TELOS),
      and a continuous-learning loop on top of Claude Code's agentic capabilities.
      After installing this package, run `pai-install` once to set up your ~/.claude directory,
      then restart Claude Code to activate the hooks.
    '';
    homepage = "https://github.com/danielmiessler/Personal_AI_Infrastructure";
    changelog = "https://github.com/danielmiessler/Personal_AI_Infrastructure/blob/v${finalAttrs.version}/Releases/v4.0.3/README.md";
    license = licenses.mit;
    maintainers = with maintainers; [
      ljubitje
    ];
    platforms = platforms.unix;
    mainProgram = "pai-install";
  };
})
