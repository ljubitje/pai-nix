import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  ANTHROPIC_ONLY, anthropicEnv, decide, envDiffShell, localEnv, localModelFor,
  loadProviderConfig, parseConf, resolveProviderConfig, tierOf, type ProviderConfig,
} from "./InferenceProvider";

// Runs inside a materialised payload (see run.sh). HOME/.claude IS that payload. The gate's
// passwd lookup is a fake getent that reports $FAKE_PW_HOME (default: HOME), so no test can
// reach the real home of whoever runs the suite. PATH starts with the REAL lifeos-nix gate
// script whose `real` binary is a fake claude that records every exec in $SPAWNS_FILE.
const HOME = process.env.HOME!;
const SPAWNS = process.env.SPAWNS_FILE!;
const EVENTS = join(HOME, ".claude/LIFEOS/MEMORY/OBSERVABILITY/inference-provider.jsonl");
const CONF_REL = ".claude/LIFEOS/USER/CONFIG/inference.conf";
const CONF = join(HOME, CONF_REL);
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

// ── inference.conf: one strict line format, read the same way by shell and TS ─────────

test("no settings, or only comments, is anthropic-only", () => {
  expect(parseConf("")).toEqual(ANTHROPIC_ONLY);
  expect(parseConf("# nothing here\n\n   \n")).toEqual(ANTHROPIC_ONLY);
});

test("a full local config parses, CRLF and comments allowed", () => {
  const c = parseConf("# iskre\r\nmode=local-only\r\nbase_url=http://127.0.0.1:9/\nmodel=big\nmodel_haiku=small\ntoken_env=ISKRA_TOKEN\n");
  expect(c.mode).toBe("local-only");
  expect(c.local!.baseUrl).toBe("http://127.0.0.1:9");
  expect(c.local!.models).toEqual({ fable: "big", opus: "big", sonnet: "big", haiku: "small" });
  expect(c.local!.tokenEnv).toBe("ISKRA_TOKEN");
});

test("explicit anthropic-only does not judge the local settings it will not use", () => {
  expect(parseConf("mode=anthropic-only\nbase_url=https://api.anthropic.com\n")).toEqual(ANTHROPIC_ONLY);
});

test("no mode + base_url defaults to local-with-fallback", () => {
  expect(parseConf("base_url=http://x\nmodel=m\n").mode).toBe("local-with-fallback");
});

test.each([
  ["mode = local-only\n", /key=value/],                      // spaces
  ['mode="local-only"\n', /mode=/],                          // quotes become part of the value
  ["mdoe=local-only\n", /unknown key "mdoe"/],
  ["mode=local-only\nmode=anthropic-only\n", /given twice/],
  ['[inference]\nmode = "local-only"\n', /key=value/],       // TOML is not this format
  ["mode=local-only\n", /needs base_url= and model=/],
  ["mode=local-only\nbase_url=http://x\nmodel=m\ntoken_env=ANTHROPIC_AUTH_TOKEN\n", /ANTHROPIC_/],
  ["mode=anthropic-\0only\n", /key=value/],                // NUL becomes a space, like the wrapper
  ["mode=anthropic-only\nfoo=1\n", /unknown key "foo"/],
])("invalid inference.conf refuses loudly: %j", (text, msg) => {
  expect(() => parseConf(text, "/x/inference.conf")).toThrow(msg);
});

test.each([
  [{ mode: "local-only", local: { base_url: "ftp://x", model: "m" } }, /base_url/],
  [{ mode: "local-only", local: { base_url: "http://x" } }, /no model for tier/],
  [{ mode: "local-only", local: { base_url: "http://x@api.anthropic.com", model: "m" } }, /plain http/],
  [{ mode: "local-only", local: { base_url: "https://api.anthropic.com", model: "m" } }, /points at Anthropic/],
  [{ mode: "local-only", local: { base_url: "https://foo.claude.ai/v1", model: "m" } }, /points at Anthropic/],
  [{ mode: "local-only", local: { base_url: "https://api.anthropic.com./", model: "m" } }, /points at Anthropic/],
])("invalid local settings refuse: %j", (raw, msg) => {
  expect(() => resolveProviderConfig(raw, "/x/inference.conf")).toThrow(msg);
});

