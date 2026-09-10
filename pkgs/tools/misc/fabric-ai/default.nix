# fabric-ai, patched so an explicit input source beats an inherited stdin.
#
# Upstream drains fd 0 to EOF whenever stdin is not a character device, even when -y
# (YouTube), -u (scrape URL) or -q already said where the input comes from. Interactive
# use never hits it: a tty IS a char device, so the branch is skipped. Every programmatic
# caller does, and the failure is silent, indefinite, and identical with or without a
# config file: zero bytes on stdout AND stderr, forever. Measured 2026-09-10 on 1.4.459.
#
# Patched at the cause rather than at each call site because LifeOS documents bare
# `fabric -y URL` in six skills; a per-caller `stdio: ignore` or a `< /dev/null` wrapper
# would fix the callers we happened to look at and leave the rest, and the wrapper would
# additionally amputate fabric's primary interface (`cat notes.md | fabric -p summarize`).
# The patch keeps that interface exactly as it was: with no source flag, stdin is still read.
#
# vendorHash is untouched on purpose: the patch edits one file under internal/ and neither
# go.mod nor go.sum, so the vendored module set is byte-identical. If a future patch here
# touches either, expect a vendorHash mismatch and re-capture it from the failure.
{ fabric-ai }:

fabric-ai.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./f-fabric-stdin-precedence.patch
  ];
})
