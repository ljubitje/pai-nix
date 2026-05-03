# pai-nix

Nix packaging of [Personal AI Infrastructure (PAI)](https://github.com/danielmiessler/Personal_AI_Infrastructure) — Daniel Miessler's Life Operating System for Claude Code — with the patches and build hygiene needed to make it run cleanly on NixOS and other case-sensitive Linux filesystems.

PAI ships with a macOS-first installer (`bash install.sh`) that assumes a writable `~/.claude`, expects to mutate the user's shell rc files, and was authored against a case-insensitive filesystem. pai-nix turns it into a proper Nix derivation: deterministic builds, an immutable store path, no rc-file mutation, and patches for the upstream bugs that surface only on Linux or only when the installer is sandboxed.

---

## Quick install

### NixOS (via flake)

```nix
# flake.nix of your system config
{
  inputs.pai-nix.url = "git+https://codeberg.org/ljubitje/pai-nix";

  outputs = { self, nixpkgs, pai-nix, ... }: {
    nixosConfigurations.<host> = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [ pai-nix.packages.${pkgs.system}.default ];
        })
      ];
    };
  };
}
```

Then `nixos-rebuild switch` and `pai --force-install` once to drop `~/.claude` into your home.

### `nix profile` (any flake-aware Nix)

```bash
nix profile install git+https://codeberg.org/ljubitje/pai-nix
pai --force-install
```

### Try it ephemerally

```bash
nix run git+https://codeberg.org/ljubitje/pai-nix -- --force-install
```

---

## What's inside

- **PAI v5.0.0** — fetched as a fixed source tarball at build time (Daniel Miessler's upstream).
- **17 patches** layered on top, each addressing a specific upstream bug or NixOS-specific incompatibility.
- **A wrapper script** that runs the upstream installer in user space without touching `/etc`, `~/.zshrc`, or `~/.bashrc`. PATH inherits Nix-store binaries (bun, nodejs, git, curl, jq, claude-code).

### Patches

Each patch is a numbered, additive `.patch` file with a multi-paragraph header explaining the bug, RCA, fix scope, verification evidence, and co-existence with prior patches. Hunks are always generated via `diff -u` against the extracted upstream tarball or the post-prior-patches state — never hand-counted (lesson learned the hard way at patch 0005).

| #     | Patch                                       | Upstream                                                                                                  |
| ----- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 0001  | Skip bun management on NixOS                | (NixOS-specific, no upstream issue)                                                                       |
| 0002  | Linux support for Pulse daemon              | (NixOS-specific)                                                                                          |
| 0003  | Pulse `package.json` for dependency resolution | (NixOS-specific)                                                                                       |
| 0004  | NixOS installer fixes                       | (NixOS-specific)                                                                                          |
| 0005  | Validator spurious failures                 | (NixOS-specific — `process.env.NIX_STORE` is build-time-only)                                             |
| 0006  | Pulse case-sensitive path construction      | [#1146](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1146) (Pulse subset)         |
| 0007  | Prompt classifier slash-prefix              | [#1158](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1158)                         |
| 0008  | Installer `paiDir` misnaming                | [#1121](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1121)                         |
| 0009  | Remaining mixed-case path bugs (TOOLS, ALGORITHM) | [#1146](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1146) (supplement)      |
| 0010  | Installer `${HOME}` literal expansion       | [#1124](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1124)                         |
| 0011  | `PAI_SYSTEM_PROMPT.md` placeholder substitution | [#1135](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1135)                     |
| 0012  | Register ISASync / CheckpointPerISC / ToolFailureTracker hooks | [#1134](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1134)      |
| 0013  | `GenerateTelosSummary.ts` parser bugs       | [#1140](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1140)                         |
| 0014  | RepeatDetection state-save timing           | [#1155](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1155) / PR [#1156](https://github.com/danielmiessler/Personal_AI_Infrastructure/pull/1156) |
| 0015  | Root `package.json` for runtime deps        | [#1139](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1139)                         |
| 0016  | `PAI_STATE.json` producer for statusline    | [#1132](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1132)                         |
| 0017  | Migrate observability to `/interview` TELOS schema | [#1153](https://github.com/danielmiessler/Personal_AI_Infrastructure/issues/1153)                  |

---

## Design principles

- **Transparency over runtime patching.** Every modification to upstream is an auditable `.patch` file. No runtime `sed` hacks. Build-time `find -exec rm` mutations are documented inline in `default.nix`.
- **Match upstream conventions.** Patches use git format-patch headers, `diff --git a/Releases/v5.0.0/.claude/...` paths, multi-paragraph explanatory comments, and file/line manifests.
- **Co-existence verified.** Where multiple patches touch the same file (e.g. five patches touch `actions.ts`), each patch header documents the line ranges and confirms non-overlapping hunks.
- **Don't touch the macOS path.** Every Linux-specific fix is gated or platform-agnostic. macOS users see the same patches as a no-op (case-insensitive filesystem makes mixed-case paths resolve identically to caps).
- **Live verification where possible.** Patch headers include synthetic tests, build-output greps, and (for runtime-affecting patches) live API/process probes.

---

## Status

**Working.** `nix build` exit 0, all 17 patches apply cleanly, Pulse daemon reaches `localhost:31337/healthz`, dashboard renders at `/`, `/agents`, `/work`, `/telos`, `/health`, `/security`. Validator reports zero false-failures on a clean install.

**Caveats:**

- `pai --force-install` opens an Electron GUI installer (port 1337). The CLI installer path is gated behind it; some interactive prompts are not yet automatable.
- The `/algorithm` dashboard route returns 404 — `algorithm.html` is genuinely absent from upstream's `next export` output (content gap, not a path bug). Documented in patch 0017's header.
- Cron jobs require network at user-install time for `bun install` to fetch deps. If the install is run offline, runtime cron jobs may error until `bun install` is re-run with network.

---

## Repository structure

```
pai-nix/
├── flake.nix                       # Top-level flake (default + dev shell)
├── pkgs/tools/misc/personal-ai-infrastructure/
│   ├── default.nix                 # The Nix derivation + wrapper script
│   └── patches/
│       ├── 0001-…patch             # Numbered, additive
│       └── …
├── README.md                       # this file
└── LICENSE                         # AGPL-3.0
```

---

## Contributing

Patches welcome — please follow the existing pattern:

1. **Open an upstream issue first** (or reference an existing one). Patches that exist only in pai-nix without an upstream issue make the diff harder to maintain.
2. **Generate hunks via `diff -u`.** Hand-counted `@@` headers will silently break. Workdir under `/tmp/<slug>/{before,after}/`, then `diff -u`, then prepend a git format-patch header.
3. **Document the patch in its header** — bug, RCA, fix scope, files/lines touched, and verification evidence (synthetic test, grep against built output, or live probe where applicable).
4. **Verify co-existence.** Read prior patches' headers and confirm your hunks don't conflict with their line ranges.
5. **One patch per concern, one commit per patch.** Easier to review, easier to bisect, easier to upstream individually.

---

## License

This repository — the Nix expressions, patches, and documentation written here — is licensed under the **GNU Affero General Public License v3.0 only** (AGPL-3.0-only). See [`LICENSE`](LICENSE).

The packaged software, **Personal AI Infrastructure (PAI)**, is fetched as an upstream tarball at build time and remains under its own license: **MIT**, copyright © 2025 Daniel Miessler. See the bundled `LICENSE` file in the upstream tarball.

The two licenses are compatible: AGPL-3.0 covers the packaging contribution (this repo), MIT covers the bundled application. End users who interact with a hosted service running pai-nix are entitled to the source of the AGPL-licensed packaging contribution under section 13 of AGPL-3.0; the bundled PAI itself remains under MIT.

---

## Acknowledgements

- Daniel Miessler for [PAI](https://github.com/danielmiessler/Personal_AI_Infrastructure) — the Life OS itself.
- The PAI community for filing the upstream issues that drove most of these patches.
- nixpkgs maintainers for the conventions this repo follows.
