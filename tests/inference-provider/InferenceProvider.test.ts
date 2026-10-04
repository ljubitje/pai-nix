import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ANTHROPIC_ONLY, localEnv, localModelFor, resolveProviderConfig, tierOf, loadProviderConfig,
} from "./InferenceProvider";

// Runs inside a materialised payload (see run.sh): HOME is a temp dir, so observability
// writes land in it, and PATH starts with a fake `claude` that records every spawn.
const HOME = process.env.HOME!;
const SPAWNS = join(HOME, "spawns.jsonl");
const EVENTS = join(HOME, ".claude/LIFEOS/MEMORY/OBSERVABILITY/inference-provider.jsonl");
const TOOLS = import.meta.dir;

const LOCAL = {
  mode: "local-with-fallback",
  local: { base_url: "http://127.0.0.1:9/", model: "big-local", models: { haiku: "small-local" } },
};

// ── ISC-140 / ISC-141: resolution ───────────────────────────────────────────────

test("no [inference] section resolves to anthropic-only", () => {
  expect(resolveProviderConfig(undefined)).toEqual(ANTHROPIC_ONLY);
  expect(resolveProviderConfig({ mode: "anthropic-only", local: { base_url: "nonsense" } })).toEqual(ANTHROPIC_ONLY);
});

test("missing config file resolves to anthropic-only", () => {
  process.env.LIFEOS_CONFIG_PATH = join(HOME, "does-not-exist.toml");
  expect(loadProviderConfig()).toEqual(ANTHROPIC_ONLY);
});

test("config file without [inference] resolves to anthropic-only", () => {
  const p = join(HOME, "plain.toml");
  writeFileSync(p, '[principal]\nname = "x"\n');
  process.env.LIFEOS_CONFIG_PATH = p;
  expect(loadProviderConfig()).toEqual(ANTHROPIC_ONLY);
});

test.each([
  [{ mode: "lokal-only" }, /mode/],
  [{ mode: "local-only" }, /\[inference\.local\]/],
  [{ mode: "local-only", local: { model: "m" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "ftp://x", model: "m" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "http://x" } }, /no model for tier/],
  [{ mode: "local-only", local: { base_url: "http://x", model: "m", models: { gpt: "y" } } }, /unknown tier/],
  [{ mode: "local-only", local: { base_url: "http://x", model: "m", token_env: "" } }, /token_env/],
])("invalid section refuses loudly: %j", (raw, msg) => {
  expect(() => resolveProviderConfig(raw, "/cfg.toml")).toThrow(msg);
  expect(() => resolveProviderConfig(raw, "/cfg.toml")).toThrow(/\/cfg\.toml/);
});

test("tiers fill from the default model, overrides win, trailing slash trimmed", () => {
  const c = resolveProviderConfig(LOCAL);
  expect(c.local!.baseUrl).toBe("http://127.0.0.1:9");
  expect(c.local!.models).toEqual({ fable: "big-local", opus: "big-local", sonnet: "big-local", haiku: "small-local" });
});

test("aliases and pinned ids map to their tier's local model", () => {
  const { local } = resolveProviderConfig(LOCAL);
  expect(tierOf("claude-fable-5")).toBe("fable");
  expect(tierOf("claude-haiku-4-5-20251001")).toBe("haiku");
  expect(localModelFor(local!, "haiku")).toBe("small-local");
  expect(localModelFor(local!, "claude-opus-5")).toBe("big-local");
  expect(localModelFor(local!, "something-else")).toBe("big-local");
});

// ── ISC-142 / ISC-144: local env ────────────────────────────────────────────────

