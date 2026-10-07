#!@bash@/bin/bash
# lifeos-nix inference gate for claude — see default.nix. Reads the inference mode from
# LIFEOS/USER/CONFIG/inference.conf under the account's passwd home, exactly and in shell,
# then execs the real binary in place (TTY, signals and exit code stay the real claude's).
# anthropic-only (also: no file) costs what upstream costs: no bun, no parse. Local modes ask
# LifeOS's InferenceProvider.ts for the env. It routes; the local-only guarantee is the
# network room (ISA Step 7c). Anything that cannot be read exactly refuses.
# bash imports an exported SHELLOPTS: errexit would kill this script on a zero grep count,
# xtrace would print the env delta (a local token) to stderr. Start from known options.
set +e +u +x +v +o pipefail
real=@real@
refuse() { echo "❌ claude: $*" >&2; exit 3; }

# The account's home from passwd, not $HOME (callers can point $HOME anywhere). $HOME only when
# passwd cannot resolve the uid (container --user, sssd/LDAP the nix glibc cannot load).
home="$(@getent@/bin/getent passwd "$(@coreutils@/bin/id -u)" | @coreutils@/bin/cut -d: -f6)"
home="${home:-${HOME:-}}"
[ -n "$home" ] || refuse "cannot tell this account's home (passwd and \$HOME both empty)"
conf="$home/.claude/LIFEOS/USER/CONFIG/inference.conf"

# Read it ONCE; everything below (this script, the gate, Inference.ts via --lifeos-gate-query)
# decides from this one text. CR is dropped and NUL becomes a space (which then fails the line
# rule), the same normalisation InferenceProvider.parseConf applies. Absent (ENOENT on a path
# that is not a dangling link) is anthropic-only; any other read error refuses.
text="$(LC_ALL=C @coreutils@/bin/cat -- "$conf" 2>&1 | LC_ALL=C @coreutils@/bin/tr -d '\r' | LC_ALL=C @coreutils@/bin/tr '\000' ' '; exit "${PIPESTATUS[0]}")"
if [ $? -eq 0 ]; then
  # Same rules as parseConf: each line a comment, blank, or known_key=value without spaces;
  # no key twice.
  bad="$(printf '%s\n' "$text" | LC_ALL=C @gnugrep@/bin/grep -Evc '^[[:space:]]*(#.*)?$|^(mode|base_url|model|model_fable|model_opus|model_sonnet|model_haiku|token_env)=[^[:space:]]+$')"
  [ "$bad" = 0 ] || refuse "$conf: every line must be a comment or key=value with a known key (no spaces, no quotes)"
  dup="$(printf '%s\n' "$text" | LC_ALL=C @gnugrep@/bin/grep -oE '^[a-z_]+=' | LC_ALL=C @coreutils@/bin/sort | LC_ALL=C @coreutils@/bin/uniq -d)"
  [ -z "$dup" ] || refuse "$conf: ${dup%=} given twice"
  settings="$(printf '%s\n' "$text" | LC_ALL=C @gnugrep@/bin/grep -cE '^[a-z_]+=')"
  modes="$(printf '%s\n' "$text" | LC_ALL=C @gnugrep@/bin/grep -E '^mode=')"
  case "$modes" in
    "")                         [ "$settings" = 0 ] && mode=anthropic-only || mode="" ;;  # no mode: the gate decides
    mode=anthropic-only)        mode=anthropic-only ;;
    mode=local-with-fallback)   mode=local-with-fallback ;;
    mode=local-only)            mode=local-only ;;
    *)                          refuse "$conf: mode must be anthropic-only | local-with-fallback | local-only" ;;
  esac
else
  case "$text" in
    *"No such file or directory"*) mode=anthropic-only; text="" ;;
    *) refuse "cannot read $conf: ${text##*: }" ;;
  esac
fi

# For Inference.ts: the wrapper's own reading, so in-process code never re-derives the home or
# re-reads the file. Not a claude flag; never reaches the real binary.
if [ "${1:-}" = --lifeos-gate-query ]; then
  printf 'mode=%s\n---\n%s\n' "$mode" "$text"
  exit 0
fi

if [ "$mode" = anthropic-only ] && [ -z "${LIFEOS_INFERENCE_LOCAL:-}" ] && [ -z "${LIFEOS_INFERENCE_TARGET:-}" ]; then
  exec "$real" "$@"   # the upstream path, untouched
fi

# Manual escape hatch, never set by code: allowed except where Anthropic is forbidden.
if [ "${LIFEOS_GATE:-}" = off ]; then
  [ "$mode" = local-only ] || [ -z "$mode" ] && refuse "LIFEOS_GATE=off is not allowed when $conf may say local-only"
  exec "$real" "$@"
fi

gate="$home/.claude/LIFEOS/TOOLS/InferenceProvider.ts"
[ -f "$gate" ] || refuse "inference mode is ${mode:-unset} but the gate ($gate) is missing"

# Run the gate from / with no bunfig (a project bunfig.toml preload would run inside the
# decision) and no .env. Protocol on fd 3 only, so nothing a module prints can be eval'd; the
# last line must be the sentinel, or the gate did not speak the protocol (e.g. an older
# payload) and we refuse.
export HOME="${HOME:-$home}"
# The gate decides from the text read above (stdin) and must agree with this script's mode.
code="$(printf '%s\n' "$text" | (cd / && @bun@/bin/bun --no-env-file --config=/dev/null "$gate" gate --conf "$conf" --mode "$mode") 3>&1 1>&2)" || exit 3
[ "${code##*$'\n'}" = ": lifeos-gate-ok" ] || refuse "inference gate gave no decision (stale LifeOS payload?)"
# eval's status is the sentinel's (always 0), so prove the delta applies under set -e first.
# Own line, status read after: on the left of `||` bash ignores set -e, even in a subshell.
( set -e; eval "$code" ) >/dev/null 2>&1
[ $? -eq 0 ] || refuse "inference gate output did not apply"
eval "$code"
exec "$real" "$@"
