#!@bash@/bin/bash
# lifeos-nix inference gate for claude — see default.nix. Reads the inference mode from
# LIFEOS/USER/CONFIG/inference.conf under the account's passwd home, exactly and in shell,
# then execs the real binary in place (TTY, signals and exit code stay the real claude's).
# anthropic-only (also: no file) costs about what upstream costs: one getent, one tr, no bun.
# Local modes ask LifeOS's InferenceProvider.ts for the env.
#
# The bar (Klemen, 2026-10-08): anthropic-only behaves as upstream; local modes route
# correctly under normal conditions; plain misconfiguration refuses. Edge cases under
# local-only (unmounted disks, a foreign $HOME, flaky filesystems) are the network room's
# job (ISA Step 7c), not this script's.

# bash imports an exported SHELLOPTS: errexit would kill this script, xtrace would print the
# env delta (a local token) to stderr. Start from known options.
set +e +u +x +v +o pipefail
real=@real@
refuse() { echo "❌ claude: $*" >&2; exit 3; }

# parse_conf FILE: sets conf_mode ("" = no mode line but settings present: the gate decides)
# and conf_text (normalised), or refuses. Same rules as InferenceProvider.parseConf: NUL
# becomes a space and CR a newline; each line a comment, blank, or known_key=value with no
# whitespace in the value; no key twice. Pure bash after one tr: no grep/sort per exec.
parse_conf() {
  local f="$1" LC_ALL=C line key n=0 settings=0
  local -A seen=()
  conf_text="$(@coreutils@/bin/tr '\000\r' ' \n' < "$f")" || refuse "cannot read $f"
  conf_mode=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ ^(mode|base_url|model|model_fable|model_opus|model_sonnet|model_haiku|token_env)=[^[:space:]]+$ ]] \
      || refuse "$f:$n: every line must be a comment or key=value with a known key (no spaces, no quotes)"
    key="${BASH_REMATCH[1]}"
    [ -z "${seen[$key]:-}" ] || refuse "$f:$n: $key given twice"
    seen[$key]=1
    settings=$((settings + 1))
    [ "$key" = mode ] && conf_mode="${line#mode=}"
  done <<< "$conf_text"
  case "$conf_mode" in
    "")                  [ "$settings" = 0 ] && conf_mode=anthropic-only ;;
    anthropic-only|local-with-fallback|local-only) ;;
    *)                   refuse "$f: mode must be anthropic-only | local-with-fallback | local-only" ;;
  esac
}

# read_conf FILE: like parse_conf, but a path that is genuinely not there (no file, no link to
# nothing) is anthropic-only with no text.
read_conf() {
  if [ -e "$1" ]; then parse_conf "$1"
  elif [ -L "$1" ]; then refuse "$1 is a link to nothing"
  else conf_mode=anthropic-only; conf_text=""
  fi
}

# The account's home from passwd, not $HOME (callers can point $HOME anywhere). $HOME only when
# passwd cannot resolve the uid (container --user, sssd/LDAP the nix glibc cannot load).
pw="$(@getent@/bin/getent passwd "$EUID")"
home="${pw%:*}"; home="${home##*:}"
home="${home:-${HOME:-}}"
[ -n "$home" ] || refuse "cannot tell this account's home (passwd and \$HOME both empty)"
conf="$home/.claude/LIFEOS/USER/CONFIG/inference.conf"

# A link along the path that points nowhere (a moved USER tree) must not read as "no config".
p="$home"
for c in .claude LIFEOS USER CONFIG; do
  p="$p/$c"
  if [ -L "$p" ] && [ ! -e "$p" ]; then refuse "$p is a link to nothing"; fi
  [ -e "$p" ] || break
done

read_conf "$conf"
mode="$conf_mode"; text="$conf_text"

# A second LifeOS (the launcher honours CLAUDE_CONFIG_DIR) with an inference.conf that means
# something else is ambiguous; refuse rather than ignore it. Fine: no file there, both
# anthropic-only, or the same text (which is also what the same tree reads as).
other="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/LIFEOS/USER/CONFIG/inference.conf}"
if [ -n "$other" ] && { [ -e "$other" ] || [ -L "$other" ]; }; then
  read_conf "$other"
  if ! { [ "$conf_mode" = anthropic-only ] && [ "$mode" = anthropic-only ]; } && [ "$conf_text" != "$text" ]; then
    refuse "CLAUDE_CONFIG_DIR's inference.conf differs from $conf; this gate reads the latter only"
  fi
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

# Run the gate from / with no bunfig and no .env. It decides from the text read above (stdin,
# no second read) and must agree with this script's mode. Protocol on fd 3 only, so nothing a
# module prints can be eval'd; the last line must be the sentinel, or the gate did not speak the
# protocol (e.g. an older payload) and we refuse.
export HOME="${HOME:-$home}"
code="$(printf '%s\n' "$text" | (cd / && @bun@/bin/bun --no-env-file --config=/dev/null "$gate" gate --conf "$conf" --mode "$mode") 3>&1 1>&2)" || exit 3
[ "${code##*$'\n'}" = ": lifeos-gate-ok" ] || refuse "inference gate gave no decision (stale LifeOS payload?)"
# eval's status is the sentinel's (always 0), so prove the delta applies under set -e first.
# Own line, status read after: on the left of `||` bash ignores set -e, even in a subshell.
( set -e; eval "$code" ) >/dev/null 2>&1
[ $? -eq 0 ] || refuse "inference gate output did not apply"
eval "$code"
exec "$real" "$@"
