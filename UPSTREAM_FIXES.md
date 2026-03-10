# Upstream Fixes

Fixes applied to [ljubitje/Personal_AI_Infrastructure](https://github.com/ljubitje/Personal_AI_Infrastructure)
(fork of danielmiessler/Personal_AI_Infrastructure) to support NixOS and fix general bugs.

## 1. Missing Parser/output directory (`e39cece`)

The `Web/output` symlink in the release pointed to a `Parser/output` directory that
didn't exist, causing a broken symlink at install time. Fixed by creating the missing
directory in the release tree.

## 2. Hardcoded `~/.zshrc` in installer completion message (`13983e3`)

Both the GUI (`public/app.js`) and CLI (`cli/display.ts`) completion screens always
displayed `source ~/.zshrc && pai` regardless of the user's shell. The backend
(`engine/actions.ts`) already correctly detected the shell via `$SHELL` and wrote the
alias to the right rc file, but the summary message wasn't using that information.

Fixed by adding `shellRcFile` to `InstallSummary` (computed from `$SHELL`) and using
it in both GUI and CLI output. Now correctly shows `.bashrc`, `.config/fish/config.fish`,
or `.zshrc` depending on the detected shell.

## 3. Missing `skills/PAI/SKILL.md` in v4.0.3 release

The installer validation checks for `skills/PAI/SKILL.md` and warns "Not found — clone
PAI repo to enable" when it's missing. This file existed in v2.5 and v3.0 releases but
was dropped from v4.0.3. The clone fallback (`git clone danielmiessler/PAI.git ~/.claude`)
also doesn't help since the repo root doesn't contain a `skills/PAI/` directory.

**Status:** Not yet fixed.
