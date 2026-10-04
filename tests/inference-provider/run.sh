#!/usr/bin/env bash
# Materialise the patched TOOLS tree in a temp dir and run the InferenceProvider suite.
# The files under test exist only inside f-inference-provider.patch until a build applies
# it, so this is that build in miniature: live TOOLS (== patched baseline) + this patch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PATCH="$REPO/pkgs/tools/misc/lifeos/patches/f-inference-provider.patch"
SRC="${LIFEOS_LIVE:-$HOME/.claude}"

TREE="$(mktemp -d)"; trap 'rm -rf "${TREE:?}"' EXIT
ROOT="$TREE/LifeOS/install"
mkdir -p "$ROOT/LIFEOS/TOOLS" "$TREE/home/bin"
cp -r "$SRC/LIFEOS/TOOLS/." "$ROOT/LIFEOS/TOOLS/"
chmod -R u+w "$TREE"
# A live tree that already carries a dev copy of the new file would half-apply.
rm -f "$ROOT/LIFEOS/TOOLS/InferenceProvider.ts"
( cd "$TREE" && patch -p1 --silent --batch --forward -i "$PATCH" )
cp "$HERE/InferenceProvider.test.ts" "$ROOT/LIFEOS/TOOLS/"

# Fake real claude: records argv model + the provider-relevant env of every exec, fails when
# pointed at a local server and FAKE_LOCAL_FAIL=1, otherwise answers with a JSON envelope
# whose modelUsage names the model it was asked for. It sits BEHIND the real gate script.
mkdir -p "$TREE/real"
cat > "$TREE/real/claude" <<'FAKE'
#!/usr/bin/env bun
import { appendFileSync } from "node:fs";
const a = process.argv.slice(2);
const i = a.indexOf("--model");
const model = i >= 0 ? a[i + 1] : process.env.ANTHROPIC_MODEL ?? "default";
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(ANTHROPIC_|CLAUDE_CODE_DISABLE|LIFEOS_INFERENCE|ENABLE_CLAUDEAI)/.test(k)));
appendFileSync(`${process.env.HOME}/spawns.jsonl`, JSON.stringify({ model, env }) + "\n");
if (a.includes("--print")) await Bun.stdin.text();
if (process.env.ANTHROPIC_BASE_URL && process.env.FAKE_LOCAL_FAIL === "1") { console.error("connection refused"); process.exit(1); }
console.log(JSON.stringify({ result: "ok", modelUsage: { [model]: { outputTokens: 5 } } }));
FAKE
chmod +x "$TREE/real/claude"
# The gate exactly as the claude-code derivation installs it, pointed at the fake.
sed -e "s|@bash@|$(dirname "$(dirname "$(command -v bash)")")|" \
    -e "s|@bun@|$(dirname "$(dirname "$(command -v bun)")")|" \
    -e "s|@real@|$TREE/real/claude|" \
    "$REPO/pkgs/tools/misc/claude-code/claude-gate.sh" > "$TREE/home/bin/claude"
chmod +x "$TREE/home/bin/claude"

cd "$ROOT/LIFEOS/TOOLS"
# Scrub provider vars from the outer shell so the anthropic-only assertions see only what
# the code under test sets.
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDECODE \
  -u LIFEOS_INFERENCE_MODE -u LIFEOS_INFERENCE_TARGET -u LIFEOS_GATE \
  HOME="$TREE/home" CLAUDE_CONFIG_DIR="$ROOT" PATH="$TREE/home/bin:$PATH" bun test InferenceProvider.test.ts
