# lifeos-nix

Nix packaging of [LifeOS](https://github.com/danielmiessler/LifeOS) — Daniel Miessler's Life Operating System for Claude Code — turned into a deterministic, privacy-hardened Nix derivation with an immutable store path and no shell-rc mutation.

Upstream ships as an AI-native, skill-only distribution installed by a chain of `bun` TypeScript tools driven by `INSTALL.md`, assuming a writable `~/.claude` and network access at install time. lifeos-nix wraps that into a proper derivation: the skill+runtime payload is store-copied, every npm dependency tree is vendored as a fixed-output derivation (reproducible, offline), a small patch set neutralizes default background egress, and a `lifeos` launcher on `PATH` drives the upstream installer in user space — no `/etc`, `~/.zshrc`, or `~/.bashrc` writes.

> **Rebased across upstream releases.** LifeOS shipped v7.1.1 ("The Bitter Pill" reorg: skill-only distribution, config `yaml` → `toml`), then moved on to **v7.40.4** (a 40-version jump). Each rebase re-triaged the patch set against the fresh source — most divergences turned out to be clean upstream changes that dissolved on contact (the 7.40.4 pass alone dropped 6 of 19). The current set is **thirteen load-bearing patches**: privacy/runtime kills (f2, f4-*, 0029), the Linux DerivedWatch service, Pulse runtime fixes (systemd-unit ownership, NixOS unit-gen skip), settings/hooks override composition, `PROJECTS.md` dormancy, and a dev-first launcher default. Full list: `pkgs/tools/misc/lifeos/patches/` and `ISA.md` (local system of record).

---

## Quick install

### NixOS (via flake)

```nix
# flake.nix of your system config
{
  inputs.lifeos-nix.url = "git+https://codeberg.org/ljubitje/lifeos-nix";

  outputs = { self, nixpkgs, lifeos-nix, ... }: {
    nixosConfigurations.<host> = nixpkgs.lib.nixosSystem {
      modules = [
        lifeos-nix.nixosModules.lifeos
      ];
    };
  };
}
```

`nixosModules.lifeos` adds the package to `environment.systemPackages`. Then run the `lifeos` launcher once — on a fresh `~/.claude` it installs the LifeOS payload; on an existing pre-7.x install it **refuses** (freeze-guard) rather than clobber it.

### `nix profile` (any flake-aware Nix)

```bash
nix profile install git+https://codeberg.org/ljubitje/lifeos-nix#lifeos
lifeos          # first run installs into ~/.claude, then launches Claude Code with the LifeOS system prompt
```

### Try it ephemerally

```bash
nix run git+https://codeberg.org/ljubitje/lifeos-nix#lifeos
```

---

## What's inside

- **LifeOS v7.40.4** — fetched from `danielmiessler/LifeOS` at the pinned `v7.40.4` release tag (`be9e8ef`) as a fixed source, hash-locked.
- **`claude-code` pinned as source-of-truth** — a vendored derivation (`pkgs/tools/misc/claude-code/`) plus the official upstream `manifest.json` pin the exact `claude` CLI version, decoupled from the nixpkgs channel and multi-arch (the manifest carries every platform; `eachDefaultSystem` builds only the consumer's). `nixosModules.lifeos` puts it on the system `PATH` and in the Pulse unit's `PATH`. Bump: `pkgs/tools/misc/claude-code/update.sh <version>`, then rebuild — `versionCheckHook` verifies the pin at build. The wrapper also puts the pinned bun on `PATH` as a **suffix** (hooks are `#!/usr/bin/env bun` scripts, and a `claude` not started by the `lifeos` launcher — Pulse, `Inference.ts`, a bare `claude` — would otherwise fail every hook with `env: 'bun': No such file or directory`); a suffix, so a project's own devshell bun still wins.
- **`bun` pinned as source-of-truth** — nixpkgs' bun recipe vendored whole at `pkgs/tools/misc/bun/` (1.4.2; the whole recipe, because the release asset changes between versions), so every machine runs the same bun whatever nixpkgs revision it carries. `claude-code.passthru.bun` is the single handle: the `lifeos` derivation, the Pulse unit (`path` and `ExecStart`), the launcher and the devShell all take bun from it. Bumping bun means copying the newer recipe over, then running `tests/vendor-hashes-test.sh` — the vendored `node_modules` trees are fixed-output derivations, and a cached one hides a bun change (see below).
- **The module builds from *your* `pkgs`** — `nixosModules.lifeos` calls `mkPackages` with the consumer's `pkgs`, not this flake's own nixpkgs pin, so no `lifeos.inputs.nixpkgs.follows` line is needed for consistency. `claude-code` is unfree, and the module says so instead of switching the gate off internally: it asserts `nixpkgs.config.allowUnfree` (or an `allowUnfreePredicate` that allows it) and fails with a readable message otherwise.
- **Reproducible vendored dependencies** — one fixed-output derivation per `package.json` tree (root, TOOLS, PULSE, PULSE/Observability, TOOLS/TokenXray, plus the Evals and Prompting skill trees), built with `--frozen-lockfile --ignore-scripts` and `NEXT_TELEMETRY_DISABLED=1`. No runtime `bun install`, no postinstall beacons. Skill trees that reach non-Anthropic services (image-gen, scraping) are deliberately not vendored. Hashes captured for `x86_64-linux` (`vendor-locks/`), from-scratch reproducibility verified.
- **`fabric` + `yt-dlp` on the system `PATH`** — upstream documents `fabric -y URL` as the transcript path in six skills but never ships the tool, so a fresh install ENOENTs and falls back to scraping the YouTube page. `nixosModules.lifeos` installs both, creates `~/.config/fabric/.env` via tmpfiles (`f`, never `f+` — fabric refuses to start without the file, and truncating it would wipe a user's keys). One upstream defect is left standing on purpose and documented in `flake.nix`: with stdin left open fabric blocks forever, so programmatic callers must pass `< /dev/null`. Guard: `tests/fabric-test.sh`.
- **A thirteen-patch set** (all listed below) — privacy kills and a graceful-shutdown fix, plus Linux/Pulse runtime fixes and override composition.
- **The `lifeos` launcher** on `PATH` — drives the upstream installer offline/additively, then `exec`s Claude Code with `LIFEOS_SYSTEM_PROMPT.md`. No rc-file mutation, no shell alias. Includes a freeze-guard that refuses to run against a pre-7.x config root.

### Patches

Each patch is an additive `.patch` with a multi-paragraph header (bug, RCA, fix scope, verification). Hunks are always generated via `diff -u` against the extracted upstream source — never hand-counted.

| Patch                                    | Purpose                                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `f2-deploycore-skip-npm`                 | Stop the runtime `bun install` (both the legacy step and 7.40.4's `deployNestedDependencies`) — dependencies are vendored and bridged in from the store. |
| `f4-a-neutralize-update-check`           | Kill the external self-update check (updates come via Nix, not a phone-home).                    |
| `f4-b-elevenlabs-killswitch`             | ElevenLabs egress dead regardless of any configured key (local TTS seam preserved).              |
| `f4-c-pulse-disable-default-active`      | Ship `PULSE.toml` with the default-active egress modules (voice/notifications/local-intelligence) off. |
| `0029-fix-pulse-graceful-shutdown-on-sigterm` | Pulse exits cleanly on `SIGTERM` (no 60 s hang, no mid-`writeState` `SIGKILL`).             |
| `f-derived-watch-wire`                   | Wire an in-process inotify **DerivedWatch** module into Pulse `loadModules` — the Linux equivalent of launchd WatchPaths (on-edit regen of derived artifacts; debounced, single-flight, output-ignore). Module shipped via `installPhase` from `files/derived-watch.ts`. |
| `f-derived-watch-config`                 | Default-on `[derived_watch]` in base `PULSE.toml`.                                               |
| `f-launcher-cwd-default`                 | `lifeos` launcher stays in the **current directory** by default (dev-first); `--claude-dir`/`-c` opts into `~/.claude` for LifeOS-meta work. `--local` retained as a no-op alias. |
| `f-mergesettings-preserve-hooks`         | `MergeSettings` re-attaches hooks from the canonical `hooks/hooks.json` (else a user overlay drops the `SessionStart` array 5→0). |
| `f-pulse-unit-nixos-skip`                | On NixOS, skip the installer's unit-gen; the nix module owns `com.lifeos.pulse.service` with the correct `PATH` (else cron jobs `ENOENT` on `/bin/bash`). |
| `f-projects-dormant`                     | Do not force-load `USER/PROJECTS.md` (unbounded growth → ~53% of startup context); opt-in via manual uncomment, on-demand via Cortex recall. |
| `f-projects-no-memory-writes`            | Retire the memory machinery around `PROJECTS.md` (reviewer proposals / tier-B / GC / freshness) — companion to `f-projects-dormant`. |
| `f-mergesettings-hooks-overlay`          | Compose `LIFEOS/USER/CONFIG/hooks.user.json` over the official `hooks.json` — our hooks leave the official file, so it syncs cleanly with no B∩C collision. |
| `f-inference-provider`                   | `LIFEOS/USER/CONFIG/inference.conf` (`mode=anthropic-only` · `local-with-fallback` · `local-only`, plus the local server) points `claude` at a local Anthropic-compatible server. The claude-code wrapper reads the mode exactly and routes every exec; `anthropic-only` is the upstream path. The `local-only` guarantee is the network room (planned); the subscription OAuth token is never sent to the local server. |
| `f-siri-retire`                          | Pulse no longer loads the Siri voice-turn endpoint (tunnel-exposed, and its Agent SDK path bypasses the `claude` gate). |

> Six patches from the 7.1.1 set **dissolved** on the 7.40.4 rebase — upstream independently shipped the same fix (the `~`-path cron preflight, the doc-integrity rename, the TELOS unified-first read, the settings prune-write-path, the module-flag gating, and the cron half-open breaker). Convergent evolution; re-triaged out rather than re-ported.

---

## Privacy invariant

**No default background egress beyond Anthropic.** This is the load-bearing property of the packaging and it is enforced by a test, not just a config default: `tests/egress-test.sh` activates the built payload inside a rootless deny-all network namespace under `strace -e network` (with a positive control) and asserts zero external `connect()`s across activation, the job/check scripts, and Pulse boot. The privacy patches (`f4-*`) are belt-and-suspenders on top of that proof.

`tests/settings-merge-test.sh` covers the install semantics: a virgin install, a merge that never clobbers pre-existing user values, and idempotent re-installs.

Two more cuts sit on top of the invariant: the `claude` wrapper sets `DISABLE_TELEMETRY` and `DISABLE_ERROR_REPORTING` for every exec (Claude Code's own Datadog/Sentry/GrowthBook reporting), and Pulse no longer loads the tunnel-exposed Siri endpoint (`f-siri-retire`).

---

## Local inference

LifeOS can run on a local, Anthropic-compatible model server instead of — or in front of — Anthropic. One file in the USER zone, `~/.claude/LIFEOS/USER/CONFIG/inference.conf`, one `key=value` per line:

```
mode=local-with-fallback        # anthropic-only | local-with-fallback | local-only
base_url=http://host:8000       # must speak Anthropic /v1/messages (OpenAI-only: put a translating proxy in front)
model=my-model                  # all tiers; model_fable / model_opus / model_sonnet / model_haiku override
token_env=MY_SERVER_TOKEN       # optional; the env var holding the server's key
```

| mode | what happens |
|---|---|
| no file, or `anthropic-only` | the upstream path: the real `claude` runs unchanged (~10 ms of wrapper per exec, no bun) |
| `local-with-fallback` | every `claude` goes to the local server while it answers; if it does not, that `claude` runs on Anthropic with a notice. `Inference.ts` retries a failed local call once on Anthropic. |
| `local-only` | always local, never Anthropic, even when the server is down; WebFetch, claude.ai MCP and nonessential traffic are off |

How it works: the lifeos-nix `claude` (`pkgs/tools/misc/claude-code/claude-gate.sh`) reads `inference.conf` once, in shell, from the account's passwd home, before every exec of the real binary, so the launcher, Pulse, hooks, skills and a bare `claude` all pass through it. Local modes hand the text to `InferenceProvider.ts`, which sets the env (server URL, model names per tier, a credential). Anything it cannot read exactly (unknown key, typo, repeated key, unreadable file, a `token_env` that is not set) refuses instead of guessing. Edit the file and the next `claude` follows it; `LIFEOS_GATE=off` bypasses the gate, except where the file says `local-only`.

Things worth knowing:

- **No Anthropic login needed for local modes.** The gate always sets `ANTHROPIC_AUTH_TOKEN`, which Claude Code treats as authentication, so a first run shows the theme and folder-trust screens and no login step. Without a subscription, use `local-only`: `local-with-fallback` would fall back to an Anthropic it cannot reach.
- **Your subscription token never reaches the local server.** With only `ANTHROPIC_BASE_URL` set, Claude Code sends the OAuth bearer to that URL (measured); the always-set `ANTHROPIC_AUTH_TOKEN` outranks it.
- **The gate routes; it is not a sandbox.** Claude Code itself can still reach Anthropic outside the gate's view (telemetry it does not gate, OAuth refresh, its own subcommands). A network-level guarantee for `local-only` is planned and deferred. The accepted limits are listed in the header of `f-inference-provider.patch`.

`tests/inference-provider/run.sh` runs 112 tests against the pinned source plus the patch list and the real gate script, in `env -i` with a fake passwd so nothing touches the runner's own home: parsing and refusals, shell/TypeScript agreement on the same bytes (C and UTF-8 locales), the routing table, the gate end to end, and `Inference.ts` through the gate. Mutation-checked.

---

## Design principles

- **Transparency over runtime patching.** Every upstream modification is an auditable `.patch`. Build-time mutations are documented inline in `default.nix`.
- **Privacy is a test, not a hope.** The egress invariant is asserted against the *built tree*, not the live install.
- **Reproducible, offline, hermetic.** No network at build time beyond the hash-locked sources and vendored FOD trees; `--ignore-scripts` keeps postinstall beacons out of the hash.
- **Pins are owned here.** The LifeOS payload, the `claude-code` CLI and the `bun` they run on are pinned in this repo as source-of-truth, not inherited from a moving channel.
- **Consent is explicit.** Unfree software is never allowed behind the consumer's back; the module asserts the consumer's own `allowUnfree` choice.
- **Brand ≠ path.** The rename touches branding and flake outputs only — the config root stays `~/.claude` because Claude Code hardcodes it.

---

## Status

**Build green + from-scratch reproducible** — `nix build --rebuild` yields identical output (including the emitted `MANIFEST.sha256`), `nix flake check` passes, and there are no impure builtins. Privacy invariant **proven** by `tests/egress-test.sh`; install semantics covered by `tests/settings-merge-test.sh` (24/24). `packages.lifeos` (= `packages.default`), `packages.claude-code`, and `nixosModules.lifeos` evaluate and build.

**On v7.40.4, deployed + sealed.** The 7.1.1.1 → 7.40.4 rebase (40-version upstream jump) is complete: source re-pinned, dependency trees re-vendored case-by-case, patch set re-triaged 19 → 13, and `claude-code` pinned as source-of-truth. `tests/smoke-test.sh` boots Pulse in a rootless net namespace (loopback isolated from any live instance) and asserts `/healthz` → HTTP 200, graceful `SIGTERM` shutdown (~110 ms), and the dashboard — built into the derivation via a hermetic `next build` — serving. Store→live payload durability is closed by `payload-sync` (a shipped tool plus a build-time `MANIFEST.sha256`).

**Known gap — upstream removals could be missed silently.** `payload-sync` does detect official
deletions, but that detection hung on `--old` (the previous payload), which is an optional
argument: when a caller omitted it, the entire class went unexamined and nothing said so. On the
7.1.1.0 → 7.40.4.6 jump that left 193 stale files on a live install, including one tool that had
been dead at import for weeks and a casing-rename pair that coexisted.

**Now reported without `--old`.** The run reports a `STALE` bucket — live, absent from the new
payload, and carrying a hash that was official in some past release per the accumulated
`known-official.sha256`. It **deletes nothing**; removal stays a human decision. A file whose path
was once official but whose live hash is unknown is listed separately as `STALE?`, because that is
just as likely to be your own edit.

Still owed: decide, once the report has been lived with, whether removal becomes an opt-in
`--prune` with per-class confirmation or stays manual. Deleting on sync is destructive against a
tree that also holds files the user owns, which is why reporting came first.

**bun pin + hook PATH (2026-10-08, deployed; not yet versioned).** Since the inference-gate update, hooks failed with `env: 'bun': No such file or directory` in any session not started by `lifeos`: bun reached `PATH` only through the launcher. Fixed in layers: the claude wrapper suffixes bun onto `PATH`; bun itself is pinned here (1.4.2) and shared through `claude-code.passthru.bun`; the module builds from the consumer's `pkgs` and asserts `allowUnfree`. Guard: `tests/vendor-hashes-test.sh` rebuilds all seven `lifeos-deps-*` trees under the pinned bun and compares them with their declared hashes, with a control that must fail on a wrong hash (7/7 pass, ~5 min, needs network). `lifeos` is still 7.40.4.23 — these are packaging changes without a version bump; a `.24` is owed. Not yet seen: a fresh bare-`claude` session confirming the hook error is gone.

**7.40.4.23 — local inference.** `inference.conf` with three modes, routed at every `claude` exec
(see *Local inference*), Siri retired, Claude Code telemetry off. Reached after ten review
rounds, the last of which found nothing against the agreed bar: `anthropic-only` behaves as
upstream, local modes route correctly under normal conditions, misconfiguration refuses.
Deferred: the network room that would make `local-only` a guarantee rather than routing.

---

## Repository structure

```
lifeos-nix/
├── flake.nix                       # Top-level flake (packages.lifeos + default + claude-code; nixosModules)
├── pkgs/tools/misc/
│   ├── lifeos/
│   │   ├── default.nix             # The Nix derivation, vendored deps, and the `lifeos` wrapper
│   │   ├── patches/                # The load-bearing patch set
│   │   ├── files/                  # DerivedWatch module, copied into the payload at installPhase
│   │   └── vendor-locks/           # Injected bun lockfiles + hashes
│   ├── claude-code/                # Vendored claude-code derivation + pinned manifest.json + update.sh
│   │                               #   + claude-gate.sh, the inference gate installed as bin/claude
│   └── bun/                        # bun 1.4.2, nixpkgs recipe vendored whole; the one bun LifeOS runs on
├── tests/
│   ├── egress-test.sh              # Privacy invariant (deny-all netns + strace)
│   ├── settings-merge-test.sh      # Merge-safe install semantics
│   ├── vendor-hashes-test.sh       # Every lifeos-deps-* tree reproduces its hash under the pinned bun (with a control)
│   └── inference-provider/         # Inference gate: run.sh + 112 tests
├── README.md                       # this file
└── LICENSE                         # AGPL-3.0
```

---

## License

This repository — the Nix expressions, patches, and documentation written here — is licensed under the **GNU Affero General Public License v3.0 only** (AGPL-3.0-only). See [`LICENSE`](LICENSE).

The packaged software, **LifeOS**, is fetched as upstream source at build time and remains under its own license: **MIT**, © Daniel Miessler. The `claude-code` CLI is fetched from Anthropic's official distribution under its own terms.

The licenses are compatible: AGPL-3.0 covers the packaging contribution (this repo), MIT covers the bundled application. End users who interact with a hosted service running lifeos-nix are entitled to the source of the AGPL-licensed packaging contribution under section 13 of AGPL-3.0; LifeOS itself remains under MIT.

---

## Acknowledgements

- Daniel Miessler for [LifeOS](https://github.com/danielmiessler/LifeOS) — the Life OS itself.
- nixpkgs maintainers for the conventions this repo follows.
