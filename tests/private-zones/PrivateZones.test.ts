import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync, readFileSync as rf } from "node:fs";
import { tmpdir } from "node:os";
import { join as pj } from "node:path";
import {
  assertCoarseAggregate, assertQuotable, bucketLabel, classify, isCountable, isQuotable,
  loadRegister, matchesRule, PRIVATE_BUCKET, PROJECTS_DIR, REGISTER_PATH, safeExcerpt,
  splitBySensitivity, unregistered, type Register,
} from "./PrivateZones";
import { check as guard } from "../../hooks/PrivateZoneEgressGuard.hook";

const VALID: Register = {
  state: "valid",
  private: [{ match: "proj-vault", why: "example zone" }, { match: "/vault/" }],
  public: [{ match: "proj-work" }],
  narratedExempt: [{ match: "/HANDOFF.md" }],
};
const read = (file_path: string, cwd?: string, reg: Register = VALID) =>
  guard({ tool_name: "Read", cwd, tool_input: { file_path } }, reg);
const ABSENT: Register = { state: "absent", private: [], public: [], narratedExempt: [] };
const BROKEN: Register = { state: "broken", private: [], public: [], narratedExempt: [] };

// PRECEDENCE fixture: a name matching a private AND a longer public rule.
const MIXED = `${PROJECTS_DIR}/proj-work-proj-vault/a.jsonl`;
// The zone proper, used everywhere the cwd allowance is under test.
const ZONE = `${PROJECTS_DIR}/proj-vault`;
const PRIV = `${ZONE}/a.jsonl`;
const PUB = `${PROJECTS_DIR}/proj-work/a.jsonl`;
const NEW = `${PROJECTS_DIR}/proj-brand-new/a.jsonl`;
const NARRATED = `${ZONE}/HANDOFF.md`;
const ROOT = PROJECTS_DIR.slice(0, PROJECTS_DIR.lastIndexOf("/"));

// ── library: classification ────────────────────────────────────────────────────
test("private wins unconditionally, even against a longer public rule", () => {
  expect(classify(MIXED, VALID)).toBe("private");       // private beats a longer public rule
  expect(classify(PRIV, VALID)).toBe("private");
  expect(classify(PUB, VALID)).toBe("public");          // positive control
  expect(classify(NEW, VALID)).toBe("unregistered");
});

test("register state drives the default: absent is OFF, broken fails CLOSED", () => {
  expect(classify(PUB, ABSENT)).toBe("public");
  expect(classify(PRIV, ABSENT)).toBe("public");
  expect(classify(PUB, BROKEN)).toBe("private");
});

test("narrated crosses FROM a zone, raw from the same zone does not, and .bak does not", () => {
  expect(classify(NARRATED, VALID)).toBe("public");
  expect(classify(`${ZONE}/RawTranscript.md`, VALID)).toBe("private");
  expect(classify(`${NARRATED}.rawtranscript.jsonl`, VALID)).toBe("private");
  expect(isQuotable(`${NARRATED}.bak`, VALID)).toBe(false);
});

test("a trailing-slash rule names its own directory", () => {
  expect(matchesRule("/vault", "/vault/")).toBe(true);
  expect(matchesRule("/vault/x.md", "/vault/")).toBe(true);
  expect(matchesRule("/vaulted", "/vault/")).toBe(false); // positive control
});

test("unregistered is quote-closed but still counted", () => {
  expect(isQuotable(NEW, VALID)).toBe(false);
  const { quotable, countableOnly } = splitBySensitivity([PUB, PRIV, NEW], VALID);
  expect(quotable).toEqual([PUB]);
  expect(countableOnly).toEqual([PRIV, NEW]);
  expect(quotable.length + countableOnly.length).toBe(3);
  for (const p of [PRIV, PUB, NEW]) expect(isCountable(p)).toBe(true);
});

test("quote guard throws for private, stays quiet for public; labels collapse", () => {
  expect(() => assertQuotable(PRIV, VALID)).toThrow(/refused/);
  expect(() => assertQuotable(PUB, VALID)).not.toThrow();
  expect(safeExcerpt(PRIV, () => "x", VALID)).toBeNull();
  expect(safeExcerpt(PUB, () => "x", VALID)).toBe("x");
  expect(bucketLabel(ZONE, VALID)).toBe(PRIVATE_BUCKET);
  expect(bucketLabel("proj-work", VALID)).toBe("proj-work");
  expect(() => assertCoarseAggregate(PRIV, "per-dir", VALID)).toThrow(/breakdown/);
  expect(() => assertCoarseAggregate(PRIV, "per-day", VALID)).not.toThrow();
});

