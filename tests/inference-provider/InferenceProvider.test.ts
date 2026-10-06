import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ANTHROPIC_ONLY, anthropicEnv, decide, envDiffShell, localEnv, localModelFor,
  loadProviderConfig, resolveProviderConfig, tierOf, type ProviderConfig,
} from "./InferenceProvider";

// Runs inside a materialised payload (see run.sh). PATH starts with the REAL lifeos-nix gate
// script (claude-gate.sh) whose `real` binary is a fake claude that records every exec, so
// the end-to-end tests below cross the same seam a live spawn does.
const HOME = process.env.HOME!;
const SPAWNS = join(HOME, "spawns.jsonl");
const EVENTS = join(HOME, ".claude/LIFEOS/MEMORY/OBSERVABILITY/inference-provider.jsonl");
const CFG = join(HOME, "cfg.toml");
const GATE = Bun.which("claude")!;

const LOCAL = {
  mode: "local-with-fallback",
  local: { base_url: "http://127.0.0.1:9/", model: "big-local", models: { haiku: "small-local" } },
};
const lines = (p: string) =>
  existsSync(p) ? readFileSync(p, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
const spawns = () => lines(SPAWNS);
const events = () => lines(EVENTS).map((e) => e.event);
const reset = () => { rmSync(SPAWNS, { force: true }); rmSync(EVENTS, { force: true }); };

// ── resolution: fail closed on anything that is not clearly meant ─────────────────

test("no [inference] section, or empty one, resolves to anthropic-only", () => {
  expect(resolveProviderConfig(undefined)).toEqual(ANTHROPIC_ONLY);
  expect(resolveProviderConfig({})).toEqual(ANTHROPIC_ONLY);
});

test("[inference.local] without mode defaults to local-with-fallback", () => {
  expect(resolveProviderConfig({ local: LOCAL.local }).mode).toBe("local-with-fallback");
});

test("explicit anthropic-only wins over a configured local table", () => {
  expect(resolveProviderConfig({ ...LOCAL, mode: "anthropic-only" })).toEqual(ANTHROPIC_ONLY);
});

test.each([
  [{ mode: "lokal-only", local: LOCAL.local }, /mode/],
  [{ mdoe: "local-only", local: LOCAL.local }, /unknown key "mdoe"/],
  [{ local: { ...LOCAL.local, mode: "local-only" } }, /unknown key "mode"/], // mode under the wrong table
  [{ mode: "local-only" }, /\[inference\.local\]/],
  [{ mode: "local-only", local: { model: "m" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "ftp://x", model: "m" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "http://x" } }, /no model for tier/],
  [{ mode: "local-only", local: { base_url: "http://x", model: "m", models: { gpt: "y" } } }, /unknown key "gpt"/],
  [{ mode: "local-only", local: { base_url: "http://x", model: "m", token_env: "" } }, /token_env/],
  [{ mode: "anthropic-only", local: { base_url: "nonsense" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "http://x@api.anthropic.com", model: "m" } }, /plain http/],
  [{ mode: "local-only", local: { base_url: "https://api.anthropic.com", model: "m" } }, /points at Anthropic/],
  [{ mode: "local-only", local: { base_url: "https://foo.claude.ai/v1", model: "m" } }, /points at Anthropic/],
  [{ mode: "local-only", local: { base_url: "https://api.anthropic.com./", model: "m" } }, /points at Anthropic/],
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
  expect(localModelFor(local!, "haiku")).toBe("small-local");
  expect(localModelFor(local!, "claude-opus-5")).toBe("big-local");
});

// ── sticky local-only: a descendant can never lose it ────────────────────────────

test("no config file → anthropic-only, but with the local-only marker → refuses", () => {
  process.env.LIFEOS_CONFIG_PATH = join(HOME, "missing.toml");
  expect(loadProviderConfig({})).toEqual(ANTHROPIC_ONLY);
  expect(() => loadProviderConfig({ LIFEOS_INFERENCE_MODE: "local-only" })).toThrow(/not readable/);
});

test("marker overrides a config that now says something else; no local table → refuses", () => {
  writeFileSync(CFG, `[inference]\nmode = "local-with-fallback"\n[inference.local]\nbase_url = "http://x"\nmodel = "m"\n`);
  process.env.LIFEOS_CONFIG_PATH = CFG;
  expect(loadProviderConfig({ LIFEOS_INFERENCE_MODE: "local-only" }).mode).toBe("local-only");
  writeFileSync(CFG, `[inference]\nmode = "anthropic-only"\n`);
  expect(() => loadProviderConfig({ LIFEOS_INFERENCE_MODE: "local-only" })).toThrow(/no \[inference\.local\]/);
});

// ── env overlay ───────────────────────────────────────────────────────────────

test("local env points claude at the server, sets a credential, drops the API key", () => {
  const cfg = resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, token_env: "MY_TOK" } });
  const env = localEnv({ ANTHROPIC_API_KEY: "sk-x", MY_TOK: "secret", KEEP: "1" }, cfg);
  expect(env.ANTHROPIC_API_KEY).toBeUndefined();
  expect(env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:9");
  expect(env.ANTHROPIC_AUTH_TOKEN).toBe("secret");
  expect(env.ANTHROPIC_DEFAULT_HAIKU_MODEL).toBe("small-local");
  expect(env.ANTHROPIC_SMALL_FAST_MODEL).toBe("small-local");
  expect(env.KEEP).toBe("1");
  expect(env.LIFEOS_INFERENCE_MODE).toBeUndefined();
  expect(localEnv({}, resolveProviderConfig(LOCAL)).ANTHROPIC_AUTH_TOKEN).toBe("lifeos-local-no-auth");
});

