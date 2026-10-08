# bun, pinned by lifeos-nix. Vendored verbatim from nixpkgs (pkgs/by-name/bu/bun/package.nix at
# the nixos-unstable revision in /etc/nixos' lock on 2026-10-08, bun 1.4.2) so that the bun LifeOS
# runs on is the same on every machine, whatever nixpkgs revision a consumer's system carries:
# claude's hooks, the lifeos launcher, the Pulse unit and the vendored node_modules trees all use this
# one. The whole recipe is vendored, not just the version, because the release asset and install
# steps change between bun versions (1.3.13 shipped bun-linux-x64.zip, 1.4.2 ships the -baseline one).
# Bump: copy the newer nixpkgs package.nix over this file, then re-check the lifeos-deps-* hashes
# (see the WARNING in ../lifeos/default.nix) and rebuild them with `nix build --rebuild`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  unzip,
  installShellFiles,
  makeWrapper,
  openssl,
  writeShellScript,
  curl,
  jq,
  common-updater-scripts,
  cctools,
  darwin,
  rcodesign,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  version = "1.4.2";
  pname = "bun";

  src =
    finalAttrs.passthru.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");

  sourceRoot =
    {
      aarch64-darwin = "bun-darwin-aarch64";
    }
    .${stdenvNoCC.hostPlatform.system} or null;

  strictDeps = true;
  nativeBuildInputs = [
    unzip
    installShellFiles
    makeWrapper
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ openssl ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm 755 ./bun $out/bin/bun
    ln -s $out/bin/bun $out/bin/bunx

    runHook postInstall
  '';

  postPhases = [ "postPatchelf" ];
  postPatchelf =
    lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
      '${lib.getExe' cctools "${cctools.targetPrefix}install_name_tool"}' $out/bin/bun \
        -change /usr/lib/libicucore.A.dylib '${lib.getLib darwin.ICU}/lib/libicucore.A.dylib'
      '${lib.getExe rcodesign}' sign --code-signature-flags linker-signed $out/bin/bun
    ''
    + lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
      installShellCompletion --cmd bun \
        --bash <(SHELL="bash" $out/bin/bun completions) \
        --zsh <(SHELL="zsh" $out/bin/bun completions) \
        --fish <(SHELL="fish" $out/bin/bun completions)
    '';

  passthru = {
    sources = {
      "aarch64-darwin" = fetchurl {
        url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-darwin-aarch64.zip";
        hash = "sha256-kJh6OhbX21VtiGrD1VHnttPt8KHPQ6yu1iLoZ2vh0S8=";
      };
      "aarch64-linux" = fetchurl {
        url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-linux-aarch64.zip";
        hash = "sha256-VDKLvC2cjgyfiSxUTWbFeoO4QTnjSQnl7oF1jxrI/ac=";
      };
      "x86_64-linux" = fetchurl {
        url = "https://github.com/oven-sh/bun/releases/download/bun-v${finalAttrs.version}/bun-linux-x64-baseline.zip";
        hash = "sha256-xngEDxT+BEDrg503y9DOTAUaMtpygGrJfeamqra/co8=";
      };
    };
    updateScript = writeShellScript "update-bun" ''
      set -o errexit
      export PATH="${
        lib.makeBinPath [
          curl
          jq
          common-updater-scripts
        ]
      }"
      NEW_VERSION=$(curl --silent https://api.github.com/repos/oven-sh/bun/releases/latest | jq '.tag_name | ltrimstr("bun-v")' --raw-output)
      if [[ "${finalAttrs.version}" = "$NEW_VERSION" ]]; then
          echo "The new version same as the old version."
          exit 0
      fi
      for platform in ${lib.escapeShellArgs finalAttrs.meta.platforms}; do
        update-source-version "bun" "$NEW_VERSION" --ignore-same-version --source-key="sources.$platform"
      done
    '';
  };
  meta = {
    homepage = "https://bun.sh";
    changelog = "https://bun.sh/blog/bun-v${finalAttrs.version}";
    description = "Incredibly fast JavaScript runtime, bundler, transpiler and package manager – all in one";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    longDescription = ''
      All in one fast & easy-to-use tool. Instead of 1,000 node_modules for development, you only need bun.
    '';
    license = with lib.licenses; [
      mit # bun core
      lgpl21Only # javascriptcore and webkit
    ];
    mainProgram = "bun";
    maintainers = with lib.maintainers; [
      DAlperin
      jk
      thilobillerbeck
      cdmistman
      diogomdp
    ];
    platforms = builtins.attrNames finalAttrs.passthru.sources;
    # Broken for Musl at 2024-01-13, tracking issue:
    # https://github.com/NixOS/nixpkgs/issues/280716
    broken = stdenvNoCC.hostPlatform.isMusl;
  };
})