test("aliases and pinned ids map to their tier's local model", () => {
  const { local } = resolveProviderConfig(LOCAL);
  expect(tierOf("claude-fable-5")).toBe("fable");
  expect(localModelFor(local!, "haiku")).toBe("small-local");
  expect(localModelFor(local!, "claude-opus-5")).toBe("big-local");
});

test("loadProviderConfig: absent → anthropic-only; unreadable or a directory → throws", () => {
  const dir = join(HOME, "loadtest");
  mkdirSync(dir, { recursive: true });
  expect(loadProviderConfig(join(dir, "missing.conf"))).toEqual(ANTHROPIC_ONLY);
  const f = join(dir, "locked.conf");
  writeFileSync(f, "mode=anthropic-only\n");
  chmodSync(f, 0o000);
  expect(() => loadProviderConfig(f)).toThrow(/cannot read/);
  chmodSync(f, 0o600);
  expect(() => loadProviderConfig(dir)).toThrow(/cannot read/);
});

// ── env overlay ───────────────────────────────────────────────────────────────

test("local env points claude at the server, sets a credential, drops the API key", () => {
  const cfg = resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, token_env: "MY_TOK" } });
  const env = localEnv({ ANTHROPIC_API_KEY: "sk-x", MY_TOK: "secret", KEEP: "1", CLAUDE_CODE_USE_BEDROCK: "1" }, cfg);
  expect(env.ANTHROPIC_API_KEY).toBeUndefined();
  expect(env.CLAUDE_CODE_USE_BEDROCK).toBeUndefined(); // would outrank the local server
  expect(env.ANTHROPIC_BASE_URL).toBe("http://127.0.0.1:9");
  expect(env.ANTHROPIC_AUTH_TOKEN).toBe("secret");
  expect(env.ANTHROPIC_DEFAULT_HAIKU_MODEL).toBe("small-local");
  expect(env.KEEP).toBe("1");
  expect(env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBeUndefined(); // only under local-only
  expect(localEnv({}, resolveProviderConfig(LOCAL)).ANTHROPIC_AUTH_TOKEN).toBe("lifeos-local-no-auth");
});

test("local-only adds the static privacy switches", () => {
  const env = localEnv({}, resolveProviderConfig({ ...LOCAL, mode: "local-only" }));
  expect(env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC).toBe("1");
  expect(env.CLAUDE_CODE_DISABLE_WEB_FETCH).toBe("1");
  expect(env.ENABLE_CLAUDEAI_MCP_SERVERS).toBe("false");
});

test("anthropicEnv strips what localEnv set, restores no credential, keeps the user's own switches", () => {
  const user = { KEEP: "1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", ANTHROPIC_API_KEY: "sk-own" };
  expect(anthropicEnv(localEnv(user, resolveProviderConfig(LOCAL))))
    .toEqual({ KEEP: "1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" });
  const own = { ANTHROPIC_BASE_URL: "https://corp-proxy", KEEP: "1" };
  expect(anthropicEnv(own)).toEqual(own); // localEnv never ran: untouched
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

test("decide: a token_env naming an unset variable refuses (a typo is not 'server down')", async () => {
  const cfg = () => resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, token_env: "ISKRA_TOKN" } });
  const d = await decide({}, cfg, up);
  expect(d.action).toBe("refuse");
  if (d.action === "refuse") expect(d.reason).toMatch(/ISKRA_TOKN/);
  expect((await decide({ ISKRA_TOKN: "x" }, cfg, up)).action).toBe("exec");
  // The explicit Anthropic leg of a fallback does not need the local token.
  expect((await decide({ LIFEOS_INFERENCE_TARGET: "anthropic" }, cfg, up)).action).toBe("exec");
});

test("decide: invalid config refuses", async () => {
  const d = await decide({}, () => { throw new Error("boom"); }, up);
  expect(d.action).toBe("refuse");
});

// ── the real gate script, end to end ─────────────────────────────────────────────

