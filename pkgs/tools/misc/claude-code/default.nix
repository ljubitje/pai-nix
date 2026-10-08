# Vendored from nixpkgs (pkgs/by-name/cl/claude-code) so lifeos-nix owns the
# claude-code version pin as source-of-truth, decoupled from the nixpkgs input.
# version + per-platform checksums live in ./manifest.json (official upstream
# manifest from downloads.claude.ai). Bump: `./update.sh <version>` (refetches
# manifest.json), then rebuild. Multi-arch: eachDefaultSystem builds only the
# consumer's arch; manifest carries all platforms so any supported arch works.
{
  lib,
  stdenvNoCC,
  bash,
  bun,
  coreutils,
  getent,
  fetchurl,
  installShellFiles,
  makeBinaryWrapper,
  autoPatchelfHook,
  alsa-lib,
  procps,
  ripgrep,
  bubblewrap,
  socat,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
let
  stdenv = stdenvNoCC;
  baseUrl = "https://downloads.claude.ai/claude-code-releases";
  manifest = lib.importJSON ./manifest.json;
  platformKey = "${stdenv.hostPlatform.node.platform}-${stdenv.hostPlatform.node.arch}";
  platformManifestEntry = manifest.platforms.${platformKey};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-code";
  inherit (manifest) version;

  src = fetchurl {
    url = "${baseUrl}/${finalAttrs.version}/${platformKey}/claude";
    sha256 = platformManifestEntry.checksum;
  };

  dontUnpack = true;
  dontBuild = true;
  __noChroot = stdenv.hostPlatform.isDarwin;
  # otherwise the bun runtime is executed instead of the binary
  dontStrip = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isElf [ autoPatchelfHook ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    installBin $src

    # LifeOS hooks are `#!/usr/bin/env bun` scripts and claude runs them with its own PATH, so a
    # claude not started by the `lifeos` launcher (Pulse, Inference.ts, bare `claude`) needs bun.
    # --suffix, not --prefix: a bun from the project's own devshell must still win.
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set DISABLE_TELEMETRY 1 \
      --set DISABLE_ERROR_REPORTING 1 \
      --set USE_BUILTIN_RIPGREP 0 \
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ alsa-lib ]} \
      ''}--prefix PATH : ${
        lib.makeBinPath (
          [
            # claude-code uses [node-tree-kill](https://github.com/pkrumins/node-tree-kill) which requires procps's pgrep(darwin) or ps(linux)
            procps
            # https://code.claude.com/docs/en/troubleshooting#search-and-discovery-issues
            ripgrep
          ]
          # the following packages are required for the sandbox to work (Linux only)
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            bubblewrap
            socat
          ]
        )
      } \
      --suffix PATH : ${lib.makeBinPath [ bun ]}

    # lifeos-nix: inference gate. bin/claude becomes a thin script (claude-gate.sh) that reads
    # LIFEOS/USER/CONFIG/inference.conf under the account's passwd home before exec'ing the
    # real binary, so every spawn path — launcher, Inference.ts, Pulse, skills, a bare
    # `claude` — goes through it. No file or mode=anthropic-only: plain exec, as upstream.
    # Local modes: LifeOS's InferenceProvider.ts supplies the env. Anything it cannot read
    # exactly refuses; LIFEOS_GATE=off is the manual escape hatch outside local-only.
    install -dm755 $out/libexec/claude-code
    mv $out/bin/claude $out/libexec/claude-code/claude
    substitute ${./claude-gate.sh} $out/bin/claude \
      --subst-var-by bash ${bash} \
      --subst-var-by bun ${bun} \
      --subst-var-by coreutils ${coreutils} \
      --subst-var-by getent ${getent} \
      --subst-var-by real $out/libexec/claude-code/claude
    chmod 0755 $out/bin/claude

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  passthru.updateScript = ./update.sh;
  # The one bun LifeOS runs on: lifeos and the Pulse unit take it from here, so they cannot drift
  # from the bun the claude wrapper hands to hooks.
  passthru.bun = bun;

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://claude.com/product/claude-code";
    changelog = "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    maintainers = with lib.maintainers; [
      adeci
      malo
      markus1189
      mirkolenz
      omarjatoi
      oskarwires
      xiaoxiangmoe
    ];
    mainProgram = "claude";
  };
})
