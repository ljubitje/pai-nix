#!/usr/bin/env bash
# Hermetic test for payload-sync B2 detection (MANIFEST + accumulated known-official).
#
# Builds a synthetic store(B) + live tree with one file per bucket and asserts the
# tool classifies and applies each correctly — the load-bearing safety property being
# that OURS / diverged files (off the official list) are NEVER auto-overwritten, only
# officially-known older versions are. No nix build; pure tool logic against temp dirs.
#
#   a.ts : live == B                         -> CURRENT (skip)
#   b.ts : live == a KNOWN official hash ≠ B -> TAKE_B  (safe deterministic overwrite)
#   c.ts : live == ours (off the list)       -> REVIEW  (merge-candidate, left untouched)
#   d.ts : in B, absent in live              -> ADD     (copy-missing)
# plus: --apply persists the grown known-official set and backs up overwritten files.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$REPO/pkgs/tools/misc/lifeos/files/payload-sync.ts"
W="$(mktemp -d /tmp/payload-sync-test.XXXXXX)"
trap 'rm -rf "$W"' EXIT
FAILS=0
NEW="$W/new/LifeOS/install"; LIVE="$W/live"
mkdir -p "$NEW/LIFEOS" "$LIVE/LIFEOS" "$LIVE/LIFEOS/MEMORY/STATE"

echo "== payload-sync B2 detection test =="

# --- B (new store) payload ---
printf 'shared-current\n' > "$NEW/LIFEOS/a.ts"
printf 'official-v2\n'    > "$NEW/LIFEOS/b.ts"
printf 'official-c\n'     > "$NEW/LIFEOS/c.ts"
printf 'brand-new\n'      > "$NEW/LIFEOS/d.ts"

# --- live tree ---
printf 'shared-current\n' > "$LIVE/LIFEOS/a.ts"   # == B         -> CURRENT
printf 'official-v1\n'    > "$LIVE/LIFEOS/b.ts"   # old official -> TAKE_B (seed its hash as known)
printf 'our-hand-edit\n'  > "$LIVE/LIFEOS/c.ts"   # ours         -> REVIEW
# d.ts intentionally absent -> ADD

# --- MANIFEST for B (mirror the build: paths relative to install/, sorted) ---
( cd "$NEW" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256 )

# --- seed known-official with live b.ts's hash keyed to its path (an older official release) ---
BHASH="$(sha256sum "$LIVE/LIFEOS/b.ts" | cut -d' ' -f1)"
printf '%s  LIFEOS/b.ts\n' "$BHASH" > "$LIVE/LIFEOS/MEMORY/STATE/known-official.sha256"

count() { grep -E "^  $1 " "$W/dry.out" | grep -oE '[0-9]+' | head -1; }

echo "-- dry-run --"
bun "$TOOL" --new "$NEW" --live "$LIVE" --roots LIFEOS > "$W/dry.out" 2>&1 || { echo "FAIL: tool errored"; cat "$W/dry.out"; exit 2; }
for pair in "CURRENT 1" "TAKE_B 1" "ADD 1" "REVIEW 1" "DELETE 0"; do
  set -- $pair; got="$(count "$1")"
  if [ "$got" = "$2" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1 = $got (expected $2)"; FAILS=$((FAILS+1)); fi
done

echo "-- apply --"
bun "$TOOL" --new "$NEW" --live "$LIVE" --roots LIFEOS --apply > "$W/apply.out" 2>&1 || { echo "FAIL: apply errored"; cat "$W/apply.out"; exit 2; }
chk() { if [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$(cat "$1" 2>/dev/null)')"; FAILS=$((FAILS+1)); fi; }
chk "$LIVE/LIFEOS/b.ts" "official-v2"  "TAKE_B: b.ts overwritten with B"
chk "$LIVE/LIFEOS/d.ts" "brand-new"    "ADD: d.ts created"
chk "$LIVE/LIFEOS/c.ts" "our-hand-edit" "REVIEW: c.ts left UNTOUCHED (no blind overwrite)"
chk "$LIVE/LIFEOS/a.ts" "shared-current" "CURRENT: a.ts unchanged"

# accumulator grew to include B's hashes (b.ts new official hash now known)
NEWBHASH="$(sha256sum "$NEW/LIFEOS/b.ts" | cut -d' ' -f1)"
if grep -q "$NEWBHASH  LIFEOS/b.ts" "$LIVE/LIFEOS/MEMORY/STATE/known-official.sha256"; then
  echo "  ok   known-official persisted + grew (B's b.ts hash now recorded)"
else
  echo "  FAIL known-official did not fold in B's hashes"; FAILS=$((FAILS+1))
fi
# a backup exists holding the pre-overwrite b.ts
if find "$LIVE" -path '*payload-sync-backup*/LIFEOS/b.ts' -exec grep -q 'official-v1' {} \; 2>/dev/null; then
  echo "  ok   backup holds pre-overwrite b.ts (restore-able)"
else
  echo "  FAIL no restore-able backup of overwritten b.ts"; FAILS=$((FAILS+1))
fi

echo "== result =="
if [ "$FAILS" -eq 0 ]; then echo "PASS — payload-sync B2 detection (manifest+accumulator; ours never clobbered)"; exit 0
else echo "FAIL — $FAILS check(s) failed"; exit 1; fi
