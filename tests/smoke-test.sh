#!/usr/bin/env bash
# F7 sandbox runtime smoke for lifeos-nix (ISC-107 / ISC-108 / ISC-109).
#
# Activates the 7.1.1 tree into a scratch config-root (the launcher's own
# install_core chain), then boots Pulse INSIDE a rootless net namespace — its
# loopback is isolated, so binding :31337 cannot collide with the live Pulse.
#
#   ISC-108  Pulse answers GET /healthz on :31337 (server reachable)
#   ISC-109  Pulse exits gracefully on SIGTERM in <5s (patch 0029 — the former
#            60s-hang / mid-writeState-SIGKILL hazard)
#   ISC-107  the `lifeos` wrapper's launch chain resolves (claude binary +
#            lifeos.ts in the tree + wrapper exec line). The actual interactive
#            nested launch is DEFERRED — CLAUDECODE=1 blocks nesting a session.
#
# Never touches the live install: scratch HOME only; Pulse network-isolated.
# Requires: nix, unshare (rootless user+net ns — NO sudo), curl. No bc.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/lifeos-smoke.XXXXXX)"
trap 'pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0
CFGHOME="$WORK/act"; CFG="$CFGHOME/.claude"; mkdir -p "$CFG"
# Live-untouched guard: fingerprint a set of daemon-STABLE, activation-written live files
# before the run, compare after. Self-baselining — it compares the run's own before/after,
# never an absolute expected value, so upstream version bumps are a non-issue (the old
# hardcoded .pai-version=5.0.0 check rotted the moment the live install migrated). The
# scratch HOME already isolates the activation; this trips if that isolation ever regresses
# and lets the activation write real ~/.claude. Each file is written by a distinct activation
# step (VERSION←DeployCore, settings.system.json←InstallSettings, CLAUDE.md +
# LIFEOS_SYSTEM_PROMPT.md←install steps), so together they canary the whole chain. NOTE:
# settings.json is deliberately EXCLUDED — it is regenerated at runtime (~2h churn probed),
# so it would false-fail; only files the live daemon never rewrites belong here.
CANARY_FILES=(
  "$HOME/.claude/LIFEOS/VERSION"
  "$HOME/.claude/LIFEOS/LIFEOS_SYSTEM_PROMPT.md"
  "$HOME/.claude/settings.system.json"
  "$HOME/.claude/CLAUDE.md"
)
canary_fp() { for f in "${CANARY_FILES[@]}"; do [ -f "$f" ] && sha256sum "$f" || echo "absent $f"; done | sha256sum | cut -d' ' -f1; }
LIVE_BEFORE="$(canary_fp)"

echo "== F7 sandbox smoke =="
echo "-- building .#lifeos --"
OUT="$(nix build "$REPO#lifeos" --print-out-paths --no-link 2>/dev/null | tail -1)"
[ -n "$OUT" ] || { echo "FAIL: build produced no out path"; exit 2; }
SKILL="$OUT/share/lifeos/LifeOS"
BUN_BIN="$(grep -oE '/nix/store/[^:"]*-bun-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
CLAUDE_BIN="$(grep -oE '/nix/store/[^:"]*-claude-code-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
PTH="$BUN_BIN:$CLAUDE_BIN:/run/current-system/sw/bin:/usr/bin:/bin"
echo "   out=$OUT"

echo "-- activate into scratch config-root (launcher's install_core chain) --"
timeout 180 env -i HOME="$CFGHOME" PATH="$PTH" NEXT_TELEMETRY_DISABLED=1 bash -c "
  bun '$SKILL/Tools/DeployCore.ts'      --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/ScaffoldUser.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/LinkUser.ts'        --skill-root '$SKILL' --config-root '$CFG' --apply &&
  { [ -e '$CFG/CLAUDE.md' ] || install -m 0644 '$SKILL/install/CLAUDE.template.md' '$CFG/CLAUDE.md'; } &&
  bun '$SKILL/Tools/InstallSettings.ts' --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/InstallHooks.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/ActivateImports.ts' --skill-root '$SKILL' --config-root '$CFG' --apply