test("local-only adds the marker and turns off nonessential traffic, WebFetch, claude.ai MCP", () => {
  const env = localEnv({}, resolveProviderConfig({ ...LOCAL, mode: "local-only" }));
  expect(env.LIFEOS_INFERENCE_MODE).toBe("local-only");
  expect(env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBe("1");
  expect(env.CLAUDE_CODE_DISABLE_WEB_FETCH).toBe("1");
  expect(env.ENABLE_CLAUDEAI_MCP_SERVERS).toBe("false");
});

test("local-only never stores the user's API key in the session env", () => {
  const env = localEnv({ ANTHROPIC_API_KEY: "sk-ant-x" }, resolveProviderConfig({ ...LOCAL, mode: "local-only" }));
  expect(env.ANTHROPIC_API_KEY).toBeUndefined();
  expect(env.LIFEOS_INFERENCE_SAVED).toBeUndefined();
  expect(JSON.stringify(env)).not.toContain("sk-ant-x");
  // …nor when the record was inherited from a local-with-fallback parent.
  const parent = localEnv({ ANTHROPIC_API_KEY: "sk-ant-x" }, resolveProviderConfig(LOCAL));
  expect(parent.LIFEOS_INFERENCE_SAVED).toContain("sk-ant-x"); // positive control
  const child = localEnv(parent, resolveProviderConfig({ ...LOCAL, mode: "local-only" }));
  expect(JSON.stringify(child)).not.toContain("sk-ant-x");
});

test("anthropicEnv strips exactly what localEnv added, and nothing when it added nothing", () => {
  const local = localEnv({ KEEP: "1" }, resolveProviderConfig(LOCAL));
  expect(anthropicEnv(local)).toEqual({ KEEP: "1" });
  const own = { ANTHROPIC_BASE_URL: "https://corp-proxy", KEEP: "1" };
  expect(anthropicEnv(own)).toEqual(own);
});

test("the user's own routing and privacy settings survive a local → Anthropic round trip", () => {
  const user = {
    ANTHROPIC_BASE_URL: "https://corp-proxy", ANTHROPIC_API_KEY: "sk-own",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", CLAUDE_CODE_USE_BEDROCK: "1", KEEP: "1",
  };
  const local = localEnv(user, resolveProviderConfig(LOCAL));
  expect(local.CLAUDE_CODE_USE_BEDROCK).toBeUndefined(); // would outrank the local server
  expect(local.ANTHROPIC_API_KEY).toBeUndefined();
  expect(local.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBe("1"); // opt-out kept on local too
  const nested = localEnv(local, resolveProviderConfig(LOCAL)); // a local child of a local session
  expect(anthropicEnv(nested)).toEqual(user);
});

test("envDiffShell round-trips through bash, including quotes", async () => {
  const before = { A: "1", GONE: "x" };
  const after = { A: "1", B: "it's \"q\" $HOME `x`" };
  const script = `${envDiffShell(before, after)}\nprintf '%s|%s' "\${GONE-unset}" "$B"`;
  const p = Bun.spawn([Bun.which("bash")!, "-c", script], { env: { GONE: "x" }, stdout: "pipe" });
  expect(await new Response(p.stdout).text()).toBe(`unset|it's "q" $HOME \`x\``);
});

// ── decide(): the gate's whole table ─────────────────────────────────────────────

const cfgOf = (mode: string) => () => resolveProviderConfig({ ...LOCAL, mode }) as ProviderConfig;
const up = async () => true, down = async () => false;

test.each([
  ["anthropic-only", undefined, up, "anthropic"],
  ["local-only", undefined, down, "local"],
  ["local-only", "local", down, "local"],
  ["local-only", "anthropic", up, "refuse"],
  ["local-with-fallback", undefined, up, "local"],
  ["local-with-fallback", undefined, down, "anthropic"],
  ["local-with-fallback", "local", down, "local"],
  ["local-with-fallback", "anthropic", up, "anthropic"],
  ["local-with-fallback", "bogus", up, "refuse"],
] as const)("decide %s hint=%s → %s", async (mode, hint, health, want) => {
  const d = await decide(hint ? { LIFEOS_INFERENCE_TARGET: hint } : {}, cfgOf(mode), health);
  const got = d.action === "refuse" ? "refuse" : d.env.ANTHROPIC_BASE_URL ? "local" : "anthropic";
  expect(got).toBe(want);
  if (d.action === "exec") expect(d.env.LIFEOS_INFERENCE_TARGET).toBeUndefined();
});

test.each(["update", "install", "setup-token", "login", "auth"])("decide: local-only refuses `claude %s`", async (sub) => {
  const d = await decide({}, cfgOf("local-only"), up, ["--verbose", sub]);
  expect(d.action).toBe("refuse");
});

test.each([
  [["--model", "x", "update"]],
  [["--model", "-p", "update"]],           // "-p" as a flag value must not exempt anything
  [["--append-system-prompt", "--print", "auth", "login"]],
  [["ultrareview"]],
  [["--cloud", "fix it"]],
  [["--environment=prod"]],
  [["--teleport"]],
  [["--remote-control"]],
])("decide: local-only refuses %j", async (argv) => {
  expect((await decide({}, cfgOf("local-only"), up, argv)).action).toBe("refuse");
});

test("decide: ordinary local-only runs still exec", async () => {
  expect((await decide({}, cfgOf("local-only"), up, ["-p", "fix the bug", "--model", "opus"])).action).toBe("exec");
  expect((await decide({}, cfgOf("local-only"), up, ["--resume"])).action).toBe("exec");
});

test("decide: local-only refuses when settings would re-route; fallback mode does not check", async () => {
  const hits = () => ["/p/.claude/settings.json: env.ANTHROPIC_BASE_URL"];
  expect((await decide({}, cfgOf("local-only"), up, [], hits)).action).toBe("refuse");
  expect((await decide({}, cfgOf("local-with-fallback"), up, [], hits)).action).toBe("exec");
});

test("decide: invalid config refuses", async () => {
  const d = await decide({}, () => { throw new Error("boom"); }, up);
  expect(d.action).toBe("refuse");
});

// ── the real gate script, end to end ─────────────────────────────────────────────

let server: ReturnType<typeof Bun.serve> | undefined;
let serverUp = true;
beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch: (req) =>
      serverUp && new URL(req.url).pathname === "/v1/models"
        ? Response.json({ data: [{ id: "big-local" }] })
        : new Response("down", { status: 503 }),
  });
});
afterAll(() => server?.stop(true));
const base = () => `http://127.0.0.1:${server!.port}`;

