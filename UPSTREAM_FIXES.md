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

## 3. Stale validation path for PAI core skill (`a44df7d`)

The installer validator checked for `skills/PAI/SKILL.md`, which was the correct path in
v2.5 and v3.0. In v4.0.3 the PAI core skill was moved to `PAI/SKILL.md` — the file
exists, but the check looked at the old path and always warned "Not found — clone PAI
repo to enable" on every fresh install.

Fixed by updating the check in `engine/validate.ts` to look at the correct v4.0.3 path
(`PAI/SKILL.md`) and updating the error detail message accordingly.
