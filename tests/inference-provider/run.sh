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
if (!process.env.ANTHROPIC_BASE_URL && process.env.FAKE_ANTHROPIC_SLEEP_MS) await Bun.sleep(Number(process.env.FAKE_ANTHROPIC_SLEEP_MS));
if (process.env.ANTHROPIC_BASE_URL && process.env.FAKE_LOCAL_FAIL === "1") { console.error("connection refused"); process.exit(1); }
console.log(JSON.stringify({ result: "ok", modelUsage: { [model]: { outputTokens: 5 } } }));
FAKE
chmod +x "$TREE/real/claude"

# HOME/.claude IS the payload. The gate's passwd lookup is a fake that reports $FAKE_PW_HOME
# (default: the sandbox home), so nothing can fall through to the real home of whoever runs
# the suite. A second gate copy has a getent that resolves nothing (unknown uid).
ln -s "$ROOT" "$TREE/home/.claude"
mkdir -p "$TREE/pw-home/bin" "$TREE/pw-none/bin"
printf '#!/bin/sh\necho "u:x:1000:1000::${FAKE_PW_HOME:-%s}:/bin/sh"\n' "$TREE/home" > "$TREE/pw-home/bin/getent"
printf '#!/bin/sh\nexit 2\n' > "$TREE/pw-none/bin/getent"
chmod +x "$TREE/pw-home/bin/getent" "$TREE/pw-none/bin/getent"
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
gate_copy "$TREE/home/bin/claude" "$TREE/pw-home"
gate_copy "$TREE/nopw-gate/claude" "$TREE/pw-none"

cd "$ROOT/LIFEOS/TOOLS"
# A clean environment: nothing from the shell that runs the suite (a local session's
# ANTHROPIC_*/LIFEOS_* variables, XDG dirs, bun caches) can reach the code under test.
BUN_DIR="$(dirname "$(command -v bun)")"   # absolute, so the clean env below never depends on the caller's PATH
env -i PATH="$TREE/home/bin:$BUN_DIR:$PATH" HOME="$TREE/home" TMPDIR="$TREE/tmp" \
  XDG_CACHE_HOME="$TREE/cache" XDG_CONFIG_HOME="$TREE/config" \
  SPAWNS_FILE="$TREE/home/spawns.jsonl" NOPW_GATE="$TREE/nopw-gate/claude" \
  bash -c 'mkdir -p "$TMPDIR" && exec bun test InferenceProvider.test.ts'