let server: ReturnType<typeof Bun.serve> | undefined;
let port = 0;
let modelsStatus = 200;   // what an "up" server answers on /v1/models
const serve = () => Bun.serve({
  port,
  fetch: (req) =>
    new URL(req.url).pathname === "/v1/models"
      ? (modelsStatus === 200 ? Response.json({ data: [{ id: "big-local" }] }) : new Response("", { status: modelsStatus }))
      : new Response("nope", { status: 404 }),
});
beforeAll(() => { server = serve(); port = server.port; });
afterAll(() => server?.stop(true));
/** Up = something answers HTTP on the port; down = nothing listens there (connection refused). */
async function setUp(up: boolean) {
  if (up && !server) server = serve();
  if (!up && server) { server.stop(true); server = undefined; }
}
const base = () => `http://127.0.0.1:${port}`;
const localConf = (mode: string | null) =>
  `${mode ? `mode=${mode}\n` : ""}base_url=${base()}\nmodel=big-local\n`;

/** Write inference.conf under `home` (default: the main sandbox home); null removes it. */
function conf(text: string | null, home = HOME) {
  const f = join(home, CONF_REL);
  mkdirSync(join(home, ".claude/LIFEOS/USER/CONFIG"), { recursive: true });
  try { chmodSync(f, 0o600); } catch { /* absent */ }
  rmSync(f, { force: true, recursive: true });
  if (text !== null) writeFileSync(f, text);
}
async function claude(extraEnv: Record<string, string | undefined> = {}, cwd = HOME, bin = GATE, args = ["-p", "hi"]) {
  reset();
  const env = { ...process.env, ...extraEnv } as Record<string, string>;
  for (const [k, v] of Object.entries(extraEnv)) if (v === undefined) delete env[k];
  const p = Bun.spawn([bin, ...args], { env, cwd, stdout: "pipe", stderr: "pipe" });
  const code = await p.exited;
  return { code, stderr: await new Response(p.stderr).text(), spawns: spawns(), events: events() };
}
/** A separate passwd home: own conf, and a gate file or none. */
function otherHome(name: string, gateSource: string | null) {
  const h = join(HOME, name);
  mkdirSync(join(h, ".claude/LIFEOS/TOOLS"), { recursive: true });
  const g = join(h, ".claude/LIFEOS/TOOLS/InferenceProvider.ts");
  rmSync(g, { force: true });
  if (gateSource !== null) writeFileSync(g, gateSource);
  return h;
}

test("gate fixture: claude on PATH is the gate script, and passwd is the sandbox fake", () => {
  const src = readFileSync(GATE, "utf8");
  expect(src).toContain("inference gate");
  expect(src).not.toContain("/run/current-system/sw/bin/getent");
});

test("gate: no inference.conf → plain claude, the gate never runs", async () => {
  const h = otherHome("crashing-gate", "process.exit(9);\n"); // would refuse if it ran
  conf(null, h);
  const r = await claude({ FAKE_PW_HOME: h });
  expect(r.code).toBe(0);
  expect(r.spawns.length).toBe(1);
  expect(Object.keys(r.spawns[0].env).filter((k) => k.startsWith("ANTHROPIC_"))).toEqual([]);
});

test("gate: mode=anthropic-only → plain claude without running the gate", async () => {
  const h = otherHome("crashing-gate", "process.exit(9);\n");
  conf("mode=anthropic-only\n", h);
  const r = await claude({ FAKE_PW_HOME: h });
  expect(r.code).toBe(0);
  expect(r.spawns.length).toBe(1);
});

test("gate: anthropic-only with an inherited local env goes through the gate and is stripped", async () => {
  conf("mode=anthropic-only\n");
  const inherited = localEnv({}, resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, base_url: base() } }));
  const r = await claude(inherited);
  expect(r.code).toBe(0);
  expect(Object.keys(r.spawns[0].env).filter((k) => k.startsWith("ANTHROPIC_"))).toEqual([]);
});

test("gate: local-only + server down still goes local (fails, never fails over)", async () => {
  conf(localConf("local-only"));
  await setUp(false);
  const r = await claude();
  await setUp(true);
  expect(r.spawns.length).toBe(1);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: local-only refuses an explicit Anthropic request, real claude never runs", async () => {
  conf(localConf("local-only"));
  const r = await claude({ LIFEOS_INFERENCE_TARGET: "anthropic" });
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
  expect(r.events).toEqual(["refused"]);
});