function config(mode: string | null) {
  writeFileSync(CFG, mode === null ? "" : `[inference]\nmode = "${mode}"\n[inference.local]\nbase_url = "${base()}"\nmodel = "big-local"\n`);
  process.env.LIFEOS_CONFIG_PATH = CFG;
}
async function claude(extraEnv: Record<string, string | undefined> = {}, cwd = HOME) {
  reset();
  const env = { ...process.env, ...extraEnv } as Record<string, string>;
  for (const [k, v] of Object.entries(extraEnv)) if (v === undefined) delete env[k];
  const p = Bun.spawn([GATE, "-p", "hi"], { env, cwd, stdout: "pipe", stderr: "pipe" });
  const code = await p.exited;
  return { code, stderr: await new Response(p.stderr).text(), spawns: spawns(), events: events() };
}

test("gate fixture: claude on PATH is the gate script (positive control)", () => {
  expect(readFileSync(GATE, "utf8")).toContain("inference gate");
});

test("gate: anthropic-only execs with no local variables", async () => {
  config(null);
  const r = await claude();
  expect(r.code).toBe(0);
  expect(r.spawns.length).toBe(1);
  expect(Object.keys(r.spawns[0].env).filter((k) => k.startsWith("ANTHROPIC_"))).toEqual([]);
});

