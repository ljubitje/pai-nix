#!/usr/bin/env bash
# Gate for the vendored node_modules trees (lifeos-deps-*). They are fixed-output derivations
# addressed by CONTENT, so a green build proves nothing after the bun that runs `bun install`
# changes: nix serves the cached output and never runs the new bun. `nix build --rebuild`
# re-runs the build and compares the result with the declared outputHash, so it is the only
# check that exercises the pinned bun. Run it after every bump of pkgs/tools/misc/bun, every
# lock or patch change in pkgs/tools/misc/lifeos, and on a machine with network access.
# Exits non-zero on the first tree that no longer reproduces its hash.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "-- vendor-hashes: every lifeos-deps-* tree must reproduce its outputHash under the pinned bun --"
SYS="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
LIFEOS_DRV="$(nix eval --raw ".#packages.$SYS.lifeos.drvPath")"
BUN="$(nix eval --raw ".#packages.$SYS.claude-code.passthru.bun.version")"
echo "pinned bun: $BUN"

# control: the rebuild comparison has to be able to fail, or a pass below means nothing
CTL="$(mktemp --suffix=.nix)"; trap 'rm -f "$CTL"' EXIT
cat > "$CTL" <<'N'
let pkgs = import <nixpkgs> {}; in pkgs.stdenvNoCC.mkDerivation {
  name = "vendor-hash-control"; dontUnpack = true; dontFixup = true;
  buildPhase = "mkdir $out; echo hi > $out/f"; installPhase = "true";
  outputHashMode = "recursive"; outputHashAlgo = "sha256";
  outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}
N
# captured first: under pipefail, `grep -q` closing the pipe early would fail the pipeline
CTL_OUT="$(nix build --no-link --impure -f "$CTL" 2>&1 || true)"
if grep -q "hash mismatch" <<<"$CTL_OUT"; then
  echo "ok   control: a wrong hash is detected"
else
  echo "FAIL control: a wrong hash was NOT detected; this test cannot fail"; exit 1
fi

n=0
while read -r drv; do
  name="$(basename "$drv" .drv | sed 's/^[a-z0-9]*-//')"
  if nix build --rebuild --no-link "$drv^out" >/dev/null 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name: rebuild does not reproduce the declared outputHash (rerun without >/dev/null to see the new hash)"; exit 1
  fi
  n=$((n+1))
done < <(nix-store -qR "$LIFEOS_DRV" | grep -E 'lifeos-deps-[a-z]+\.drv$' | sort)
[ "$n" -gt 0 ] || { echo "FAIL: no lifeos-deps-* trees found; the test matched nothing"; exit 1; }
echo "PASS: $n trees reproduce their hash under bun $BUN"
