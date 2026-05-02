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
    # Install the wrapper script.
    install -dm755 $out/bin
    cat > $out/bin/pai << 'WRAPPER'
    #!/@bash@/bin/bash
    set -euo pipefail
    export PATH="@bun@/bin:@nodejs@/bin:@git@/bin:@curl@/bin:@jq@/bin:@claude-code@/bin:$PATH"

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
