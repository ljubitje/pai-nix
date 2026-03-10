{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  makeWrapper,
  bash,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "personal-ai-infrastructure";
  version = "4.0.3-nixos";

  src = fetchFromGitHub {
    owner = "ljubitje";
    repo = "Personal_AI_Infrastructure";
    tag = "v${finalAttrs.version}";
    hash = "sha256-z/PAJYCP57SCESp4rcaZH8ibh8fuhl+5azvlinc1J6iHo=";
  };

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [ bun ];

  # No build step — PAI is config files + a Bun setup wizard.
  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall

    # Install the release template into the Nix store so users can reference it.
    install -dm755 $out/share/personal-ai-infrastructure
    cp -r Releases/v${finalAttrs.version}/.claude $out/share/personal-ai-infrastructure/

    # Install the wrapper script.
    install -dm755 $out/bin

    # pai-install: copies the .claude template into $HOME and then runs the wizard.
    cat > $out/bin/pai-install << 'EOF'
    #!${bash}/bin/bash
    set -euo pipefail

    PAI_SHARE="@out@/share/personal-ai-infrastructure/.claude"

    if [ -d "$HOME/.claude" ]; then
      BACKUP="$HOME/.claude-backup-$(date +%Y%m%d-%H%M%S)"
      echo "Backing up existing ~/.claude to $BACKUP"
      mv "$HOME/.claude" "$BACKUP"
    fi

    echo "Installing PAI v${finalAttrs.version} to ~/.claude ..."
    cp -r "$PAI_SHARE" "$HOME/.claude"
    chmod -R u+w "$HOME/.claude"

    echo "Running configuration wizard..."
    cd "$HOME/.claude"
    exec bash "$HOME/.claude/install.sh"
    EOF

    # Substitute the real store path.
    substituteInPlace $out/bin/pai-install \
      --replace '@out@' "$out"

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
    changelog = "https://github.com/danielmiessler/Personal_AI_Infrastructure/blob/v${finalAttrs.version}/Releases/v${finalAttrs.version}/README.md";
    license = licenses.mit;
    maintainers = with maintainers; [
      ljubitje
    ];
    platforms = platforms.unix;
    mainProgram = "pai-install";
  };
})