" > "$WORK/activate.log" 2>&1
AC=$?
# bridge vendored node_modules exactly like the launcher, then normalize modes (b415672)
ln -sfn "$SKILL/install/node_modules"                            "$CFG/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/node_modules"               "$CFG/LIFEOS/PULSE/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/Observability/node_modules" "$CFG/LIFEOS/PULSE/Observability/node_modules"
ln -sfn "$SKILL/install/LIFEOS/TOOLS/node_modules"               "$CFG/LIFEOS/TOOLS/node_modules"
chmod -R u+w "$CFG" 2>/dev/null
if [ $AC -ne 0 ] || [ ! -f "$CFG/LIFEOS/PULSE/PULSE.toml" ]; then
  echo "  FAIL activation (exit $AC) — tail:"; tail -6 "$WORK/activate.log" | sed 's/^/      /'; exit 2
fi
echo "  ok  activated (exit 0, PULSE.toml present)"

echo "-- ISC-107: lifeos wrapper -> Claude launch chain (interactive nesting deferred) --"
VER="$(env -u CLAUDECODE PATH="$PTH" claude --version 2>/dev/null | head -1)"
if [ -n "$VER" ]; then echo "  ok   claude binary resolves: $VER"; else echo "  FAIL claude --version returned nothing"; FAILS=$((FAILS+1)); fi
if grep -qF 'exec bun "$CFG/LIFEOS/TOOLS/lifeos.ts"' "$OUT/bin/lifeos"; then echo "  ok   wrapper execs lifeos.ts -s LIFEOS_SYSTEM_PROMPT.md"; else echo "  FAIL wrapper exec line not found"; FAILS=$((FAILS+1)); fi
if [ -f "$CFG/LIFEOS/TOOLS/lifeos.ts" ]; then echo "  ok   lifeos.ts present in activated tree"; else echo "  FAIL lifeos.ts missing from tree"; FAILS=$((FAILS+1)); fi
echo "  DEFERRED-VERIFY: interactive nested claude launch — CLAUDECODE=1 blocks nesting (run from a non-Claude-Code shell)."

echo "-- ISC-108/109: Pulse in a rootless netns (loopback isolated from live :31337) --"
cat > "$WORK/probe.sh" <<'HELPER'
#!/usr/bin/env bash
CFG="$1"; CFGHOME="$2"; PTH="$3"; WORK="$4"
ip link set lo up 2>/dev/null
cd "$CFG/LIFEOS/PULSE" || { echo "PROBE_ERR=cd-failed"; exit 9; }
env HOME="$CFGHOME" PATH="$PTH" NEXT_TELEMETRY_DISABLED=1 bun run pulse.ts >"$WORK/pulse.log" 2>&1 &
PP=$!
UP=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:31337/healthz" 2>/dev/null; then UP=1; break; fi
  kill -0 "$PP" 2>/dev/null || { echo "PULSE_DIED_EARLY=1"; break; }
  sleep 0.5
done
echo "PULSE_UP=$UP"
if [ "$UP" = 1 ]; then
  CODE=$(curl -s -o "$WORK/healthz.body" -w '%{http_code}' "http://127.0.0.1:31337/healthz" 2>/dev/null)
  echo "HEALTHZ_CODE=$CODE"
  echo "HEALTHZ_BODY=$(head -c 400 "$WORK/healthz.body" | tr '\n' ' ')"
fi
if [ "$UP" = 1 ]; then
  T0=$(date +%s%N)
  kill -TERM "$PP" 2>/dev/null
  GRACE=0
  for i in $(seq 1 50); do kill -0 "$PP" 2>/dev/null || { GRACE=1; break; }; sleep 0.1; done
  T1=$(date +%s%N)
  echo "SIGTERM_MS=$(( (T1 - T0) / 1000000 ))"
  if [ "$GRACE" = 1 ]; then wait "$PP" 2>/dev/null; echo "PULSE_EXIT=$?"; echo "SIGTERM_RESULT=EXITED"; else echo "SIGTERM_RESULT=HANG"; kill -9 "$PP" 2>/dev/null; fi
