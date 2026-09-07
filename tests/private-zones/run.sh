#!/usr/bin/env bash
# Materialise the patched payload in a temp tree and run the PrivateZones suite against it.
# The suite cannot run from the repo directly: the files it imports exist only inside
# f-private-zones.patch until a build applies them. This script is that build, in miniature.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PATCH="$REPO/pkgs/tools/misc/lifeos/patches/f-private-zones.patch"
SRC="${LIFEOS_LIVE:-$HOME/.claude}"

TREE="$(mktemp -d)"; trap 'rm -rf "$TREE"' EXIT
ROOT="$TREE/LifeOS/install"
mkdir -p "$ROOT/LIFEOS/TOOLS" "$ROOT/LIFEOS/USER/CONFIG" "$TREE/home"
# The whole hooks dir: the dispatcher imports eight guard modules, and a partial copy makes
# it die on import (exit 1), which reads as "not blocked" unless you look at the code.
cp -r "$SRC/hooks" "$ROOT/hooks"
# hooks/lib reaches into LIFEOS/TOOLS (identity → LifeosConfig → …), so the dispatcher needs
# the real TOOLS tree, not just the two files under test. 3.4M, cheap enough for a temp tree.
cp -r "$SRC/LIFEOS/TOOLS/." "$ROOT/LIFEOS/TOOLS/"
chmod -R u+w "$TREE"
# The live tree may already carry dev copies of the files this patch CREATES; drop them so
# the patch applies against a pristine baseline rather than half-applying over itself.
rm -f "$ROOT/hooks/PrivateZoneEgressGuard.hook.ts" \
      "$ROOT/LIFEOS/TOOLS/PrivateZones.ts" "$ROOT/LIFEOS/TOOLS/PrivateZones.test.ts" \
      "$ROOT/USER/CONFIG/private-zones.example.json"
( cd "$TREE" && patch -p1 --silent --batch --forward -i "$PATCH" )

# $HOME/.claude must BE the payload root so REGISTER_PATH and PROJECTS_DIR resolve inside it.
# The dispatcher's import graph reaches real deps (yaml via hooks/lib/identity.ts); without
# node_modules it dies on import and exits 1, which reads as "allowed" unless you look.
[ -d "$SRC/node_modules" ] && ln -s "$SRC/node_modules" "$ROOT/node_modules"
ln -s "$ROOT" "$TREE/home/.claude"
mkdir -p "$ROOT/projects/proj-vault" "$ROOT/projects/proj-work"
cp "$HERE/PrivateZones.test.ts" "$ROOT/LIFEOS/TOOLS/"
cat > "$ROOT/LIFEOS/USER/CONFIG/private-zones.json" <<'JSON'
{ "private": [{ "match": "proj-vault" }], "public": [{ "match": "proj-work" }],
  "narratedExempt": [{ "match": "/HANDOFF.md" }] }
JSON

cd "$ROOT/LIFEOS/TOOLS"
# Only the OPERATOR's register may supply anti-leak needles: falling back to the fixture made
# a fresh clone report a leak about names that live in the shipped comments by design.
# `|| true`: one of the two paths is always absent, and under `set -e` a failing command
# substitution in an assignment killed the whole run with no output at all.
REAL_REG="$(ls "$SRC"/LIFEOS/USER/CONFIG/private-zones.json "$SRC"/LIFEOS/USER/CONFIG/private-zones.json.off 2>/dev/null | head -1 || true)"
HOME="$TREE/home" PZ_TREE="$ROOT" PZ_REAL_REGISTER="$REAL_REG" bun test PrivateZones.test.ts
