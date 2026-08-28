#!/usr/bin/env bash
# ISC-133 — default-egress invariant test for lifeos-nix.
#
# Asserts: under a DENY-ALL network (rootless net namespace, loopback only) with an
# EMPTY environment (no creds), NO default-active LifeOS code path attempts an external
# connect(). "External" = any AF_INET/AF_INET6 that is not loopback. The invariant is
# `default background egress ⊆ {Anthropic} ∪ K`, where K = user-configured intentional
# targets (e.g. healthcheck monitor sites via LIFEOS_PULSE_HEALTH_SITES) — EMPTY in this
# base test (empty env, no creds), so the achieved set here is ∅. K is populated only in a
# principal's own config; a LOS-config test run would allow-list those consented targets.
#
# A POSITIVE CONTROL (a script that deliberately dials 1.2.3.4) proves the harness would
# catch a real egress — so a clean run means "nothing tried", not "nothing was watched".
#
# Coverage: (1) positive control, (2) every default job/check script with empty env,
# (3) the DeployCore activation chain into a scratch config-root, (4) a full Pulse daemon
# boot against that activated tree (SIGKILL, no graceful-shutdown hang). Anthropic connects
# are ALLOWED (none expected here — no session/prompt is driven); everything else is a FAIL.
#
# Requires: nix, unshare (rootless user+net namespaces — NO sudo), strace, ip.
# Never touches the live install: scratch HOME only, network fully isolated.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/lifeos-egress.XXXXXX)"
trap 'pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/traces" "$WORK/home/.claude"
FAILS=0

echo "== ISC-133 egress test =="
echo "-- building package --"
OUT="$(nix build "$REPO#lifeos" --print-out-paths --no-link 2>/dev/null | tail -1)"
[ -n "$OUT" ] || { echo "FAIL: build produced no out path"; exit 2; }
SKILL="$OUT/share/lifeos/LifeOS"
BUN_BIN="$(grep -oE '/nix/store/[^:"]*-bun-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
PATH_IN="$BUN_BIN:/run/current-system/sw/bin:/usr/bin:/bin"
echo "   out=$OUT"

# Helper that runs INSIDE the namespace: brings loopback up, then execs the command
# under strace with an empty env. Args preserved as real argv (no string re-parsing).
cat > "$WORK/isolate.sh" <<'HELPER'
#!/usr/bin/env bash
ip link set lo up 2>/dev/null
home="$1"; pth="$2"; tmo="$3"; trace="$4"; shift 4
exec env -i HOME="$home" PATH="$pth" \
  timeout -s KILL "$tmo" strace -f -e trace=network -qq -o "$trace" "$@"
HELPER

ext_count() { grep -E 'connect\(.*AF_INET' "$1" 2>/dev/null | grep -Evc '127\.0\.0\.1|::1|0\.0\.0\.0' || true; }

# isolate <home> <tmo> <trace> <cmd...>  → run cmd in netns+strace; returns ext connect count via $EXT
isolate() {
  local home="$1" tmo="$2" trace="$3"; shift 3
  unshare -rn --map-root-user bash "$WORK/isolate.sh" "$home" "$PATH_IN" "$tmo" "$trace" "$@" \
    >"$trace.out" 2>"$trace.err"
  EXT="$(ext_count "$trace")"
}

report() { # <label> <trace>
  if [ "${EXT:-0}" -ne 0 ]; then
    echo "  FAIL  $1 — $EXT external connect(s):"
    grep -E 'connect\(.*AF_INET' "$2" | grep -Ev '127\.0\.0\.1|::1|0\.0\.0\.0' | sed 's/^/        /'
    FAILS=$((FAILS+1))
  else
    echo "  ok    $1 — 0 external connects"
  fi
}

echo "-- positive control (MUST be caught) --"
isolate "$WORK/home" 8 "$WORK/traces/pos.strace" \
  bun -e 'await fetch("http://1.2.3.4:8080/x").catch(()=>{}); await new Promise(r=>setTimeout(r,150))'
if [ "${EXT:-0}" -eq 0 ]; then
  echo "  FATAL: positive control did NOT trip — harness is blind, aborting."; exit 3
fi
echo "  ok    harness proven — positive control tripped ($EXT external connect caught)"

echo "-- default job/check scripts (empty env) --"
for rel in checks/airgradient-poll.ts checks/calendar.ts checks/github.ts checks/github-work.ts \
           checks/health.ts checks/life-morning-brief.ts checks/notification-governor.ts \
           checks/poller-meta-monitor.ts Performance/cost-aggregator.ts; do
  tr="$WORK/traces/$(echo "$rel" | tr / _).strace"
  isolate "$WORK/home" 25 "$tr" bash -c "cd '$SKILL/install/LIFEOS/PULSE' && exec bun run '$rel'"
  report "$rel" "$tr"
done

echo "-- activation (DeployCore chain into scratch config-root) --"
CFGHOME="$WORK/act"; CFG="$CFGHOME/.claude"; mkdir -p "$CFG"
isolate "$CFGHOME" 120 "$WORK/traces/activation.strace" bash -c "
  bun '$SKILL/Tools/DeployCore.ts'      --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/ScaffoldUser.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/LinkUser.ts'        --skill-root '$SKILL' --config-root '$CFG' --apply &&
  { [ -e '$CFG/CLAUDE.md' ] || cp '$SKILL/install/CLAUDE.template.md' '$CFG/CLAUDE.md' 2>/dev/null; true; } &&
  bun '$SKILL/Tools/InstallSettings.ts' --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/InstallHooks.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/ActivateImports.ts' --skill-root '$SKILL' --config-root '$CFG' --apply "
report "activation" "$WORK/traces/activation.strace"
[ -f "$CFG/LIFEOS/PULSE/PULSE.toml" ] || { echo "  FAIL  activation did not populate config-root"; FAILS=$((FAILS+1)); }

# bridge vendored node_modules exactly like the launcher does
ln -sfn "$SKILL/install/node_modules"                            "$CFG/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/node_modules"               "$CFG/LIFEOS/PULSE/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/Observability/node_modules" "$CFG/LIFEOS/PULSE/Observability/node_modules"
ln -sfn "$SKILL/install/LIFEOS/TOOLS/node_modules"               "$CFG/LIFEOS/TOOLS/node_modules"

echo "-- Pulse daemon boot (deployed tree, ~15s, SIGKILL) --"
isolate "$CFGHOME" 15 "$WORK/traces/pulse.strace" bash -c "cd '$CFG/LIFEOS/PULSE' && exec bun run pulse.ts"
report "pulse-boot" "$WORK/traces/pulse.strace"
if grep -q '"voice":false' "$WORK/traces/pulse.strace.out"; then
  echo "  ok    pulse-boot — voice module OFF at runtime (f4-c load-bearing; telegram module removed upstream in 7.40.4)"
else
  echo "  WARN  could not confirm voice OFF in boot log"
fi

echo "== result =="
if [ "$FAILS" -eq 0 ]; then
  echo "PASS — default background egress ⊆ {Anthropic} ∪ K (base test: K=∅ empty env, achieved ∅ external, no creds)"; exit 0
else
  echo "FAIL — $FAILS surface(s) attempted external egress"; exit 1
fi
