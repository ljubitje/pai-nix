#!/usr/bin/env bun
/**
 * DerivedWatch — event-driven regen of derived artifacts on manual USER edits.
 * The Linux answer to launchd WatchPaths, run inside the Pulse daemon (0 extra processes).
 *
 * Minimal-resource by design:
 *   - inotify via fs.watch on a fixed set of USER source dirs — no recursion, no polling.
 *     On Linux a dir watch already delivers child-file modify events (unlike systemd .path).
 *   - Debounced: an edit burst coalesces into ONE DerivedSync run after DEBOUNCE_MS of quiet.
 *   - Single-flight: never overlaps a running DerivedSync; if edits arrive mid-run, re-runs once.
 *   - DerivedSync.ts is hash-idempotent, so any spurious fire is a cheap no-op.
 *
 * The daily `derived-sync` cron job stays as a safety-net for events inotify may miss.
 */
import { watch, existsSync, type FSWatcher } from 'node:fs';
import { join, resolve, basename } from 'node:path';
import { homedir } from 'node:os';

declare const Bun: {
  spawn: (cmd: string[], opts?: { stdout?: 'ignore' | 'pipe' | 'inherit'; stderr?: 'ignore' | 'pipe' | 'inherit' }) => { exited: Promise<number> };
};

const DEBOUNCE_MS = Number(process.env.DERIVED_WATCH_DEBOUNCE_MS || 30_000); // = launchd ThrottleInterval 30s
const CLAUDE_ROOT = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const USER_DIR = resolve(process.env.LIFEOS_USER_DIR || join(CLAUDE_ROOT, 'LIFEOS', 'USER'));
// Command to run on a settled edit. Overridable for tests; defaults to DerivedSync.ts.
const DERIVED_CMD = process.env.DERIVED_WATCH_CMD
  ? process.env.DERIVED_WATCH_CMD.split(' ')
  : ['bun', 'run', join(CLAUDE_ROOT, 'LIFEOS', 'TOOLS', 'DerivedSync.ts')];

// The USER source subtrees DerivedSync cares about (mirrors the launchd WatchPaths set).
const WATCH_SUBDIRS = ['', 'TELOS', 'TELOS/IDEAL_STATE', 'TELOS/CURRENT_STATE', 'PRINCIPAL', 'DIGITAL_ASSISTANT', 'CONFIG'];

// DerivedSync's own outputs live under these watched dirs — ignore them, or every regen
// re-triggers the watcher (a self-feeding loop; hash-idempotence would cap it at one no-op
// run per regen, but ignoring outright means zero wasted spawns). KEEP IN SYNC with
// DerivedSync.ts's own watch-list exclusions; if it ever writes a new derived artifact INTO
// the watched USER tree, add it here too (else derived-watch would spin a spawn every 30s).
const IGNORE_FILES = new Set(['PRINCIPAL_TELOS.md', 'LIFEOS_STATE.json']);

let watchers: FSWatcher[] = [];
let timer: ReturnType<typeof setTimeout> | null = null;
let running = false;
let dirtyDuringRun = false;

async function runDerivedSync(): Promise<void> {
  if (running) { dirtyDuringRun = true; return; }
  running = true;
  try {
    await Bun.spawn(DERIVED_CMD, { stdout: 'ignore', stderr: 'ignore' }).exited;
  } catch { /* hash-idempotent — the next event or the daily cron recovers */ }
  running = false;
  if (dirtyDuringRun) { dirtyDuringRun = false; schedule(); }
}

function schedule(): void {
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => { timer = null; void runDerivedSync(); }, DEBOUNCE_MS);
}

export function start(): number {
  for (const sub of WATCH_SUBDIRS) {
    const dir = sub ? join(USER_DIR, sub) : USER_DIR;
    if (!existsSync(dir)) continue;
    try {
      const w = watch(dir, (_ev, filename) => {
        if (filename && IGNORE_FILES.has(basename(String(filename)))) return;
        schedule();
      });
      // An async inotify 'error' (watched dir removed/renamed, fs.inotify.max_user_watches
      // exhausted) is emitted on the watcher; with no listener Node throws and could crash the
      // long-lived Pulse daemon. Drop the dead watcher instead — the daily derived-sync cron
      // is the safety-net for the coverage lost until the next Pulse restart.
      w.on("error", () => { try { w.close(); } catch { /* already closed */ } });
      watchers.push(w);
    } catch { /* skip unwatchable dir */ }
  }
  console.log(`[derived-watch] watching ${watchers.length} USER dirs (debounce ${DEBOUNCE_MS}ms)`);
  return watchers.length;
}

export function stop(): void {
  if (timer) { clearTimeout(timer); timer = null; }
  for (const w of watchers) { try { w.close(); } catch { /* already closed */ } }
  watchers = [];
}