test("local env points claude at the server and never carries the API key", () => {
  const cfg = resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, token_env: "MY_TOK" } });
  const env = localEnv({ ANTHROPIC_API_KEY: "sk-x", MY_TOK: "secret", KEEP: "1" }, cfg);
  expect(env.ANTHROPIC_API_KEY).toBeUndefined();
  expect(env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:9");
  expect(env.ANTHROPIC_AUTH_TOKEN).toBe("secret");
  expect(env.ANTHROPIC_DEFAULT_FABLE_MODEL).toBe("big-local");
  expect(env.ANTHROPIC_DEFAULT_OPUS_MODEL).toBe("big-local");
  expect(env.ANTHROPIC_DEFAULT_SONNET_MODEL).toBe("big-local");
  expect(env.ANTHROPIC_DEFAULT_HAIKU_MODEL).toBe("small-local");
  expect(env.ANTHROPIC_SMALL_FAST_MODEL).toBe("small-local");
  expect(env.KEEP).toBe("1");
  expect(env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBeUndefined();
});

test("no token configured still sets a placeholder AUTH_TOKEN (outranks OAuth)", () => {
  const env = localEnv({}, resolveProviderConfig(LOCAL));
  expect(env.ANTHROPIC_AUTH_TOKEN).toBe("lifeos-local-no-auth");
});