// ── library: register loading ──────────────────────────────────────────────────
test("a missing file is absent; a typo'd or unparseable one is broken, not valid", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz-"));
  expect(loadRegister(pj(d, "nope.json")).state).toBe("absent");
  for (const [n, body] of [["typo", '{"privateZones":[{"match":"z"}]}'], ["empty", "{}"],
                           ["arr", "[]"], ["num", "123"], ["trunc", "{oops"]] as const) {
    const f = pj(d, `${n}.json`); writeFileSync(f, body);
    expect(loadRegister(f).state).toBe("broken");
  }
  const ok = pj(d, "ok.json"); writeFileSync(ok, '{"private":[{"match":"z"}]}');
  expect(loadRegister(ok).state).toBe("valid"); // positive control
});

test("the memo notices a same-size, same-mtime rewrite", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz2-"));
  const ref = pj(d, "ref"), f = pj(d, "r.json"); writeFileSync(ref, "x");
  const A = '{"private":[{"match":"aaaa"}],"public":[],"narratedExempt":[]}';
  const B = '{"private":[{"match":"bbbb"}],"public":[],"narratedExempt":[]}';
  expect(A.length).toBe(B.length);
  writeFileSync(f, A); Bun.spawnSync(["touch", "-r", ref, f]);
  expect(loadRegister(f).private[0]!.match).toBe("aaaa");
  writeFileSync(f, B); Bun.spawnSync(["touch", "-r", ref, f]);
  expect(loadRegister(f).private[0]!.match).toBe("bbbb");
});

test("unregistered() lists what awaits triage", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz3-"));
  mkdirSync(pj(d, "proj-brand-new")); mkdirSync(pj(d, "proj-work"));
  expect(unregistered(d, VALID)).toEqual(["proj-brand-new"]);
  expect(unregistered("/no/such/dir", VALID)).toEqual([]);
});

// ── guard: Bash is coarse on purpose ───────────────────────────────────────────




// ── guard: structured tools are exact ──────────────────────────────────────────
test("Read/Grep/Glob are checked on their path FIELDS, never on a pattern", () => {
  expect(guard({ tool_name: "Read", tool_input: { file_path: PRIV } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "x", path: ZONE } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Glob", tool_input: { path: ZONE, pattern: "*" } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Read", tool_input: { file_path: PUB } }, VALID)).toBeNull();
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "proj-vault", path: "/etc" } }, VALID)).toBeNull();
});


test("a narrated artifact must be a FILE, or a directory forges the exemption", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz17-"));
  const zone = pj(d, "proj-vault"); mkdirSync(zone);
  writeFileSync(pj(zone, "HANDOFF.md"), "narrated");
  writeFileSync(pj(zone, "raw.jsonl"), "SECRET");
  mkdirSync(pj(zone, "forged")); mkdirSync(pj(zone, "forged/HANDOFF.md"));
  writeFileSync(pj(zone, "forged/HANDOFF.md/inside.jsonl"), "SECRET");
  const reg: Register = { state: "valid", private: [{ match: "proj-vault" }], public: [],
    narratedExempt: [{ match: "/HANDOFF.md" }] };
  expect(read(pj(zone, "HANDOFF.md"), undefined, reg)).toBeNull();          // the document
  expect(read(pj(zone, "raw.jsonl"), undefined, reg)?.block).toBe(true);    // the record
  // A DIRECTORY wearing the name is not the narrative, and used to exempt its whole subtree.
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "S", path: pj(zone, "forged/HANDOFF.md") } }, reg)?.block).toBe(true);
  expect(read(pj(zone, "forged/HANDOFF.md/inside.jsonl"), undefined, reg)?.block).toBe(true);
  // The quote-closed default still holds for an untriaged project directory.
  expect(read(`${PROJECTS_DIR}/proj-brand-new/a.jsonl`)?.block).toBe(true);
});

// ── guard: register states ─────────────────────────────────────────────────────
test("an absent register is silent, everywhere", () => {
  expect(read(`${PROJECTS_DIR}/proj-vault/a.jsonl`, undefined, ABSENT)).toBeNull();
  expect(read(`${PROJECTS_DIR}/proj-brand-new/a.jsonl`, undefined, ABSENT)).toBeNull();
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "S", path: PROJECTS_DIR } }, ABSENT)).toBeNull();
});


