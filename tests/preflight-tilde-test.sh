#!/usr/bin/env bash
# Regression guard for f-pulse-preflight-tilde (2026-08-26 bug).
#
# pulse.ts's cron preflight (#1392) resolves a job's script ref as
# `startsWith("/") ? p : join(PULSE_DIR, p)`. A "~/…" path is neither absolute
# nor PULSE_DIR-relative, so pre-fix it joined onto PULSE_DIR → nonsense path →
# existsSync false → the job was falsely "script not present" and DISABLED at
# every boot. Five real user jobs (deriver/synthesis/conduit-*/derived-sync)
# were silently dead since 2026-08-09 because of exactly this.
#
# This boots the BUILT (patched) pulse.ts with two ~-path jobs — one whose
# script EXISTS, one whose script is ABSENT — and asserts the fix is two-sided:
#   - tilde-present : script present under HOME  -> NOT disabled   (the fix)
#   - tilde-absent  : script absent under HOME   -> still disabled (check intact)
#
# dontBuild=true means the build never type-checks pulse.ts, so a broken patch
# only surfaces at runtime — this actually runs the boot path. Live install
# untouched: scratch HOME only; Pulse network-isolated in a rootless netns.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/lifeos-tilde.XXXXXX)"
trap 'pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0
CFGHOME="$WORK/act"; CFG="$CFGHOME/.claude"; mkdir -p "$CFG"

echo "== preflight-tilde test =="
echo "-- building .#lifeos --"
OUT="$(nix build "$REPO#lifeos" --print-out-paths --no-link 2>/dev/null | tail -1)"
[ -n "$OUT" ] || { echo "FAIL: build produced no out path"; exit 2; }
SKILL="$OUT/share/lifeos/LifeOS"
BUN_BIN="$(grep -oE '/nix/store/[^:"]*-bun-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
CLAUDE_BIN="$(grep -oE '/nix/store/[^:"]*-claude-code-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
PTH="$BUN_BIN:$CLAUDE_BIN:/run/current-system/sw/bin:/usr/bin:/bin"

echo "-- confirm the built pulse.ts actually carries the fix --"
if grep -q 'resolveRef' "$SKILL/install/LIFEOS/PULSE/pulse.ts" && grep -q 'import { homedir } from "os"' "$SKILL/install/LIFEOS/PULSE/pulse.ts"; then
  echo "  ok   patched pulse.ts in store (resolveRef + homedir import)"
else
  echo "  FAIL patched pulse.ts missing the fix in the built payload"; exit 2
fi

echo "-- activate into scratch config-root --"
timeout 180 env -i HOME="$CFGHOME" PATH="$PTH" NEXT_TELEMETRY_DISABLED=1 bash -c "
  bun '$SKILL/Tools/DeployCore.ts'      --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/ScaffoldUser.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/LinkUser.ts'        --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/InstallSettings.ts' --skill-root '$SKILL' --config-root '$CFG' --apply &&
  bun '$SKILL/Tools/InstallHooks.ts'    --skill-root '$SKILL' --config-root '$CFG' --apply
" > "$WORK/activate.log" 2>&1
AC=$?
ln -sfn "$SKILL/install/node_modules"                            "$CFG/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/node_modules"               "$CFG/LIFEOS/PULSE/node_modules"
ln -sfn "$SKILL/install/LIFEOS/PULSE/Observability/node_modules" "$CFG/LIFEOS/PULSE/Observability/node_modules"
ln -sfn "$SKILL/install/LIFEOS/TOOLS/node_modules"               "$CFG/LIFEOS/TOOLS/node_modules"
chmod -R u+w "$CFG" 2>/dev/null
if [ $AC -ne 0 ] || [ ! -f "$CFG/LIFEOS/PULSE/PULSE.toml" ]; then
  echo "  FAIL activation (exit $AC) — tail:"; tail -6 "$WORK/activate.log" | sed 's/^/      /'; exit 2
fi
echo "  ok  activated"

echo "-- inject two ~-path jobs (present script + absent script) --"
# HOME=$CFGHOME during boot, so ~/.claude resolves to $CFG. Create only the "present" one.
printf 'console.log("tilde-present ran")\n' > "$CFG/marker-present.ts"
cat >> "$CFG/LIFEOS/PULSE/PULSE.toml" <<'JOBS'

[[job]]
name = "tilde-present"
schedule = "0 0 1 1 *"
type = "script"
command = "bun run ~/.claude/marker-present.ts"
output = "log"
enabled = true

[[job]]
name = "tilde-absent"
schedule = "0 0 1 1 *"
type = "script"
command = "bun run ~/.claude/marker-absent.ts"
output = "log"
enabled = true
JOBS

echo "-- boot Pulse in a rootless netns; capture preflight log --"
cat > "$WORK/probe.sh" <<'HELPER'
#!/usr/bin/env bash
CFG="$1"; CFGHOME="$2"; PTH="$3"; WORK="$4"
ip link set lo up 2>/dev/null
cd "$CFG/LIFEOS/PULSE" || { echo "PROBE_ERR=cd-failed"; exit 9; }
env HOME="$CFGHOME" PATH="$PTH" NEXT_TELEMETRY_DISABLED=1 bun run pulse.ts >"$WORK/pulse.log" 2>&1 &
PP=$!
for i in $(seq 1 60); do
  curl -s -o /dev/null "http://127.0.0.1:31337/healthz" 2>/dev/null && break
  kill -0 "$PP" 2>/dev/null || { echo "PULSE_DIED_EARLY=1"; break; }
  sleep 0.5
done
kill -TERM "$PP" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$PP" 2>/dev/null || break; sleep 0.1; done
kill -9 "$PP" 2>/dev/null
HELPER
chmod +x "$WORK/probe.sh"
timeout 120 unshare -rn --map-root-user bash "$WORK/probe.sh" "$CFG" "$CFGHOME" "$PTH" "$WORK" >/dev/null 2>&1

echo "-- assertions --"
if grep -q 'Disabling cron job tilde-absent' "$WORK/pulse.log"; then
  echo "  ok   tilde-absent still flagged missing (check intact)"
else
  echo "  FAIL tilde-absent NOT flagged — preflight no longer catches truly-missing ~ scripts"; FAILS=$((FAILS+1))
fi
if grep -q 'Disabling cron job tilde-present' "$WORK/pulse.log"; then
  echo "  FAIL tilde-present was disabled — the ~ path did not resolve (fix broken)"; FAILS=$((FAILS+1))
  grep 'Disabling cron job' "$WORK/pulse.log" | sed 's/^/        /'
else
  echo "  ok   tilde-present survived preflight (~ resolved to an existing script)"
fi

echo "== result =="
if [ "$FAILS" -eq 0 ]; then
  echo "PASS — preflight resolves ~ paths (present survives, absent still flagged)"; exit 0
else
  echo "FAIL — $FAILS check(s) failed"; tail -20 "$WORK/pulse.log" 2>/dev/null | sed 's/^/      pulse: /'; exit 1
fi
