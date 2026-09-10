#!/usr/bin/env bash
# Regression guard for the fabric transcript path (2026-09-10).
#
# Three things have to hold together or `fabric -y URL` breaks, and each broke once:
#   1. the binary exists at all — upstream LifeOS documents `fabric -y URL` in six
#      skills and ships the pattern DATA but never the tool, so a fresh install
#      ENOENTs and silently falls back to scraping the YouTube page;
#   2. ~/.config/fabric/.env exists — fabric refuses to start without it, INCLUDING
#      the -y leg that needs no credential. The tmpfiles verb must stay `f` and never
#      become `f+`: `f` creates only when absent, `f+` TRUNCATES, which would wipe a
#      user's API keys on every rebuild;
#   3. our stdin-precedence patch is on the derivation — without it any caller that
#      leaves stdin open blocks forever with zero bytes on both streams.
# This test asserts all three in the evaluated module, so none regresses silently.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "-- fabric: transcript-path regression guard --"
J="$(nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (toString ./.);
    sys = import <nixpkgs/nixos> {
      system = "x86_64-linux";
      configuration = {
        imports = [ flake.nixosModules.lifeos ];
        nixpkgs.config.allowUnfree = true;
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "x"; fsType = "ext4"; };
        system.stateVersion = "24.05";
      };
    };
    fab = flake.packages.x86_64-linux.fabric-ai;
  in {
    packages   = map toString sys.config.environment.systemPackages;
    tmpfiles   = sys.config.systemd.user.tmpfiles.rules;
    fabPatches = map baseNameOf (fab.patches or [ ]);
  }
')"

FAILS=0
ck() { # ck <label> <jq-ish grep pattern>
  if echo "$J" | grep -q "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; FAILS=$((FAILS+1)); fi
}
ckn() { # ckn <label> <pattern that must NOT appear>
  if echo "$J" | grep -q "$2"; then echo "  FAIL $1"; FAILS=$((FAILS+1)); else echo "  ok   $1"; fi
}

ck  "fabric-ai on system PATH"                  '\-fabric-ai-'
ck  "yt-dlp on system PATH"                     '\-yt-dlp-'
ck  "tmpfiles rule creates ~/.config/fabric/.env" 'f %h/\.config/fabric/\.env'
ckn "tmpfiles verb is NOT f+ (would truncate keys)" '"f+ %h/\.config/fabric/\.env'
ck  "stdin-precedence patch on the derivation"  'fabric-stdin-precedence'

# Positive control: prove the package assertion above can actually fail, otherwise a
# green line only means the grep never matches anything. A name no build produces
# must be absent; if this "finds" it, the probe is matching noise, not the field.
ckn "probe calibration (bogus package name absent)" '\-fabric-ai-0\.0\.0-nonexistent-'

if [ "$FAILS" -eq 0 ]; then
  echo "PASS — fabric transcript path (binary + .env rule + stdin patch)"; exit 0
else
  echo "FAIL — $FAILS check(s) failed"; echo "$J"; exit 1
fi