test("local-only also disables nonessential traffic", () => {
  const env = localEnv({}, resolveProviderConfig({ ...LOCAL, mode: "local-only" }));
  expect(env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBe("1");
});

// ── ISC-145 / ISC-147 / ISC-148 / ISC-149: Inference.ts end to end, fake claude ───

function writeConfig(mode: string | null): void {
  const p = join(HOME, "cfg.toml");
  const body = mode === null ? "" : `[inference]\nmode = "${mode}"\n[inference.local]\nbase_url = "http://127.0.0.1:9"\nmodel = "big-local"\n`;
  writeFileSync(p, body);
  process.env.LIFEOS_CONFIG_PATH = p;
}
const spawns = () =>
  existsSync(SPAWNS) ? readFileSync(SPAWNS, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
const events = () =>
  existsSync(EVENTS) ? readFileSync(EVENTS, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
async function run(level = "low") {
  rmSync(SPAWNS, { force: true });
  rmSync(EVENTS, { force: true });
  const { inference } = await import("./Inference");
  return inference({ systemPrompt: "s", userPrompt: "u", level: level as any, timeout: 10_000 });
}

test("anthropic-only: one spawn, no local vars, no provider field (pre-patch path)", async () => {
  writeConfig(null);
  process.env.FAKE_LOCAL_FAIL = "0";
  const r = await run();
  const s = spawns();
  expect(r.success).toBe(true);
  expect(r.provider).toBeUndefined();
  expect(s.length).toBe(1);
  expect(Object.keys(s[0].env).filter((k) => k.startsWith("ANTHROPIC_"))).toEqual([]);
  expect(s[0].model).toBe("haiku");
});

test("local-with-fallback, local healthy: answers locally, no false downgrade", async () => {
  writeConfig("local-with-fallback");
  process.env.FAKE_LOCAL_FAIL = "0";
  const r = await run();
  const s = spawns();
  expect(r.success).toBe(true);
  expect(r.provider).toBe("local");
  expect(s.length).toBe(1);
  expect(s[0].env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:9");
  expect(s[0].model).toBe("big-local");
  expect(r.executedModel).toBe("big-local");
  expect(r.modelDowngraded).toBe(false);
});

test("local-with-fallback, local down: retries once on Anthropic and records it", async () => {
  writeConfig("local-with-fallback");
  process.env.FAKE_LOCAL_FAIL = "1";
  const r = await run();
  const s = spawns();
  expect(r.success).toBe(true);
  expect(r.provider).toBe("anthropic");
  expect(r.fallbackFrom).toBeTruthy();
  expect(s.length).toBe(2);
  expect(s[0].env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:9");
  expect(s[1].env.ANTHROPIC_BASE_URL).toBeUndefined();
  expect(s[1].env.ANTHROPIC_AUTH_TOKEN).toBeUndefined();
  expect(events().map((e) => e.event)).toEqual(["fallback"]);
});

test("max level, single local model: no wasted rung retry before provider fallback", async () => {
  writeConfig("local-with-fallback");
  process.env.FAKE_LOCAL_FAIL = "1";
  await run("max");
  const s = spawns();
  expect(s.filter((x) => x.env.ANTHROPIC_BASE_URL).length).toBe(1);
});

test("local-only, local down: fails closed, Anthropic never spawned", async () => {
  writeConfig("local-only");
  process.env.FAKE_LOCAL_FAIL = "1";
  const r = await run();
  const s = spawns();
  expect(r.success).toBe(false);
  expect(r.provider).toBe("local");
  expect(s.length).toBe(1);
  expect(s.every((x) => x.env.ANTHROPIC_BASE_URL === "http://127.0.0.1:9")).toBe(true);
});

test("invalid config: fails closed with zero spawns", async () => {
  writeFileSync(join(HOME, "cfg.toml"), '[inference]\nmode = "lokal-only"\n');
  process.env.LIFEOS_CONFIG_PATH = join(HOME, "cfg.toml");
  const r = await run();
  expect(r.success).toBe(false);
  expect(r.error).toMatch(/provider config invalid/);
  expect(spawns().length).toBe(0);
  expect(events().map((e) => e.event)).toEqual(["config-invalid"]);
});

// ── ISC-146: launcher health check, against a fake server that can be up or down ──

let server: ReturnType<typeof Bun.serve> | undefined;
let up = true;
beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch: (req) => {
      if (!up) return new Response("down", { status: 503 });
      return new URL(req.url).pathname === "/v1/models"
        ? Response.json({ data: [{ id: "big-local" }] })
        : new Response("nope", { status: 404 });
    },
  });
});
afterAll(() => server?.stop(true));

async function launcher(mode: string) {
  const p = join(HOME, "cfg.toml");
  writeFileSync(p, `[inference]\nmode = "${mode}"\n[inference.local]\nbase_url = "http://127.0.0.1:${server!.port}"\nmodel = "big-local"\n`);
  rmSync(SPAWNS, { force: true });
  rmSync(EVENTS, { force: true });
  const proc = Bun.spawn(["bun", join(TOOLS, "lifeos.ts"), "-p", "hello"], {
    env: { ...process.env, LIFEOS_CONFIG_PATH: p, FAKE_LOCAL_FAIL: "0" },
    stdout: "pipe", stderr: "pipe",
  });
  const code = await proc.exited;
  return { code, stderr: await new Response(proc.stderr).text(), spawns: spawns(), events: events() };
}

test("launcher: healthy server → claude gets the local env", async () => {
  up = true;
  const r = await launcher("local-with-fallback");
  expect(r.code).toBe(0);
  expect(r.spawns.length).toBe(1);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(`http://127.0.0.1:${server!.port}`);
  expect(r.stderr).toMatch(/inference: local/);
});

test("launcher: server down + fallback → Anthropic env, visible notice, event recorded", async () => {
  up = false;
  const r = await launcher("local-with-fallback");
  expect(r.code).toBe(0);
  expect(r.spawns.length).toBe(1);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined();
  expect(r.stderr).toMatch(/fallback/);
  expect(r.events.map((e: any) => e.event)).toEqual(["fallback"]);
});

test("launcher: server down + local-only → refuses, claude never spawned", async () => {
  up = false;
  const r = await launcher("local-only");
  expect(r.code).not.toBe(0);
  expect(r.spawns.length).toBe(0);
  expect(r.stderr).toMatch(/local-only/);
  expect(r.events.map((e: any) => e.event)).toEqual(["refused"]);
});

// Fixture sanity: the fake claude must be the one on PATH, or every assertion above is about
// a real binary. (Positive control for the spawn recorder.)
test("fake claude is first on PATH", () => {
  expect(Bun.which("claude")).toBe(join(HOME, "bin", "claude"));
});
