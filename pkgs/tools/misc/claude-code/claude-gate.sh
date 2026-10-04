#!@bash@/bin/bash
# lifeos-nix inference gate for claude — see default.nix. Decides the model server for this
# exec via LifeOS's InferenceProvider.ts, then execs the real binary in place (TTY, signals
# and exit code stay the real claude's).
real=@real@
if [ "${LIFEOS_GATE:-}" = off ]; then exec "$real" "$@"; fi
gate="${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}/LIFEOS/TOOLS/InferenceProvider.ts"
if [ ! -f "$gate" ]; then
  if [ "${LIFEOS_INFERENCE_MODE:-}" = local-only ]; then
    echo "❌ claude: LIFEOS_INFERENCE_MODE=local-only but the inference gate ($gate) is missing — refusing" >&2
    exit 3
  fi
  exec "$real" "$@"
fi
# --no-env-file: bun would otherwise load a .env from the cwd into the decision.
code="$(@bun@/bin/bun --no-env-file "$gate" gate)" || exit 3
eval "$code"
exec "$real" "$@"
