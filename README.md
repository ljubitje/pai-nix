# lifeos-nix

Nix packaging of [LifeOS](https://github.com/danielmiessler/LifeOS) — Daniel Miessler's Life Operating System for Claude Code — turned into a deterministic, privacy-hardened Nix derivation with an immutable store path and no shell-rc mutation.

Upstream ships as an AI-native, skill-only distribution installed by a chain of `bun` TypeScript tools driven by `INSTALL.md`, assuming a writable `~/.claude` and network access at install time. lifeos-nix wraps that into a proper derivation: the skill+runtime payload is store-copied, every npm dependency tree is vendored as a fixed-output derivation (reproducible, offline), a small patch set neutralizes default background egress, and a `lifeos` launcher on `PATH` drives the upstream installer in user space — no `/etc`, `~/.zshrc`, or `~/.bashrc` writes.

> **Rebased from the earlier v5.0.0 PAI packaging.** Upstream renamed PAI → LifeOS and shipped v7.1.1 ("The Bitter Pill" reorg): skill-only distribution, `PAI/` → `LIFEOS/`, config `yaml` → `toml`. The 29 v5.0.0-era patches were retired after a full triage against 7.1.1 (most fixed upstream or made obsolete); the current set is nine load-bearing patches — five privacy/runtime (f2, f4-*, 0029) plus four completing upstream's unfinished PAI→LIFEOS migration and adding the Linux DerivedWatch service (f-telos, f-derived-watch ×2, f-docintegrity). History: `ISA.md` (local system of record).

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
        lifeos-nix.nixosModules.lifeos   # `nixosModules.pai` is kept as a compat alias
      ];
    };
  };
}
```

`nixosModules.lifeos` adds the package to `environment.systemPackages`. Then run the `lifeos` launcher once — on a fresh `~/.claude` it installs the LifeOS payload; on an existing pre-7.x PAI/LifeOS tree it **refuses** (freeze-guard) rather than clobber it.

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

- **LifeOS v7.1.1** — fetched from `danielmiessler/LifeOS` at the pinned `v7.1.1` release tag (`a4e8e74`) as a fixed source, hash-locked.
- **Reproducible vendored dependencies** — one fixed-output derivation per `package.json` tree (root, TOOLS, PULSE, PULSE/Observability, TOOLS/TokenXray), built with `--frozen-lockfile --ignore-scripts` and `NEXT_TELEMETRY_DISABLED=1`. No runtime `bun install`, no postinstall beacons. Hashes captured for `x86_64-linux` (`vendor-locks/HASHES.txt`), from-scratch reproducibility verified.
- **A five-patch set** (see below) — privacy kills + a graceful-shutdown fix.
- **The `lifeos` launcher** on `PATH` — drives the upstream installer offline/additively, then `exec`s Claude Code with `LIFEOS_SYSTEM_PROMPT.md`. No rc-file mutation, no shell alias. Includes a freeze-guard that refuses to run against a pre-7.x config root.

### Patches

Each patch is a numbered, additive `.patch` with a multi-paragraph header (bug, RCA, fix scope, verification). Hunks are always generated via `diff -u` against the extracted upstream source — never hand-counted.

| Patch                                    | Purpose                                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `f2-deploycore-skip-npm`                 | Stop the runtime `bun install` — dependencies are vendored and bridged in from the store.        |
| `f4-a-neutralize-update-check`           | Kill the external self-update check (updates come via Nix, not a phone-home).                    |
| `f4-b-elevenlabs-killswitch`             | ElevenLabs egress dead regardless of any configured key (local TTS seam preserved).              |
| `f4-c-pulse-disable-default-active`      | Ship `PULSE.toml` with the default-active egress modules (voice/telegram/morning-brief) off.     |
| `0029-fix-pulse-graceful-shutdown-on-sigterm` | Pulse exits cleanly on `SIGTERM` (no 60 s hang, no mid-`writeState` `SIGKILL`).             |
| `f-telos-source-unified-first`           | `GenerateTelosSummary` reads the unified `TELOS.md` first, so re-scaffolded SAMPLE per-files can't shadow real identity content in `PRINCIPAL_TELOS.md` (@-imported into the DA identity). |
| `f-derived-watch-wire`                   | Wire an in-process inotify **DerivedWatch** module into Pulse `loadModules` — the Linux equivalent of launchd WatchPaths (on-edit regen of derived artifacts; debounced, single-flight, output-ignore). Module shipped via `installPhase` from `files/derived-watch.ts`. |
| `f-derived-watch-config`                 | Default-on `[derived_watch]` in base `PULSE.toml`.                                               |
| `f-docintegrity-rename`                  | Finish the PAI→LIFEOS rename in the doc-integrity chain (`DocCrossRefIntegrity`, `change-detection`): dead `PAI/` path-gates → `/DOCUMENTATION/`, ref-regex → `LIFEOS/`, 7.1.1 doc names, and core-system detection moved out of the 5.0 `skills/` block. |

---

## Privacy invariant

**No default background egress beyond Anthropic.** This is the load-bearing property of the packaging and it is enforced by a test, not just a config default: `tests/egress-test.sh` activates the built payload inside a rootless deny-all network namespace under `strace -e network` (with a positive control) and asserts zero external `connect()`s across activation, the job/check scripts, and Pulse boot. The privacy patches (`f4-*`) are belt-and-suspenders on top of that proof.

`tests/settings-merge-test.sh` covers the install semantics: a virgin install, a merge that never clobbers pre-existing user values, and idempotent re-installs.

---

## Design principles

- **Transparency over runtime patching.** Every upstream modification is an auditable `.patch`. Build-time mutations are documented inline in `default.nix`.
- **Privacy is a test, not a hope.** The egress invariant is asserted against the *built tree*, not the live install.
- **Reproducible, offline, hermetic.** No network at build time beyond the hash-locked source and vendored FOD trees; `--ignore-scripts` keeps postinstall beacons out of the hash.
- **Brand ≠ path.** The rename touches branding and flake outputs only — the config root stays `~/.claude` because Claude Code hardcodes it.
- **Backward-compatible outputs.** `packages.personal-ai-infrastructure` and `nixosModules.pai` are kept as compat aliases so pinned downstream flakes keep resolving across the rename.

---

## Status

**Build green + from-scratch reproducible.** Privacy invariant **proven** by `tests/egress-test.sh`; install semantics covered by `tests/settings-merge-test.sh` (23/23). Both `packages.lifeos` and the `packages.personal-ai-infrastructure` alias build to the same store path; `nixosModules.{lifeos,pai}` both evaluate.

**Sandbox smoke (F7) — done.** `tests/smoke-test.sh` boots Pulse in a rootless net namespace (loopback isolated from any live instance) and asserts `/healthz` → HTTP 200, graceful `SIGTERM` shutdown (~110 ms), and the dashboard — built into the derivation via a hermetic `next build` — serving. The `lifeos` wrapper's launch chain is verified (claude binary + `lifeos.ts` + exec line); the interactive Claude Code launch is deferred (a Claude Code session cannot nest another). Remaining: the final hygiene/determinism pass (F8).

---

## Repository structure

```
lifeos-nix/
├── flake.nix                       # Top-level flake (packages.lifeos + default + compat aliases; nixosModules)
├── pkgs/tools/misc/lifeos/
│   ├── default.nix                 # The Nix derivation, vendored deps, and the `lifeos` wrapper
│   ├── patches/                    # The nine load-bearing patches
│   ├── files/                      # DerivedWatch module, copied into the payload at installPhase
│   └── vendor-locks/               # Injected bun lockfiles + HASHES.txt
├── tests/
│   ├── egress-test.sh              # Privacy invariant (deny-all netns + strace)
│   └── settings-merge-test.sh      # Merge-safe install semantics
├── README.md                       # this file
└── LICENSE                         # AGPL-3.0
```

---

## License

This repository — the Nix expressions, patches, and documentation written here — is licensed under the **GNU Affero General Public License v3.0 only** (AGPL-3.0-only). See [`LICENSE`](LICENSE).

The packaged software, **LifeOS**, is fetched as upstream source at build time and remains under its own license: **MIT**, © Daniel Miessler.

The two licenses are compatible: AGPL-3.0 covers the packaging contribution (this repo), MIT covers the bundled application. End users who interact with a hosted service running lifeos-nix are entitled to the source of the AGPL-licensed packaging contribution under section 13 of AGPL-3.0; LifeOS itself remains under MIT.

---

## Acknowledgements

- Daniel Miessler for [LifeOS](https://github.com/danielmiessler/LifeOS) — the Life OS itself.
- nixpkgs maintainers for the conventions this repo follows.
