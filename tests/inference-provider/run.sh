#!/usr/bin/env bash
# Materialise the patched payload in a temp dir and run the InferenceProvider suite against it,
# through the real claude-gate.sh. The files under test exist only inside the patches until a
# build applies them, so this is that build in miniature.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# Baseline = the pinned upstream source plus the package's own patch list, in order, exactly
# as the derivation applies it. Never the live ~/.claude: after a deploy it already carries
# this patch, and `patch --forward` would then abort the suite (review 4).
SRC="$(nix eval --raw "$REPO#lifeos.src")"
nix build --no-link "$SRC" >/dev/null 2>&1 || nix-store --realise "$SRC" >/dev/null

TREE="$(mktemp -d)"; trap 'rm -rf "${TREE:?}"' EXIT
ROOT="$TREE/LifeOS/install"
cp -r "$SRC/." "$TREE/"
chmod -R u+w "$TREE"
mkdir -p "$TREE/home/bin"
( cd "$TREE"
  awk '/^  patches = \[/{f=1;next} f&&/^  \];/{f=0} f' "$REPO/pkgs/tools/misc/lifeos/default.nix" \
    | rg -o '\./patches/[^ ]+\.patch' \
    | while read -r p; do patch -p1 --silent --batch --forward -i "$REPO/pkgs/tools/misc/lifeos/$p"; done )
cp "$HERE/InferenceProvider.test.ts" "$ROOT/LIFEOS/TOOLS/"

# Fake real claude: records argv model + the provider-relevant env of every exec in
# $SPAWNS_FILE, fails when pointed at a local server and FAKE_LOCAL_FAIL=1, otherwise answers
# with a JSON envelope whose modelUsage names the model it was asked for. It sits BEHIND the
# real gate script.
mkdir -p "$TREE/real"
cat > "$TREE/real/claude" <<'FAKE'
#!/usr/bin/env -S bun --config=/dev/null
import { appendFileSync } from "node:fs";
const a = process.argv.slice(2);
const i = a.indexOf("--model");
const model = i >= 0 ? a[i + 1] : process.env.ANTHROPIC_MODEL ?? "default";
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(ANTHROPIC_|CLAUDE_CODE_DISABLE|LIFEOS_INFERENCE|ENABLE_CLAUDEAI)/.test(k)));
appendFileSync(process.env.SPAWNS_FILE!, JSON.stringify({ model, env }) + "\n");
if (a.includes("--print")) await Bun.stdin.text();
if (process.env.ANTHROPIC_BASE_URL && process.env.FAKE_LOCAL_FAIL === "1") { console.error("connection refused"); process.exit(1); }
console.log(JSON.stringify({ result: "ok", modelUsage: { [model]: { outputTokens: 5 } } }));
FAKE
chmod +x "$TREE/real/claude"

# HOME/.claude IS the payload. The gate's passwd lookup is a fake too, so nothing can fall
# through to the real home of whoever runs the suite.
ln -s "$ROOT" "$TREE/home/.claude"
NOGATE_HOME="$TREE/nogate-home"; mkdir -p "$NOGATE_HOME/.claude/LIFEOS/USER/CONFIG"
fake_getent() {   # $1 = dir for bin/getent, $2 = home it reports ("" = unknown uid)
  mkdir -p "$1/bin"
  if [ -n "$2" ]; then printf '#!/bin/sh\necho "u:x:1000:1000::%s:/bin/sh"\n' "$2" > "$1/bin/getent"
  else printf '#!/bin/sh\nexit 2\n' > "$1/bin/getent"; fi
  chmod +x "$1/bin/getent"
}
gate_copy() {     # $1 = output path, $2 = getent dir. The gate exactly as the derivation installs it.
  mkdir -p "$(dirname "$1")"
  sed -e "s|@bash@|$(dirname "$(dirname "$(command -v bash)")")|g" \
      -e "s|@bun@|$(dirname "$(dirname "$(command -v bun)")")|g" \
      -e "s|@real@|$TREE/real/claude|g" \
      -e "s|@getent@|$2|g" \
      -e "s|@coreutils@|$(dirname "$(dirname "$(command -v id)")")|g" \
      -e "s|@gnugrep@|$(dirname "$(dirname "$(command -v grep)")")|g" \
      "$REPO/pkgs/tools/misc/claude-code/claude-gate.sh" > "$1"
  chmod +x "$1"
}
fake_getent "$TREE/pw-home" "$TREE/home";        gate_copy "$TREE/home/bin/claude" "$TREE/pw-home"
fake_getent "$TREE/pw-none" "";                  gate_copy "$TREE/nopw-gate/claude" "$TREE/pw-none"
fake_getent "$TREE/pw-nogate" "$NOGATE_HOME";    gate_copy "$TREE/nogate-gate/claude" "$TREE/pw-nogate"

cd "$ROOT/LIFEOS/TOOLS"
# Scrub provider vars from the outer shell so the anthropic-only assertions see only what
# the code under test sets.
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDECODE \
  -u LIFEOS_INFERENCE_MODE -u LIFEOS_INFERENCE_TARGET -u LIFEOS_GATE -u XDG_RUNTIME_DIR -u CLAUDE_CONFIG_DIR \
  HOME="$TREE/home" SPAWNS_FILE="$TREE/home/spawns.jsonl" NOGATE_HOME="$NOGATE_HOME" \
  NOPW_GATE="$TREE/nopw-gate/claude" NOGATE_GATE="$TREE/nogate-gate/claude" PATH="$TREE/home/bin:$PATH" \
  bun test InferenceProvider.test.ts