test("gate: local-only + server down still goes local (fails, never fails over)", async () => {
  config("local-only");
  serverUp = false;
  const r = await claude();
  expect(r.spawns.length).toBe(1);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  expect(r.spawns[0].env.LIFEOS_INFERENCE_MODE).toBe("local-only");
});

test("gate: local-only refuses an explicit Anthropic request, real claude never runs", async () => {
  config("local-only");
  const r = await claude({ LIFEOS_INFERENCE_TARGET: "anthropic" });
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
  expect(r.events).toEqual(["refused"]);
});

test("gate: a child that scrubbed the local env (CarrierProbe-style) gets it back, OAuth-safe", async () => {
  config("local-only");
  const r = await claude({ ANTHROPIC_BASE_URL: undefined, ANTHROPIC_AUTH_TOKEN: undefined, LIFEOS_INFERENCE_MODE: "local-only" });
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  expect(r.spawns[0].env.ANTHROPIC_AUTH_TOKEN).toBe("lifeos-local-no-auth");
});

test("gate: local-only marker + unreadable config refuses", async () => {
  process.env.LIFEOS_CONFIG_PATH = join(HOME, "missing.toml");
  const r = await claude({ LIFEOS_INFERENCE_MODE: "local-only" });
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
});

test("gate: invalid config refuses", async () => {
  writeFileSync(CFG, `[inference]\nmdoe = "local-only"\n`);
  process.env.LIFEOS_CONFIG_PATH = CFG;
  const r = await claude();
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
});

test("gate: fallback mode follows server health, with a notice and an event when down", async () => {
  config("local-with-fallback");
  serverUp = true;
  const upRun = await claude();
  expect(upRun.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  serverUp = false;
  const downRun = await claude();
  expect(downRun.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined();
  expect(downRun.stderr).toMatch(/fallback/);
  expect(downRun.events).toEqual(["fallback"]);
});

test("gate: a .env in the cwd does not reach the decision", async () => {
  config("local-only");
  const dir = join(HOME, "proj");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, ".env"), "LIFEOS_INFERENCE_TARGET=anthropic\n");
  const r = await claude({}, dir);
  expect(r.code).toBe(0);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: LIFEOS_GATE=off is a plain exec", async () => {
  config("local-only");
  const r = await claude({ LIFEOS_GATE: "off" });
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined();
});

test("gate: LIFEOS_GATE=off inside a local-only session refuses", async () => {
  config("local-only");
  const r = await claude({ LIFEOS_GATE: "off", LIFEOS_INFERENCE_MODE: "local-only" });
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
});

test("gate: a project bunfig.toml preload never runs inside the decision", async () => {
  config("local-only");
  const dir = join(HOME, "evil");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "bunfig.toml"), 'preload = ["./pre.ts"]\n');
  writeFileSync(join(dir, "pre.ts"),
    'import { writeSync } from "node:fs"; writeSync(2, "PRELOAD-RAN\\n"); try { writeSync(3, "export ANTHROPIC_BASE_URL=https://api.anthropic.com\\n"); } catch {}\n');
  const r = await claude({}, dir);
  expect(r.stderr).not.toContain("PRELOAD-RAN");
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: project settings that re-route claude refuse under local-only", async () => {
  config("local-only");
  const dir = join(HOME, "proj-settings");
  mkdirSync(join(dir, ".claude"), { recursive: true });
  writeFileSync(join(dir, ".claude", "settings.json"), JSON.stringify({ env: { ANTHROPIC_BASE_URL: "https://api.anthropic.com" } }));
  const r = await claude({}, dir);
  expect(r.code).toBe(3);
  expect(r.stderr).toMatch(/re-route/);
  expect(r.spawns.length).toBe(0);
});

