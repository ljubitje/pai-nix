#!/usr/bin/env bun
/**
 * payload-sync — lifeos-nix store→live payload durability tool
 *
 * Reševanje payload-trajnosti: rebuild osveži nix-store payload (B), a živ ~/.claude
 * ne dobi posodobitev OBSTOJEČIH fajlov (deploy je "copy-missing, never overwrite").
 * Ta tool klasificira vsak fajl in — z --apply — deterministično sinka spremembe v živ.
 * Privzeto DRY-RUN (nič ne piše); --apply prepiše z backupom + verify restore-ability.
 *
 * Klasifikacija (design: PAYLOAD_SYNC_DESIGN.md):
 *   A = uraden, katerakoli verzija ≠ B   B = nov uradni   C = res najin (nikoli iz lifeos-nix)
 *
 * "Znano uradno" = množica hashev, ki jo poznamo. Zdaj (B1) = {stari store, novi store}
 * prek --old/--new (bootstrap). B2: MANIFEST.sha256 iz builda nadomesti --old. Kar ni
 * znano-uradno in ≠ B → REVIEW (safe-default: negotovo → NE prepiši, pošlji v skill/human).
 *
 * lifeos-nix-specifičen (vanilla nima store→live razcepa); shipan v LIFEOS/TOOLS/ prek installPhase.
 *
 * Uporaba:
 *   bun payload-sync.ts --new <B-install-dir> [--old <A-install-dir>] [--live <~/.claude>] [--roots LIFEOS,hooks] [--apply]
 */
import { createHash } from "node:crypto"
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, copyFileSync, rmSync, chmodSync, statSync } from "node:fs"
import { join, relative, dirname } from "node:path"

function arg(flag: string, def?: string): string | undefined {
  const i = process.argv.indexOf(flag)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : def
}

const NEW = arg("--new")!
const OLD = arg("--old") // optional fallback / bootstrap accelerator
const LIVE = arg("--live", join(process.env.HOME ?? "", ".claude"))!
const ROOTS = (arg("--roots", "LIFEOS,hooks") as string).split(",")
const MANIFEST = arg("--manifest", join(NEW, "MANIFEST.sha256"))!   // official fingerprints for B (this release)
const KNOWN = arg("--known", join(LIVE, "LIFEOS", "MEMORY", "STATE", "known-official.sha256"))! // accumulated across releases

if (!NEW || !existsSync(NEW)) { console.error("payload-sync: --new (B payload install dir) manjka/ne obstaja"); process.exit(2) }

const SKIP = /(^|\/)(USER|MEMORY|node_modules|\.git)(\/|$)|\/Observability\/out\/|\/\.next\//

const sha = (p: string): string | null => {
  try { return createHash("sha256").update(readFileSync(p)).digest("hex") } catch { return null }
}

// ── Known-official set (B2): a live file whose hash is a known official fingerprint for its
// path is safe to overwrite with B (it's some official version, not ours). The set accumulates
// across releases in KNOWN; each run ingests the current release's MANIFEST so it counts going
// forward. Off the list ⇒ ours ⇒ never auto-overwritten (REVIEW / merge). --old stays as an
// optional bootstrap accelerator for the first run before any manifest history exists.
function parseHashList(p: string): Array<[string, string]> {   // sha256sum format: `<hash>  <path>`
  if (!existsSync(p)) return []
  const out: Array<[string, string]> = []
  for (const line of readFileSync(p, "utf8").split("\n")) {
    const m = line.match(/^([0-9a-f]{64})\s+(.+)$/)
    if (m) out.push([m[1], m[2].trim()])
  }
  return out
}
const known = new Map<string, Set<string>>()
const addKnown = (h: string, p: string) => { let s = known.get(p); if (!s) known.set(p, s = new Set()); s.add(h) }
for (const [h, p] of parseHashList(KNOWN)) addKnown(h, p)          // accumulated history
const manifestFound = existsSync(MANIFEST)
for (const [h, p] of parseHashList(MANIFEST)) addKnown(h, p)       // this release (B) → official henceforth

function* walk(dir: string): Generator<string> {
  if (!existsSync(dir)) return
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isSymbolicLink()) continue
    if (e.isDirectory()) yield* walk(p)
    else if (e.isFile()) yield p
  }
}

type Bucket = "CURRENT" | "TAKE_B" | "ADD" | "REVIEW" | "DELETE"
const buckets: Record<Bucket, string[]> = { CURRENT: [], TAKE_B: [], ADD: [], REVIEW: [], DELETE: [] }

// --- za vsak fajl v NOVEM payloadu (B): klasificiraj živ ---
for (const root of ROOTS) {
  for (const nf of walk(join(NEW, root))) {
    const rel = relative(NEW, nf)
    if (SKIP.test("/" + rel)) continue
    const lf = join(LIVE, rel)
    if (!existsSync(lf)) { buckets.ADD.push(rel); continue }
    const b = sha(nf), l = sha(lf)
    if (l === b) { buckets.CURRENT.push(rel); continue }
    // A-detection: live is a known official hash for this path (any release) → safe overwrite with B.
    const officialByManifest = l != null && (known.get(rel)?.has(l) ?? false)
    const officialByOld = OLD ? l === sha(join(OLD, rel)) : false
    if (officialByManifest || officialByOld) buckets.TAKE_B.push(rel)   // A∩B: known-official older version
    else buckets.REVIEW.push(rel)   // off the list ⇒ ours / diverged: official has an update AND live changed → MERGE-candidate (B3 skill), never blind overwrite
  }
}

