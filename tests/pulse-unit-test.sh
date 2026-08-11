#!/usr/bin/env bash
# Regression guard for the Pulse systemd unit PATH (2026-08-11 bug).
#
# The nixosModule owns com.lifeos.pulse.service and MUST carry bash AND bun in
# its `path`. If either is dropped, spawnScript's `Bun.which("bash")` returns
# null, the "/bin/bash" fallback is absent on NixOS, and every cron job that
# shells out dies with ENOENT — /healthz goes "degraded" and stays there. This
# test evaluates the module and asserts the invariant so that never regresses.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "-- pulse-unit: nixosModule com.lifeos.pulse PATH regression --"
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
    svc = sys.config.systemd.user.services."com.lifeos.pulse";
  in {
    path = map toString svc.path;
    execStart = svc.serviceConfig.ExecStart;
    wd = svc.serviceConfig.WorkingDirectory;
  }
')"

FAILS=0
echo "$J" | grep -qE '\-bash(-interactive)?-'       && echo "  ok   bash in service path"                || { echo "  FAIL bash missing from service path"; FAILS=$((FAILS+1)); }
echo "$J" | grep -q '\-bun-'                         && echo "  ok   bun in service path"                 || { echo "  FAIL bun missing from service path"; FAILS=$((FAILS+1)); }
echo "$J" | grep -q '/bin/bun'                      && echo "  ok   ExecStart resolves bun"              || { echo "  FAIL ExecStart does not resolve bun"; FAILS=$((FAILS+1)); }
echo "$J" | grep -q '%h/.claude/LIFEOS/PULSE'       && echo "  ok   WorkingDirectory user-agnostic (%h)" || { echo "  FAIL WorkingDirectory not %h-based"; FAILS=$((FAILS+1)); }

if [ "$FAILS" -eq 0 ]; then
  echo "PASS — pulse unit path guard (bash + bun present, %h-anchored)"; exit 0
else
  echo "FAIL — $FAILS check(s) failed"; echo "$J"; exit 1
fi