test("gate: a child that scrubbed the local env (CarrierProbe-style) gets it back, OAuth-safe", async () => {
  conf(localConf("local-only"));
  const r = await claude({ ANTHROPIC_BASE_URL: undefined, ANTHROPIC_AUTH_TOKEN: undefined });
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  expect(r.spawns[0].env.ANTHROPIC_AUTH_TOKEN).toBe("lifeos-local-no-auth");
});

test("gate: env cannot move the decision — $HOME, LIFEOS_INFERENCE_CONF, CLAUDE_CONFIG_DIR", async () => {
  conf(localConf("local-only"));
  const elsewhere = join(HOME, "elsewhere");
  mkdirSync(elsewhere, { recursive: true });
  const r = await claude({ HOME: elsewhere, LIFEOS_INFERENCE_CONF: join(elsewhere, "none.conf"), CLAUDE_CONFIG_DIR: elsewhere });
  expect(r.code).toBe(0);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base()); // passwd home's local-only still wins
});

test.each([
  ["mode = local-only\n"],
  ['mode="local-only"\n'],
  ["mode=local-only\nmode=anthropic-only\n"],
  ["mdoe=local-only\n"],
  ['base_url = """http://x"""\n'],
  ["mode=anthropic-only\nmode = local-only\n"],   // the fast path must not skip the line rule
])("gate: an invalid inference.conf refuses, real claude never runs: %j", async (text) => {
  conf(text);
  const r = await claude();
  expect(r.code).toBe(3);
  expect(r.spawns.length).toBe(0);
});

test("gate: an unreadable inference.conf, or a directory in its place, refuses", async () => {
  conf("mode=anthropic-only\n");
  chmodSync(CONF, 0o000);
  const locked = await claude();
  chmodSync(CONF, 0o600);
  expect(locked.code).toBe(3);
  expect(locked.spawns.length).toBe(0);
  conf(null);
  mkdirSync(CONF);
  const dir = await claude();
  expect(dir.code).toBe(3);
  conf(null);
});

test("gate: a link to nothing anywhere on the conf path refuses; a missing .claude is plain claude", async () => {
  const { symlinkSync } = await import("node:fs");
  const h1 = otherHome("dangling-conf", null);
  conf(null, h1);
  symlinkSync(join(h1, "not-mounted/inference.conf"), join(h1, CONF_REL));
  expect((await claude({ FAKE_PW_HOME: h1 })).code).toBe(3);
  const h2 = join(HOME, "dangling-claude");
  mkdirSync(h2, { recursive: true });
  rmSync(join(h2, ".claude"), { force: true });
  symlinkSync(join(h2, "persist/.claude"), join(h2, ".claude"));
  expect((await claude({ FAKE_PW_HOME: h2 })).code).toBe(3);
  const h3 = join(HOME, "no-claude-at-all");
  mkdirSync(h3, { recursive: true });
  const plain = await claude({ FAKE_PW_HOME: h3 });
  expect(plain.code).toBe(0);
  expect(plain.spawns.length).toBe(1);
});

test("gate: a CLAUDE_CONFIG_DIR whose inference.conf says another mode refuses; the same mode, the same tree or none is fine", async () => {
  conf("mode=anthropic-only\n");
  const other = join(HOME, "second-lifeos");
  mkdirSync(join(other, "LIFEOS/USER/CONFIG"), { recursive: true });
  writeFileSync(join(other, "LIFEOS/USER/CONFIG/inference.conf"), localConf("local-only"));
  expect((await claude({ CLAUDE_CONFIG_DIR: other })).code).toBe(3);
  writeFileSync(join(other, "LIFEOS/USER/CONFIG/inference.conf"), "mode=anthropic-only\n");
  expect((await claude({ CLAUDE_CONFIG_DIR: other })).code).toBe(0);   // two anthropic-only installs
  expect((await claude({ CLAUDE_CONFIG_DIR: join(HOME, ".claude") })).code).toBe(0);
  expect((await claude({ CLAUDE_CONFIG_DIR: join(HOME, "empty-cfgdir") })).code).toBe(0);
});