// --- A brez B: fajl v STAREM payloadu, ki ga NOV nima (uradni izbris) ---
if (OLD) for (const root of ROOTS) {
  for (const of_ of walk(join(OLD, root))) {
    const rel = relative(OLD, of_)
    if (SKIP.test("/" + rel)) continue
    if (!existsSync(join(NEW, rel)) && existsSync(join(LIVE, rel))) {
      // briši SAMO če je živ star-uradni (== A); če smo ga mi spremenili → REVIEW, ne slep izbris
      if (sha(join(LIVE, rel)) === sha(of_)) buckets.DELETE.push(rel)
      else buckets.REVIEW.push(rel)
    }
  }
}

// --approve: human/skill je potrdil te REVIEW fajle kot star-uradne → TAKE_B (comma-sep rel poti)
for (const rel of (arg("--approve", "") as string).split(",").map(s => s.trim()).filter(Boolean)) {
  const i = buckets.REVIEW.indexOf(rel)
  if (i >= 0) { buckets.REVIEW.splice(i, 1); buckets.TAKE_B.push(rel) }
  else console.error(`  ⚠ --approve: '${rel}' ni v REVIEW (ignoriram)`)
}

const line = (b: Bucket, desc: string) => console.log(`  ${b.padEnd(8)} ${String(buckets[b].length).padStart(4)}  — ${desc}`)
const knownPaths = known.size, knownHashes = [...known.values()].reduce((n, s) => n + s.size, 0)
console.log(`\n════ payload-sync DRY-RUN (roots: ${ROOTS.join(", ")}) ════`)
console.log(`  new(B):    ${NEW}`)
console.log(`  manifest:  ${manifestFound ? MANIFEST : "(brez — B2 detekcija degradirana; live≠B → REVIEW)"}`)
console.log(`  known:     ${knownPaths} poti / ${knownHashes} uradnih hashev (akumulator: ${existsSync(KNOWN) ? KNOWN : "nov"})`)
console.log(`  old(A):    ${OLD ?? "(brez — fallback ni v rabi)"}`)
console.log(`  live:      ${LIVE}\n`)
line("CURRENT", "živ == B, že svež → skip")
line("TAKE_B", "živ == znan-uradni hash (A∩B) → determinističen prepis z B")
line("ADD", "nov fajl → copy-missing")
line("REVIEW", "off-list ⇒ najin/diverged → MERGE-kandidat (B3 skill), nikoli slep prepis")
line("DELETE", "A brez B (uradni izbris) → briši (z backupom)")
console.log(`\n── REVIEW (merge-kandidati — uradni ima update IN živ je spremenjen; skill/human zlije): ──`)
for (const r of buckets.REVIEW) console.log("   " + r)
if (buckets.DELETE.length) { console.log(`\n── DELETE kandidati: ──`); for (const r of buckets.DELETE) console.log("   " + r) }

// ── APPLY (samo z --apply; sicer dry-run) ──────────────────────────────────
const APPLY = process.argv.includes("--apply")
if (!APPLY) { console.log("\n(dry-run — nič spremenjeno. Za izvedbo dodaj --apply)\n"); process.exit(0) }

const stamp = new Date().toISOString().replace(/[:.]/g, "-")
const BACKUP = arg("--backup-dir", join(LIVE, `.payload-sync-backup-${stamp}`))!

/** Backup + VERIFY restore-ability (Klemnovo pravilo: dokazano restore-able, ne le vzet). */
function backup(rel: string) {
  const src = join(LIVE, rel), dst = join(BACKUP, rel)
  mkdirSync(dirname(dst), { recursive: true })
  copyFileSync(src, dst)
  if (sha(src) !== sha(dst)) throw new Error(`BACKUP VERIFY FAIL za ${rel} — abort, nič ne pišem`)
}

// store-copied live files inherit the store's read-only 444 mode; make dest owner-writable
// before overwriting (mirrors the launcher's `chmod -R u+w $CFG`), preserving other mode bits.
const ensureWritable = (p: string) => { if (existsSync(p)) chmodSync(p, statSync(p).mode | 0o200) }

let took = 0, added = 0, deleted = 0
for (const rel of buckets.TAKE_B) { backup(rel); const d = join(LIVE, rel); ensureWritable(d); copyFileSync(join(NEW, rel), d); took++ }
for (const rel of buckets.ADD)   { const d = join(LIVE, rel); mkdirSync(dirname(d), { recursive: true }); copyFileSync(join(NEW, rel), d); added++ }
for (const rel of buckets.DELETE){ backup(rel); rmSync(join(LIVE, rel)); deleted++ }
// REVIEW + CURRENT: NIKOLI ne piše.

// Persist the accumulated known-official set (monotonic across releases): this release's
// MANIFEST is now folded in, so future runs recognize these hashes as official. Only on
// --apply (dry-run stays read-only). Sorted by path for a stable, diffable file.
let persistedKnown = 0
if (manifestFound) {
  const lines: string[] = []
  for (const [p, hs] of known) for (const h of hs) { lines.push(`${h}  ${p}`); persistedKnown++ }
  lines.sort((a, b) => (a.slice(66) < b.slice(66) ? -1 : a.slice(66) > b.slice(66) ? 1 : 0))
  mkdirSync(dirname(KNOWN), { recursive: true })
  writeFileSync(KNOWN, lines.join("\n") + "\n")
}

console.log(`\n════ APPLY izveden ════`)
console.log(`  TAKE_B prepisanih:  ${took}`)
console.log(`  ADD dodanih:        ${added}`)
console.log(`  DELETE izbrisanih:  ${deleted}`)
console.log(`  known-official:     ${persistedKnown} hashev ${manifestFound ? "→ " + KNOWN : "(brez manifesta — ni posodobljen)"}`)
console.log(`  REVIEW NEDOTAKNJEN: ${buckets.REVIEW.length} (skill/human)`)
console.log(`  backup:             ${BACKUP}\n`)
