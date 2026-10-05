#!@bash@/bin/bash
# lifeos-nix inference gate for claude — see default.nix. Decides the model server for this
# exec via LifeOS's InferenceProvider.ts, then execs the real binary in place (TTY, signals
# and exit code stay the real claude's). Every path that cannot prove a decision refuses.
real=@real@
refuse() { echo "❌ claude: $*" >&2; exit 3; }

# The marker is inherited from a local-only session: such a descendant may never leave the gate.
sticky=0; [ "${LIFEOS_INFERENCE_MODE:-}" = local-only ] && sticky=1
if [ "${LIFEOS_GATE:-}" = off ]; then
  [ "$sticky" = 1 ] && refuse "LIFEOS_GATE=off is not allowed inside a local-only session"
  exec "$real" "$@"
fi

# Where LifeOS lives. CLAUDE_CONFIG_DIR first, then the account's home from passwd (not $HOME,
# which a caller can unset or point elsewhere while claude itself still finds the real home).
pwhome="$(getent passwd "$(id -u)" | cut -d: -f6)"
gate=""
for root in "${CLAUDE_CONFIG_DIR:-}" "${pwhome:+$pwhome/.claude}"; do
  if [ -n "$root" ] && [ -f "$root/LIFEOS/TOOLS/InferenceProvider.ts" ]; then
    gate="$root/LIFEOS/TOOLS/InferenceProvider.ts"; break
  fi
done
if [ -z "$gate" ]; then
  [ "$sticky" = 1 ] && refuse "local-only session but the inference gate is missing"
  # No gate, but a config that names local-only (e.g. payload not yet synced): refuse.
  grep -qs 'local-only' "${pwhome:-/nonexistent}/.claude/LIFEOS/USER/CONFIG/LIFEOS_CONFIG.toml" \
    && refuse "LIFEOS_CONFIG.toml mentions local-only but the inference gate is missing"
  exec "$real" "$@"
fi

# Run the gate from / with no bunfig (a project bunfig.toml preload would run inside the
# decision) and no .env. Protocol on fd 3 only, so nothing a module prints can be eval'd; the
# last line must be the sentinel, or the gate did not speak the protocol (e.g. an older
# payload) and we refuse.
export HOME="${HOME:-$pwhome}"
cwd="$PWD"   # the gate checks the caller's project settings, so it needs the real cwd
code="$(cd / && LIFEOS_GATE_CWD="$cwd" @bun@/bin/bun --no-env-file --config=/dev/null "$gate" gate "$@" 3>&1 1>&2)" || exit 3
[ "${code##*$'\n'}" = ": lifeos-gate-ok" ] || refuse "inference gate gave no decision (stale LifeOS payload?)"
eval "$code" || refuse "inference gate output did not apply"
exec "$real" "$@"