test("the block message never echoes the register's why string", () => {
  const reg: Register = { state: "valid", private: [{ match: "proj-vault", why: "ACME litigation" }],
    public: [], narratedExempt: [] };
  const msg = read(`${PROJECTS_DIR}/proj-vault/a.jsonl`, undefined, reg)?.message ?? "";
  expect(msg).not.toContain("ACME");
  expect(msg).toContain("proj-vault"); // already in the caller's own call
});


// ── the wiring, end to end ─────────────────────────────────────────────────────
test("Read runs on its own hook, and upstream's dispatcher is untouched", () => {
  const tree = process.env.PZ_TREE;
  expect(tree, "run via tests/private-zones/run.sh (PZ_TREE unset)").toBeTruthy();
  const call = (hook: string, tool: string, input: unknown) =>
    Bun.spawnSync(["bun", `${tree}/hooks/${hook}`], {
      stdin: Buffer.from(JSON.stringify({ tool_name: tool, tool_input: input })),
    }).exitCode;
  const zone = `${process.env.HOME}/.claude/projects/proj-vault/a.jsonl`;
  const open = `${process.env.HOME}/.claude/projects/proj-work/a.jsonl`;
  expect(call("PrivateZoneEgressGuard.hook.ts", "Read", { file_path: zone })).toBe(2);
  expect(call("PrivateZoneEgressGuard.hook.ts", "Read", { file_path: open })).toBe(0);
  // Bash is out of scope in v4: the standalone hook must let it through.
  expect(call("PrivateZoneEgressGuard.hook.ts", "Bash", { command: `cat ${zone}` })).toBe(0);
  // Upstream's files come out of the patch byte-identical.
  expect(rf(`${tree}/hooks/PreToolGuard.hook.ts`, "utf8")).not.toContain("PrivateZoneEgressGuard");
  expect(rf(`${tree}/hooks/hooks.json`, "utf8")).not.toContain("PrivateZoneEgressGuard");
});

// ── ninth-review regressions ───────────────────────────────────────────────────






