#!/usr/bin/env bash
# F5 (ISC-79..85, ISC-75) — settings/hooks/toml install-semantics test for lifeos-nix.
#
# Asserts, against a scratch config-root (never the live install):
#   A. VIRGIN install: the full launcher activation chain exits 0 at every step,
#      settings.json is valid, the complete 7.1.1 hook set registers, hook scripts
#      deploy, both toml configs land, DeployComponents applies the enhancements
#      (spinnerVerbs + wired statusline), and the WHOLE config-root is user-writable
#      (files copied from the read-only store must not keep mode 444 — regression
#      guard for the launcher `chmod -R u+w` + `install -m 0644` fix).
#   B. PRE-EXISTING user settings.json: additive merge only — user's custom keys,
#      custom env vars, and values that OVERLAP the template are never touched;
#      absent template keys are added (env expanded, no literal $HOME); a backup
#      is written; hooks merge in.
#   C. IDEMPOTENCE (second run over A): settings.json semantically unchanged, no
#      duplicate hook registrations, and the f4-c privacy defaults in PULSE.toml
#      (voice/telegram off) survive the re-install merge (ISC-75).
#
# The chain below mirrors install_core in default.nix (minus manage.sh + Doctor,
# which are service/network domain — covered by egress-test.sh). Keep in sync.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/lifeos-settings.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }
check(){ if [ "$1" -eq 0 ]; then ok "$2"; else fail "$2"; fi; }