test("gate: `claude update` refuses under local-only", async () => {
  config("local-only");
  reset();
  const p = Bun.spawn([GATE, "update"], { env: process.env as any, stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(3);
  expect(spawns().length).toBe(0);
});

test("gate: a stale payload whose gate does not speak the protocol refuses", async () => {
  config("local-only");
  const stale = join(HOME, "stale-lifeos");
  mkdirSync(join(stale, "LIFEOS/TOOLS"), { recursive: true });
  writeFileSync(join(stale, "LIFEOS/TOOLS/InferenceProvider.ts"), 'console.log(JSON.stringify({ mode: "local-only" }));\n');
  const r = await claude({ CLAUDE_CONFIG_DIR: stale });
  expect(r.code).toBe(3);
  expect(r.stderr).toMatch(/no decision/);
  expect(r.spawns.length).toBe(0);
});

test("gate: a down server is probed once per cache window, not once per exec", async () => {
  config("local-with-fallback");
  const runtime = join(HOME, "runtime");
  mkdirSync(runtime, { recursive: true });
  serverUp = false;
  await claude({ XDG_RUNTIME_DIR: runtime });
  serverUp = true;
  const cached = await claude({ XDG_RUNTIME_DIR: runtime });
  expect(cached.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined(); // still the cached "down"
  const fresh = await claude({ XDG_RUNTIME_DIR: undefined });
  expect(fresh.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: works with a PATH that has no getent (Pulse's unit PATH)", async () => {
  config("local-only");
  const path = [GATE.replace(/\/claude$/, ""), Bun.which("bun")!.replace(/\/bun$/, "")].join(":");
  const r = await claude({ PATH: path });
  expect(r.code).toBe(0);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: an env delta that fails to apply refuses (readonly var via BASH_ENV)", async () => {
  config("local-only");
  const rc = join(HOME, "ro.sh");
  writeFileSync(rc, "readonly ANTHROPIC_BASE_URL=https://api.anthropic.com\n");
  const r = await claude({ BASH_ENV: rc });
  expect(r.code).toBe(3);
  expect(r.stderr).toMatch(/did not apply/);
  expect(r.spawns.length).toBe(0);
});

test("gate: missing gate file + local-only marker refuses", async () => {
  const r = await claude({ CLAUDE_CONFIG_DIR: join(HOME, "no-lifeos"), LIFEOS_INFERENCE_MODE: "local-only" });
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
});

// ── Inference.ts end to end, through the gate ─────────────────────────────────────

async function infer(level = "low") {
  reset();
  const { inference } = await import("./Inference");
  return inference({ systemPrompt: "s", userPrompt: "u", level: level as any, timeout: 15_000 });
}

test("inference, local healthy: answers locally, no false downgrade", async () => {
  config("local-with-fallback");
  process.env.FAKE_LOCAL_FAIL = "0";
  const r = await infer();
  expect(r.provider).toBe("local");
  expect(r.executedModel).toBe("big-local");
  expect(r.modelDowngraded).toBe(false);
  expect(spawns().length).toBe(1);
});

test("inference, local fails: one Anthropic retry with every local variable stripped", async () => {
  config("local-with-fallback");
  process.env.FAKE_LOCAL_FAIL = "1";
  // Simulate running inside a local interactive session: inherited local variables.
  const inherited = localEnv({}, resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, base_url: base() } }));
  Object.assign(process.env, inherited);
  try {
    const r = await infer();
    const s = spawns();
    expect(r.success).toBe(true);
    expect(r.provider).toBe("anthropic");
    expect(s.length).toBe(2);
    expect(s[0].env.ANTHROPIC_BASE_URL).toBe(base());
    expect(Object.keys(s[1].env).filter((k) => k.startsWith("ANTHROPIC_"))).toEqual([]);
    expect(s[1].model).toBe("haiku");
  } finally {
    for (const k of Object.keys(inherited)) delete process.env[k];
  }
});

test("inference, local-only fails: error, Anthropic never spawned", async () => {
  config("local-only");
  process.env.FAKE_LOCAL_FAIL = "1";
  const r = await infer("max");
  expect(r.success).toBe(false);
  expect(spawns().every((x) => x.env.ANTHROPIC_BASE_URL === base())).toBe(true);
});

test("inference, invalid config: error, zero spawns", async () => {
  writeFileSync(CFG, `[inference]\nmode = "lokal-only"\n`);
  process.env.LIFEOS_CONFIG_PATH = CFG;
  const r = await infer();
  expect(r.success).toBe(false);
  expect(r.error).toMatch(/provider config invalid/);
  expect(spawns().length).toBe(0);
});