// ── tenth-review regressions ───────────────────────────────────────────────────
test("structured path fields resolve against cwd, so a relative path is checked", () => {
  // Option B: only a path that NAMES a zone is refused, so the fixtures name one.
  const root = PROJECTS_DIR.slice(0, PROJECTS_DIR.lastIndexOf("/"));
  expect(guard({ tool_name: "Grep", cwd: PROJECTS_DIR, tool_input: { pattern: "S", path: "proj-vault" } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Read", cwd: ZONE, tool_input: { file_path: "../proj-vault/a.jsonl" } }, VALID)).toBeNull();
  expect(guard({ tool_name: "Read", cwd: PROJECTS_DIR, tool_input: { file_path: "proj-vault/a.jsonl" } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Read", cwd: "/home/u/code", tool_input: { file_path: "./main.ts" } }, VALID)).toBeNull();
});


test("the own room is the concrete directory, not the rule text", () => {
  // Keying the grant on the RULE turned one `mkdir -p /tmp/decoy/proj-vault` into a key for
  // the real zone; it is now the shortest prefix of cwd that satisfies the rule.
  const zone = `${PROJECTS_DIR}/proj-vault`;
  expect(read(`${zone}/a.jsonl`, "/tmp/decoy/proj-vault")?.block).toBe(true);
  expect(read(`${zone}/a.jsonl`, zone)).toBeNull();
  expect(read(`${zone}/a.jsonl`, `${zone}/sub`)).toBeNull();
  expect(read(`${zone}/a.jsonl`, "/home/u/notes-about-proj-vault")?.block).toBe(true);
});

test("the structured lane checks cross-zone too, not just Bash", () => {
  const reg: Register = { state: "valid", private: [{ match: "proj-vault" }, { match: "/vault/" }], public: [], narratedExempt: [] };
  expect(guard({ tool_name: "Read", cwd: ZONE, tool_input: { file_path: "/vault/nda/proj-vault.md" } }, reg)?.block).toBe(true);
  expect(guard({ tool_name: "Read", cwd: ZONE, tool_input: { file_path: `${ZONE}/a.jsonl` } }, reg)).toBeNull();
});


test("classify normalises a trailing-slash rule, so triage never prints a declared zone", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz7-"));
  mkdirSync(pj(d, "proj-vault")); mkdirSync(pj(d, "proj-other"));
  const reg: Register = { state: "valid", private: [{ match: "proj-vault/" }], public: [], narratedExempt: [] };
  expect(classify(pj(d, "proj-vault"), reg)).toBe("private");
  expect(unregistered(d, reg)).toEqual(["proj-other"]);
});

test("the register path follows CLAUDE_CONFIG_DIR", () => {
  // REGISTER_PATH is resolved at import time, so this has to be asked in a fresh process.
  const out = Bun.spawnSync(["bun", "-e",
    'import("./PrivateZones.ts").then(m=>console.log(m.REGISTER_PATH,m.PROJECTS_DIR))'],
    { env: { ...process.env, CLAUDE_CONFIG_DIR: "/tmp/cfgroot" }, cwd: import.meta.dir }).stdout.toString();
  expect(out).toContain("/tmp/cfgroot/LIFEOS/USER/CONFIG/private-zones.json");
  expect(out).toContain("/tmp/cfgroot/projects");
});

test("an internal error fails OPEN: a guard bug must not wedge a read", () => {
  const hostile = { state: "valid", get private(): never { throw new Error("boom"); },
                    public: [], narratedExempt: [] } as unknown as Register;
  expect(guard({ tool_name: "Read", tool_input: { file_path: `${PROJECTS_DIR}/proj-vault/a.jsonl` } }, hostile)).toBeNull();
});

// ── eleventh-review regressions ────────────────────────────────────────────────



test("no personal zone name reaches SYSTEM code or the tests", () => {
  // The needles come from the operator's OWN register at run time, never from this file:
  // splitting a literal defeats grep, not a reader, and this repo is public.
  const src = rf(pj(import.meta.dir, "../../hooks/PrivateZoneEgressGuard.hook.ts"), "utf8")
    + rf(pj(import.meta.dir, "PrivateZones.ts"), "utf8");
  // No fallback to the fixture: its names appear in the shipped comments on purpose, so a
  // machine without the operator's register would report a leak about them.
  const path = process.env.PZ_REAL_REGISTER;
  const live = path ? loadRegister(path) : null;
  const needles = !live ? [] : [...live.private, ...live.public, ...live.narratedExempt]
    .map((r) => r.match).filter((m) => m.replace(/[^a-z0-9]/gi, "").length >= 3);
  // Positive control only where a register exists; elsewhere the scan is vacuous by design
  // and says so, rather than inventing needles.
  if (path) expect(needles.length).toBeGreaterThan(0);
  // Assert on INDEXES, never on the needle: `not.toContain(x)` prints x in its failure
  // message, so the test would publish the very name it exists to keep out of a public repo.
  const hits = needles.map((n, i) => (src.includes(n) ? i : -1)).filter((i) => i >= 0);
  expect(hits).toEqual([]);
  expect(src).toContain("PrivateZones"); // positive control: the files really were read
});

// ── twelfth-review regressions ─────────────────────────────────────────────────






// ── thirteenth-review regressions ──────────────────────────────────────────────






// ── sixteenth-review regressions ───────────────────────────────────────────────



test("classify treats a trailing-slash PUBLIC rule like a private one", () => {
  const d = mkdtempSync(pj(tmpdir(), "pz13-"));
  mkdirSync(pj(d, "proj-work")); mkdirSync(pj(d, "proj-new"));
  const reg: Register = { state: "valid", private: [], public: [{ match: "proj-work/" }], narratedExempt: [] };
  expect(classify(pj(d, "proj-work"), reg)).toBe("public");
  expect(unregistered(d, reg)).toEqual(["proj-new"]);
});

// ── seventeenth-review regressions ─────────────────────────────────────────────







// ── eighteenth-review regressions ──────────────────────────────────────────────





// ── nineteenth-review regressions ──────────────────────────────────────────────


// ── twentieth-review regressions ───────────────────────────────────────────────


test("a declared zone reached through a symlink is not 'untriaged'", () => {
  // A real symlink, because the previous version of this test built a string, asserted its
  // length and pinned nothing — and a dead-code sweep had already eaten these two helpers
  // once with the suite still green.
  const d = mkdtempSync(pj(tmpdir(), "pz15-"));
  const projects = pj(d, "projects"); mkdirSync(projects);
  const pub = pj(projects, "proj-work"); mkdirSync(pub); writeFileSync(pj(pub, "a.jsonl"), "x");
  const link = pj(d, "worklink"); symlinkSync(pub, link);
  const reg: Register = { state: "valid", private: [{ match: "proj-vault" }],
    public: [{ match: "proj-work" }], narratedExempt: [] };
  // Declared PUBLIC through the link: allowed only because classify is asked BOTH forms.
  expect(guard({ tool_name: "Read", tool_input: { file_path: pj(link, "a.jsonl") } }, reg)).toBeNull();
  // And a private zone reached through a link is still refused.
  const priv = pj(projects, "proj-vault"); mkdirSync(priv); writeFileSync(pj(priv, "a.jsonl"), "x");
  const plink = pj(d, "vaultlink"); symlinkSync(priv, plink);
  expect(guard({ tool_name: "Read", tool_input: { file_path: pj(plink, "a.jsonl") } }, reg)?.block).toBe(true);
});

// ── twenty-first-review regressions ────────────────────────────────────────────




// ── twenty-second-review regressions ───────────────────────────────────────────





// ── option B: only a path that NAMES a zone is refused ─────────────────────────



// ── twenty-fourth-review regressions ───────────────────────────────────────────

test("the untriaged default lives on the reading lane", () => {
  const untriaged = `${PROJECTS_DIR}/proj-brand-new`;
  expect(read(`${untriaged}/a.jsonl`)?.block).toBe(true);
  // Asserted through behaviour, because a dead-code sweep once ate the two helpers this
  // rule needs and the READ side then failed open with the suite still green.
  expect(classifyEitherIsWired()).toBe(true);
  // A declared PUBLIC directory is not caught by it.
  expect(read(`${PROJECTS_DIR}/proj-work/a.jsonl`)).toBeNull();
});

/** The untriaged rule needs its helpers present; a missing one fails OPEN inside the catch. */
function classifyEitherIsWired(): boolean {
  const untriaged = `${PROJECTS_DIR}/proj-brand-new/a.jsonl`;
  return !!guard({ tool_name: "Read", tool_input: { file_path: untriaged } }, VALID)?.block;
}

// ── twenty-fifth-review regressions ────────────────────────────────────────────

// ── v4: Bash is deliberately out of scope ──────────────────────────────────────
test("Bash is not this guard's business any more", () => {
  // Twenty-five of twenty-seven review rounds went into parsing shell, every fix opened a new
  // spelling, and it twice broke real work. The lane is gone; the library is the protection.
  const zone = `${PROJECTS_DIR}/proj-vault`;
  for (const command of [`cat ${zone}/a.jsonl`, `rg -n S ${zone}`, "cd proj-vault && cat a.jsonl"])
    expect(guard({ tool_name: "Bash", cwd: "/home/u", tool_input: { command } }, VALID)).toBeNull();
  expect(read(`${zone}/a.jsonl`)?.block).toBe(true);
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "x", path: zone } }, VALID)?.block).toBe(true);
});

test("the guard is inert for every tool it does not own", () => {
  for (const tool of ["Bash", "Write", "Edit", "MultiEdit", "WebFetch", "Task"])
    expect(guard({ tool_name: tool, tool_input: { file_path: `${PROJECTS_DIR}/proj-vault/a.jsonl` } }, VALID)).toBeNull();
});

// ── twenty-eighth-review regressions ───────────────────────────────────────────
test("a relative pattern naming the zone is a path, a bare regex is not", () => {
  const zone = `${PROJECTS_DIR}/proj-vault`;
  expect(guard({ tool_name: "Glob", cwd: PROJECTS_DIR, tool_input: { pattern: "proj-vault/**" } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Grep", cwd: PROJECTS_DIR, tool_input: { pattern: "S", glob: "proj-vault/**" } }, VALID)?.block).toBe(true);
  expect(guard({ tool_name: "Glob", cwd: PROJECTS_DIR, tool_input: { pattern: `${zone}/**` } }, VALID)?.block).toBe(true);
  // A content regex is not a root, even when it equals a zone name.
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "proj-vault", path: "/etc" } }, VALID)).toBeNull();
});

test("fail-closed covers a pathless call, and still allows the repair", () => {
  expect(guard({ tool_name: "Grep", tool_input: { pattern: "SECRET" } }, BROKEN)?.block).toBe(true);
  expect(guard({ tool_name: "Glob", tool_input: { pattern: "**/*.jsonl" } }, BROKEN)?.block).toBe(true);
  expect(read(REGISTER_PATH, undefined, BROKEN)).toBeNull();
  expect(read("/tmp/notes-private-zones.json.md", undefined, BROKEN)?.block).toBe(true);
});