echo "== F5 settings/hooks/toml test =="
echo "-- building package --"
OUT="$(nix build "$REPO#personal-ai-infrastructure" --print-out-paths --no-link 2>/dev/null | tail -1)"
[ -n "$OUT" ] || { echo "FAIL: build produced no out path"; exit 2; }
SKILL="$OUT/share/lifeos/LifeOS"
BUN_BIN="$(grep -oE '/nix/store/[^:"]*-bun-[^/"]*/bin' "$OUT/bin/lifeos" | head -1)"
export PATH="$BUN_BIN:$PATH"
echo "   out=$OUT"

# Mirrors default.nix install_core (minus manage.sh/Doctor). Args: <home>
# Every step's exit code is asserted — a failing step fails the test (the
# egress test deliberately doesn't check these; this one does).
run_chain() {
  local home="$1" cfg="$1/.claude" step
  mkdir -p "$cfg"
  for step in DeployCore ScaffoldUser LinkUser; do
    HOME="$home" bun "$SKILL/Tools/$step.ts" --skill-root "$SKILL" --config-root "$cfg" --apply \
      >>"$home/chain.log" 2>&1 || { fail "chain step $step (exit $?)"; return 1; }
  done
  [ -e "$cfg/CLAUDE.md" ] || install -m 0644 "$SKILL/install/CLAUDE.template.md" "$cfg/CLAUDE.md"
  for step in InstallSettings InstallHooks ActivateImports; do
    HOME="$home" bun "$SKILL/Tools/$step.ts" --skill-root "$SKILL" --config-root "$cfg" --apply \
      >>"$home/chain.log" 2>&1 || { fail "chain step $step (exit $?)"; return 1; }
  done
  ln -sfn "$SKILL/install/node_modules" "$cfg/node_modules"
  HOME="$home" bun "$SKILL/Tools/DeployComponents.ts" --config-root "$cfg" \
    --components statusline,tooltips,spinnerverbs,agents,commands --apply \
    >"$home/dc.json" 2>>"$home/chain.log" || { fail "chain step DeployComponents (exit $?)"; return 1; }
  chmod -R u+w "$cfg"
  [ -d "$home/.config/LIFEOS" ] && chmod -R u+w "$home/.config/LIFEOS"
  return 0
}

# jq-less JSON probe: py <settings.json> <python-expr-using-s>  → exit 0/1
py() { python3 -c "
import json,sys
s=json.load(open('$1'))
sys.exit(0 if ($2) else 1)"; }

HOOKS_SRC="$SKILL/install/hooks/hooks.json"
EXPECT_EVENTS="$(python3 -c "import json;print(len(json.load(open('$HOOKS_SRC'))['hooks']))" 2>/dev/null ||
                python3 -c "import json;print(len(json.load(open('$HOOKS_SRC'))))")"
PAYLOAD_HOOK_COUNT="$(ls "$SKILL"/install/hooks/*.hook.ts "$SKILL"/install/hooks/*.hook.sh 2>/dev/null | wc -l)"

echo "-- scenario A: virgin install --"
A="$WORK/a"; ACFG="$A/.claude"; mkdir -p "$A"
if run_chain "$A"; then ok "activation chain — every step exit 0"; fi
SJ="$ACFG/settings.json"
py "$SJ" "True" ; check $? "A1 settings.json valid JSON"
py "$SJ" "set(s['hooks'].keys()) == set((lambda h: h.get('hooks',h))(json.load(open('$HOOKS_SRC'))).keys())" \
  ; check $? "A2 hook events == upstream hooks.json ($EXPECT_EVENTS events)"
DEPLOYED="$(ls "$ACFG"/hooks/*.hook.ts "$ACFG"/hooks/*.hook.sh 2>/dev/null | wc -l)"
[ "$DEPLOYED" -ge "$PAYLOAD_HOOK_COUNT" ]; check $? "A3 hook scripts deployed ($DEPLOYED >= $PAYLOAD_HOOK_COUNT)"
[ -f "$ACFG/LIFEOS/PULSE/PULSE.toml" ] && [ -f "$A/.config/LIFEOS/USER/CONFIG/LIFEOS_CONFIG.toml" ]
check $? "A4 PULSE.toml (config-root) + LIFEOS_CONFIG.toml (XDG user-config) land"
py "$SJ" "'spinnerVerbs' in s and s.get('statusLine',{}).get('command','').endswith('LIFEOS_StatusLine.sh')" \
  ; check $? "A5 enhancements applied (spinnerVerbs + statusline wired)"
python3 -c "import json,sys; r=json.load(open('$A/dc.json')); sys.exit(0 if all(x.get('applied') and x.get('probe',{}).get('passed') for x in r['results']) else 1)" \
  ; check $? "A5b DeployComponents: every component applied + own probe passed"
NONWRIT="$(find "$ACFG" "$A/.config/LIFEOS" -type f ! -writable 2>/dev/null | wc -l)"
[ "$NONWRIT" -eq 0 ]; check $? "A6 config-root + XDG user-config fully user-writable ($NONWRIT read-only files)"
grep -A2 '^\[voice\]' "$ACFG/LIFEOS/PULSE/PULSE.toml" | grep -q 'enabled = false' &&
grep -A2 '^\[telegram\]' "$ACFG/LIFEOS/PULSE/PULSE.toml" | grep -q 'enabled = false'
check $? "A7 f4-c privacy defaults present (voice+telegram off)"

echo "-- scenario B: pre-existing user settings.json (clobber test) --"
B="$WORK/b"; BCFG="$B/.claude"; mkdir -p "$BCFG"
TMPL_TIMEOUT="$(python3 -c "import json;print(json.load(open('$SKILL/install/settings.system.json'))['env'].get('BASH_DEFAULT_TIMEOUT_MS',''))")"
[ "$TMPL_TIMEOUT" != "999999" ]; check $? "B0 sentinel value differs from template ('$TMPL_TIMEOUT')"
cat > "$BCFG/settings.json" <<'SEED'
{
  "userSentinel": "KEEP-ME",
  "theme": "user-theme-SENTINEL",
  "env": { "USER_SENTINEL": "KEEP-ME", "BASH_DEFAULT_TIMEOUT_MS": "999999" }
}
SEED
if run_chain "$B"; then ok "activation chain over pre-existing settings — exit 0"; fi
SJB="$BCFG/settings.json"
py "$SJB" "s.get('userSentinel')=='KEEP-ME'"            ; check $? "B1 custom top-level key survives"
py "$SJB" "s['env'].get('USER_SENTINEL')=='KEEP-ME'"    ; check $? "B2 custom env var survives"
py "$SJB" "s['env'].get('BASH_DEFAULT_TIMEOUT_MS')=='999999'" ; check $? "B3 overlapping env value NOT clobbered"
py "$SJB" "s.get('theme')=='user-theme-SENTINEL'"       ; check $? "B4 overlapping top-level value NOT clobbered"
py "$SJB" "'LIFEOS_DIR' in s['env'] and not s['env']['LIFEOS_DIR'].startswith(('\$','~'))" \
  ; check $? "B5 absent template env keys added + expanded (no literal \$HOME)"
ls "$BCFG"/settings.json.backup-* >/dev/null 2>&1        ; check $? "B6 backup written before merge"
py "$SJB" "len(s.get('hooks',{}))==$EXPECT_EVENTS"       ; check $? "B7 hooks merged into pre-existing settings"

echo "-- scenario C: idempotence (re-run over A) --"
python3 -c "import json;print(json.dumps(json.load(open('$SJ')),sort_keys=True))" > "$WORK/a-before.json"
if run_chain "$A"; then ok "second activation chain — exit 0"; fi
python3 -c "import json;print(json.dumps(json.load(open('$SJ')),sort_keys=True))" > "$WORK/a-after.json"
cmp -s "$WORK/a-before.json" "$WORK/a-after.json"        ; check $? "C1 settings.json semantically unchanged"
py "$SJ" "all(len({json.dumps(h,sort_keys=True) for h in v})==len(v) for v in s['hooks'].values())" \
  ; check $? "C2 no duplicate hook registrations"
py "$SJ" "len(s['hooks'])==$EXPECT_EVENTS"               ; check $? "C3 event count unchanged ($EXPECT_EVENTS)"
grep -A2 '^\[voice\]' "$ACFG/LIFEOS/PULSE/PULSE.toml" | grep -q 'enabled = false' &&
grep -A2 '^\[telegram\]' "$ACFG/LIFEOS/PULSE/PULSE.toml" | grep -q 'enabled = false'
check $? "C4 f4-c privacy defaults survive re-install (ISC-75)"
NONWRIT2="$(find "$ACFG" "$A/.config/LIFEOS" -type f ! -writable 2>/dev/null | wc -l)"
[ "$NONWRIT2" -eq 0 ]; check $? "C5 config-root + XDG user-config still fully writable"

echo "== result =="
if [ "$FAILS" -eq 0 ]; then
  echo "PASS — install is merge-safe, idempotent, toml-native, and leaves a writable config-root"
  exit 0
else
  echo "FAIL — $FAILS assertion(s) failed"
  exit 1
fi
