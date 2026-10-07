#!@bash@/bin/bash
# lifeos-nix inference gate for claude — see default.nix. Decides the model server for this
# exec via LifeOS's InferenceProvider.ts, then execs the real binary in place (TTY, signals
# and exit code stay the real claude's). It routes; it does not try to list what Claude Code
# can do that reaches Anthropic (that is the network room's job, ISA Step 7c). Every path that
# cannot prove a decision refuses.
real=@real@
refuse() { echo "❌ claude: $*" >&2; exit 3; }

# Where LifeOS may live: CLAUDE_CONFIG_DIR, the account's home from passwd, and $HOME (a uid
# passwd cannot resolve still has its LifeOS found). Store paths, not the caller's PATH:
# Pulse's unit PATH has no getent.
pwhome="$(@getent@/bin/getent passwd "$(@coreutils@/bin/id -u)" | @coreutils@/bin/cut -d: -f6)"
roots=()
for r in "${CLAUDE_CONFIG_DIR:-}" "${pwhome:+$pwhome/.claude}" "${HOME:+$HOME/.claude}"; do
  [ -n "$r" ] && roots+=("$r")
done

# Could any config this exec might use be asking for local-only? A file that exists but cannot
# be searched (unreadable, I/O error) counts as yes: only grep's "no match" (exit 1) is a no.
names_local_only() {
  local f rc
  for f in "${LIFEOS_CONFIG_PATH:-}" "${roots[@]/%//LIFEOS/USER/CONFIG/LIFEOS_CONFIG.toml}"; do
    [ -n "$f" ] && [ -e "$f" ] || continue
    @gnugrep@/bin/grep -qE 'local-only|\\[uU][0-9a-fA-F]{4}' "$f"; rc=$?
    [ "$rc" = 1 ] || return 0
  done
  return 1
}

if [ "${LIFEOS_GATE:-}" = off ]; then
  names_local_only && refuse "LIFEOS_GATE=off is not allowed while a config may name local-only"
  exec "$real" "$@"
fi

gate=""
for r in "${roots[@]}"; do
  if [ -f "$r/LIFEOS/TOOLS/InferenceProvider.ts" ]; then gate="$r/LIFEOS/TOOLS/InferenceProvider.ts"; break; fi
done
if [ -z "$gate" ]; then
  # No gate (no LifeOS, or a payload not yet synced): plain claude, unless local-only is asked.
  names_local_only && refuse "a config may name local-only but the inference gate is missing"
  exec "$real" "$@"
fi

# Run the gate from / with no bunfig (a project bunfig.toml preload would run inside the
# decision) and no .env. Protocol on fd 3 only, so nothing a module prints can be eval'd; the
# last line must be the sentinel, or the gate did not speak the protocol (e.g. an older
# payload) and we refuse.
export HOME="${HOME:-$pwhome}"
code="$(cd / && @bun@/bin/bun --no-env-file --config=/dev/null "$gate" gate 3>&1 1>&2)" || exit 3
[ "${code##*$'\n'}" = ": lifeos-gate-ok" ] || refuse "inference gate gave no decision (stale LifeOS payload?)"
# eval's status is the sentinel's (always 0), so prove the delta applies under set -e first.
# Own line, status read after: on the left of `||` bash ignores set -e, even in a subshell.
( set -e; eval "$code" ) >/dev/null 2>&1
[ $? -eq 0 ] || refuse "inference gate output did not apply"
eval "$code"
exec "$real" "$@"