test("gate: fallback mode follows server health, with a notice and an event when down", async () => {
  conf(localConf("local-with-fallback"));
  await setUp(true);
  const upRun = await claude();
  expect(upRun.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  await setUp(false);
  const downRun = await claude();
  await setUp(true);
  expect(downRun.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined();
  expect(downRun.stderr).toMatch(/fallback/);
  expect(downRun.events).toEqual(["fallback"]);
});

test("gate: a server that answers /v1/models with 404 or 401 is up (the contract is /v1/messages)", async () => {
  conf(localConf("local-with-fallback"));
  for (const status of [404, 401]) {
    modelsStatus = status;
    const r = await claude();
    expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
  }
  modelsStatus = 200;
});

test("gate: a down server is probed once per cache window, not once per exec", async () => {
  conf(localConf("local-with-fallback"));
  const runtime = join(HOME, "runtime");
  mkdirSync(runtime, { recursive: true });
  await setUp(false);
  await claude({ XDG_RUNTIME_DIR: runtime });
  await setUp(true);
  const cached = await claude({ XDG_RUNTIME_DIR: runtime });
  expect(cached.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined(); // still the cached "down"
  const fresh = await claude({ XDG_RUNTIME_DIR: undefined });
  expect(fresh.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: a project bunfig.toml preload never runs inside the decision", async () => {
  conf(localConf("local-only"));
  const dir = join(HOME, "evil");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "bunfig.toml"), 'preload = ["./pre.ts"]\n');
  writeFileSync(join(dir, "pre.ts"),
    'import { writeSync } from "node:fs"; writeSync(2, "PRELOAD-RAN\\n"); try { writeSync(3, "export ANTHROPIC_BASE_URL=https://api.anthropic.com\\n"); } catch {}\n');
  const r = await claude({}, dir);
  expect(r.stderr).not.toContain("PRELOAD-RAN");
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

test("gate: an env delta that fails to apply refuses (readonly var via BASH_ENV)", async () => {
  conf(localConf("local-only"));
  const rc = join(HOME, "ro.sh");
  writeFileSync(rc, "readonly ANTHROPIC_BASE_URL=https://api.anthropic.com\n");
  const r = await claude({ BASH_ENV: rc });
  expect(r.code).toBe(3);
  expect(r.stderr).toMatch(/did not apply/);
  expect(r.spawns.length).toBe(0);
});

test("gate: a stale payload whose gate does not speak the protocol refuses", async () => {
  const h = otherHome("stale", 'console.log(JSON.stringify({ mode: "local-only" }));\n');
  conf(localConf("local-only"), h);
  const r = await claude({ FAKE_PW_HOME: h });
  expect(r.code).toBe(3);
  expect(r.stderr).toMatch(/no decision/);
  expect(r.spawns.length).toBe(0);
});

test("gate: a local mode with no gate file refuses", async () => {
  const h = otherHome("nogate", null);
  for (const text of [localConf("local-only"), localConf("local-with-fallback"), localConf(null)]) {
    conf(text, h);
    const r = await claude({ FAKE_PW_HOME: h });
    expect(r.code).toBe(3);
    expect(r.spawns.length).toBe(0);
  }
});

test("gate: LIFEOS_GATE=off — plain claude except where the conf may say local-only", async () => {
  const cases: [string | null, number][] = [
    [null, 0], ["mode=anthropic-only\n", 0], [localConf("local-with-fallback"), 0],
    [localConf("local-only"), 3], [localConf(null), 3],
  ];
  for (const [text, code] of cases) {
    conf(text);
    const r = await claude({ LIFEOS_GATE: "off" });
    expect(r.code).toBe(code);
    expect(r.spawns.length).toBe(code === 0 ? 1 : 0);
    if (code === 0) expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBeUndefined();
  }
});

// The wrapper and parseConf must agree on every file, byte for byte: same verdict, same mode,
// and the text the wrapper hands on (to the gate and to Inference.ts) parses to the same thing.
const AGREE: string[] = [
  "mode=anthropic-only\r\n",
  "# only a comment\r\n\n",
  "mode=anthropic-only\nbase_url=https://api.anthropic.com\n",
  "mode=anthropic-only\nfoo=1\n",
  "mode=anthropic-only\nmode=anthropic-only\n",
  "mode=anthropic-only\nbase_url=http://a\nbase_url=http://b\n",
  "mode=anthropic-\0only\n",
  "#\rcomment\nmode=anthropic-only\n",
  "mode=anthropic-only\nmodel=a\rb\n",
  "mode=anthropic-only\n# note \u2028 x\n",
  "mode=anthropic-only\nbase_url=http://x\u00a0y\n",
  "\u00a0\nmode=anthropic-only\n",
  "\ufeffmode=anthropic-only\n",
  "base_url=http://x\nmodel=m\n",
  "mode=local-only\n",
  "mode = local-only\n",
  "mode=local-only\nbase_url=http://x\nmodel=m\n",
];
test.each(AGREE.map((t) => [t]))("wrapper and parseConf agree on %j", async (text) => {
  conf(text);
  reset();
  const q = Bun.spawnSync([GATE, "--lifeos-gate-query"], { env: process.env as any });
  const verdict = (f: () => ProviderConfig) => { try { return f().mode; } catch { return "refuse"; } };
  const direct = verdict(() => parseConf(text));
  const out = q.stdout.toString();
  if (q.exitCode === 3) {
    expect(direct).toBe("refuse");
  } else {
    expect(q.exitCode).toBe(0);
    const shellMode = out.match(/^mode=(.*)$/m)![1];
    const handedOn = verdict(() => parseConf(out.slice(out.indexOf("\n---\n") + 5)));
    expect(handedOn).toBe(direct);                           // the text passed on reads the same
    if (shellMode === "anthropic-only") expect(direct).toBe("anthropic-only");
    else {
      expect(direct).not.toBe("anthropic-only");             // the gate would then parse it
      if (shellMode && direct !== "refuse") expect(direct).toBe(shellMode);
    }
  }
  expect(spawns().length).toBe(0); // a query never reaches the real binary
  conf(null);
});

test("gate: the gate refuses when its parse disagrees with the wrapper's mode (no second read)", async () => {
  const p = Bun.spawn(["bun", "--no-env-file", join(import.meta.dir, "InferenceProvider.ts"), "gate", "--conf", "x", "--mode", "local-only"],
    { stdin: new Blob(["mode=anthropic-only\n"]), stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(3);
  expect(await new Response(p.stderr).text()).toMatch(/wrapper read mode=local-only/);
});

test("gate: a CRLF or comment-only file is plain claude, as on upstream", async () => {
  for (const text of ["mode=anthropic-only\r\n", "# nothing\r\n"]) {
    const h = otherHome("crashing-gate", "process.exit(9);\n");
    conf(text, h);
    const r = await claude({ FAKE_PW_HOME: h });
    expect(r.code).toBe(0);
    expect(r.spawns.length).toBe(1);
  }
});

test("gate: an exported SHELLOPTS (errexit, xtrace) neither breaks the wrapper nor prints the token", async () => {
  conf(`mode=local-only\nbase_url=${base()}\nmodel=big-local\ntoken_env=SECRET_TOK\n`);
  const r = await claude({ SHELLOPTS: "errexit:xtrace", SECRET_TOK: "tok-123" });
  expect(r.code).toBe(0);
  expect(r.spawns[0].env.ANTHROPIC_AUTH_TOKEN).toBe("tok-123");
  expect(r.stderr).not.toContain("tok-123");
  conf(null);
  const plain = await claude({ SHELLOPTS: "errexit" });
  expect(plain.code).toBe(0);
});

test("gate: a uid passwd cannot resolve falls back to $HOME, still gated", async () => {
  conf(localConf("local-only"));
  const r = await claude({}, HOME, process.env.NOPW_GATE!);
  expect(r.code).toBe(0);
  expect(r.spawns[0].env.ANTHROPIC_BASE_URL).toBe(base());
});

// ── Inference.ts end to end, through the gate ─────────────────────────────────────

async function infer(level = "low", extra: Record<string, unknown> = {}) {
  reset();
  const { inference } = await import("./Inference");
  return inference({ systemPrompt: "s", userPrompt: "u", level: level as any, timeout: 15_000, ...extra });
}

test("inference, local healthy: answers locally, no false downgrade", async () => {
  conf(localConf("local-with-fallback"));
  process.env.FAKE_LOCAL_FAIL = "0";
  const r = await infer();
  expect(r.provider).toBe("local");
  expect(r.executedModel).toBe("big-local");
  expect(r.modelDowngraded).toBe(false);
  expect(spawns().length).toBe(1);
});

test("inference, local fails: one Anthropic retry, every local variable and credential gone", async () => {
  conf(localConf("local-with-fallback"));
  process.env.FAKE_LOCAL_FAIL = "1";
  // Simulate running inside a local interactive session: inherited local variables.
  const inherited = localEnv({ ANTHROPIC_API_KEY: "sk-ant-own", ANTHROPIC_BASE_URL: "https://corp-proxy" },
    resolveProviderConfig({ ...LOCAL, local: { ...LOCAL.local, base_url: base() } }));
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

test("inference: the Anthropic leg of a fallback honours fallbackTimeoutMs", async () => {
  conf(localConf("local-with-fallback"));
  process.env.FAKE_LOCAL_FAIL = "1";
  process.env.FAKE_ANTHROPIC_SLEEP_MS = "3000";
  try {
    const t0 = Date.now();
    const r = await infer("low", { fallbackTimeoutMs: 400 });
    expect(r.success).toBe(false);
    expect(r.error).toMatch(/Timeout after 400ms/);
    expect(Date.now() - t0).toBeLessThan(2500);
  } finally {
    delete process.env.FAKE_ANTHROPIC_SLEEP_MS;
  }
});

test("inference, local-only fails: error, and every spawn went local", async () => {
  conf(localConf("local-only"));
  process.env.FAKE_LOCAL_FAIL = "1";
  const r = await infer("max");
  const s = spawns();
  expect(r.success).toBe(false);
  expect(s.length).toBeGreaterThan(0);
  expect(s.every((x) => x.env.ANTHROPIC_BASE_URL === base())).toBe(true);
});

test("inference reads the mode through the wrapper, so $HOME cannot move it", async () => {
  conf(localConf("local-with-fallback"));
  process.env.FAKE_LOCAL_FAIL = "0";
  const saved = process.env.HOME;
  process.env.HOME = join(saved!, "elsewhere");
  try {
    const r = await infer();
    expect(r.provider).toBe("local");
  } finally {
    process.env.HOME = saved;
  }
});

test("inference: a claude that cannot answer the gate query is recorded, not silently trusted", async () => {
  conf(localConf("local-only"));
  reset();
  // A separate process (Bun.which fixes PATH at start) whose only claude is the ungated fake:
  // `--lifeos-gate-query` then gets no protocol answer.
  const p = Bun.spawn(["bun", "-e",
    'const { inference } = await import("./Inference"); await inference({ systemPrompt: "s", userPrompt: "u", level: "low", timeout: 10000 });'],
    { cwd: import.meta.dir, stdout: "pipe", stderr: "pipe",
      env: { ...process.env, FAKE_LOCAL_FAIL: "0", PATH: [process.env.FAKE_REAL_DIR!, Bun.which("bun")!.replace(/\/bun$/, "")].join(":") } as any });
  await p.exited;
  expect(events()).toContain("query-failed");
  expect(await new Response(p.stderr).text()).toMatch(/gave no answer/);
});

test("inference: a token_env naming an unset variable is an error, not a fallback", async () => {
  conf(`mode=local-with-fallback\nbase_url=${base()}\nmodel=big-local\ntoken_env=ISKRA_TOKN\n`);
  const r = await infer();
  expect(r.success).toBe(false);
  expect(r.error).toMatch(/ISKRA_TOKN/);
  expect(spawns().length).toBe(0);
});

test("inference, invalid config: error, zero spawns", async () => {
  conf("mode=lokal-only\n");
  const r = await infer();
  expect(r.success).toBe(false);
  expect(r.error).toMatch(/provider config invalid/);
  expect(spawns().length).toBe(0);
});