else
  kill -9 "$PP" 2>/dev/null   # never came up — graceful-shutdown is unverifiable
fi
HELPER
chmod +x "$WORK/probe.sh"
timeout 120 unshare -rn --map-root-user bash "$WORK/probe.sh" "$CFG" "$CFGHOME" "$PTH" "$WORK" > "$WORK/probe.out" 2>&1
sed 's/^/      /' "$WORK/probe.out"

CODE="$(grep '^HEALTHZ_CODE=' "$WORK/probe.out" | cut -d= -f2)"
UP="$(grep '^PULSE_UP=' "$WORK/probe.out" | cut -d= -f2)"
if [ "$UP" = 1 ] && [ -n "$CODE" ] && [ "$CODE" -ge 200 ] 2>/dev/null && [ "$CODE" -lt 300 ] 2>/dev/null; then
  echo "  ok   ISC-108 — Pulse /healthz HTTP $CODE (2xx)"
else
  echo "  FAIL ISC-108 — Pulse not up or /healthz not 2xx (PULSE_UP=$UP CODE=$CODE)"; FAILS=$((FAILS+1))
  tail -10 "$WORK/pulse.log" 2>/dev/null | sed 's/^/        pulse: /'
fi
# ISC-108b: reachable is not enough — a fresh boot must be HEALTHY. A "degraded"
# body (HTTP still 200) means a subsystem is already failing at boot. Caught the
# 2026-08-11 miss where migration verified HTTP 200 only and shipped 3 dead cron
# jobs. (Weak for the /bin/bash-PATH bug itself — jobs don't fire in this window
# and the probe PATH carries bash — but catches persistent degraded-at-boot.)
if [ "$UP" = 1 ]; then
  STATUS="$(grep -o '"status":"[a-z]*"' "$WORK/healthz.body" 2>/dev/null | head -1 | cut -d'"' -f4)"
  if [ "$STATUS" = "ok" ]; then
    echo "  ok   ISC-108b — healthz status: ok"
  else
    echo "  FAIL ISC-108b — healthz status '$STATUS' (expected ok) — degraded at boot"; FAILS=$((FAILS+1))
    grep -o '"reasons":\[[^]]*\]' "$WORK/healthz.body" 2>/dev/null | sed 's/^/        /'
  fi
fi
if [ "$UP" != 1 ]; then
  echo "  FAIL ISC-109 — Pulse never came up; graceful shutdown unverifiable"; FAILS=$((FAILS+1))
elif grep -q '^SIGTERM_RESULT=EXITED' "$WORK/probe.out"; then
  echo "  ok   ISC-109 — graceful SIGTERM in $(grep '^SIGTERM_MS=' "$WORK/probe.out" | cut -d= -f2)ms, exit $(grep '^PULSE_EXIT=' "$WORK/probe.out" | cut -d= -f2) (0029 holds)"
else
  echo "  FAIL ISC-109 — SIGTERM hang (0029 regression)"; FAILS=$((FAILS+1))
fi

echo "-- freeze re-check: live install untouched by the smoke run --"
LIVE_AFTER="$(canary_fp)"
if [ "$LIVE_AFTER" = "$LIVE_BEFORE" ]; then
  echo "  ok   live canary (${#CANARY_FILES[@]} stable files) unchanged during smoke"
else
  echo "  FAIL live install mutated during smoke (canary before=$LIVE_BEFORE after=$LIVE_AFTER)"; FAILS=$((FAILS+1))
fi

echo "== result =="
if [ "$FAILS" -eq 0 ]; then
  echo "PASS — F7 smoke green (ISC-108 reachable, ISC-109 graceful; ISC-107 chain ok, interactive deferred)"; exit 0
else
  echo "FAIL — $FAILS check(s) failed"; exit 1
fi
