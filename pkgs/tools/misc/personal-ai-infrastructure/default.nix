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
  version = "2.5.0";

  src = fetchFromGitHub {
    owner = "danielmiessler";
    repo = "Personal_AI_Infrastructure";
    tag = "v${finalAttrs.version}";
    # Run `nix-prefetch-url --unpack https://github.com/danielmiessler/Personal_AI_Infrastructure/archive/refs/tags/v2.5.0.tar.gz`
    # or `nix store prefetch-file --hash-type sha256 --unpack <url>` to get this value.
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
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
    exec ${bun}/bin/bun run INSTALL.ts
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
    changelog = "https://github.com/danielmiessler/Personal_AI_Infrastructure/blob/v${finalAttrs.version}/Releases/v${lib.versions.majorMinor finalAttrs.version}/README.md";
    license = licenses.mit;
    maintainers = with maintainers; [
      # YOUR_NIXPKGS_HANDLE  <-- you'll add yourself here
    ];
    platforms = platforms.unix;
    mainProgram = "pai-install";
  };
})
