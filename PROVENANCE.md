# PROVENANCE

What this repository is, where its numbers come from, and what was changed on the
way to publishing. Written so that a claim in the documentation can still be traced
to the artifact that produced it after history is rewritten.

## Code lineage

```
Genymobile/scrcpy  tag v5.0.1  =  a60891aea193d92e7e5c3942700eca63f9d19a5f   (Apache-2.0)
  └─ 597ff27  GamingScrcpy fork: host-side gaming engine plus the real-time filter panel
     4240c72  overlay: build the panel window on first show, add the stall watchdog
     93fa33a  overlay: fade the filter panel in over 120 ms, on the OS's terms
     5ec5249  borderless: re-assert the display geometry past both upstream owners
     7d93556  telemetry: stop a quiet scene from reading as a dead stream
     + 49 further commits: the launcher, the harnesses, the documentation
```

Those five commits are the whole C-side change: **14 files, +6566 / −16**
(`git diff --stat v5.0.1..HEAD -- app server`). They were developed in a nested clone
and are published in the same repository as the launcher from this point on.

The application layer (launcher, harnesses, docs) is the rest of the 54 commits over
the base, authored by `GamingCapture <agent@local>` and `GamingScrcpy <agent@local>`.
**The implementation work was performed by an AI agent working for the repository
owner**, and the commits say so rather than being re-attributed.

## How this history was assembled

The C work and the application work lived in two repositories with two different
directory layouts, so neither could be pushed as-is. Each published commit was written
with `git commit-tree`, carrying the **tree of its development commit** and a parent
chain rooted at the real upstream tag. That is why the assembly is checkable rather
than trusted: the diff between two neighbouring published commits equals the diff
between the two development commits it stands for, no merge resolution can quietly
alter content, and the first commit's diff against `v5.0.1` is exactly the 14-file
C-side change above. `git diff v5.0.1..HEAD` is therefore the fork's whole footprint,
and the 3,210 upstream commits up to and including the tag (`git rev-list --count
v5.0.1`) are untouched.

| Step | Effect on this history |
|---|---|
| replay of both development lines onto the tag | every commit here has a **new hash**; messages, authors and author dates are the development ones |
| removal of `tools/scrcpy-stock.zip` (11,264,634 B) and `tools/platform-tools.zip` (8,044,989 B) from every tree | the two vendored archives are unreachable: `git rev-list --objects --all \| grep -cE 'scrcpy-stock\|platform-tools'` is `0` |
| redaction of device identifiers and machine paths in every commit **except** the tip | `<dev-id-1>` `<dev-id-2>` `<repo>` `<home>` `<home8>` tokens, listed below |
| drop of upstream's `.github/workflows/release.yml` | that workflow packages scrcpy alone, so on this tree it would publish an archive without the launcher |

Redaction used neutral tokens instead of the `DEV-*` aliases on purpose: one adb
identifier was announced by two different devices (see the section below), so rewriting
it as a single alias would have attributed a measurement to the wrong phone. The tip's
text was substituted by hand and is what you are reading; the ancestors keep the
original wording with only those literals replaced.

Consequence for anyone citing hashes: the development hashes are not reproducible from
this repository, so no document here cites one. The only hash this file quotes is the
base tag, which is upstream's and unchanged. `tools/publish_audit.sh` checks the
tracked-file set, the local-only paths, the size budget, the identifier/path literals,
the licence and provenance documents and that every script the gate invokes exists — it
does **not** verify hash citations.

## Numbers that were scrubbed, and numbers that were not

Publishing text replaces **identifiers only**, and does it by *model*, not by serial.
`DEV-A` is the device that announced itself as SM-S918B (Samsung Galaxy S23 Ultra,
SDK 34), `DEV-B` the moto g(7) power (SDK 28), `DEV-T` the device that announced itself
as Lenovo TB-9707F. The alias→serial key lives in `out/publish/device_alias_map.txt`
and `out/publish/forbidden_patterns.txt`, both outside the published set on purpose: a
key stored next to the thing it decodes would undo the scrub, and
`tools/publish_audit.sh` fails if a serial literal survives anywhere in the tracked
files (it caught the sentence this paragraph replaces).

**One identifier turned out to be ambiguous, and the scrub is what exposed it.** §5.1l
and the S23 Ultra sections carry the same device identifier, and the saved machine
output explains the collision rather than resolving it: the same adb entry announces
`Lenovo_TB_9707F` in `out/dev/cmp-h264.log` and `SM_S918B` in `out/s23_latency_v4.log`,
so the serial is not a device key on this bench and the **model string the device
reports** is what a measurement is about. Aliases are therefore defined by that label —
`DEV-T` for the tablet-labelled section, `DEV-A` for the SM-S918B sections — and no
number was moved between them. Model names, dates and every measurement stand as they
were; the reasoning is inside §5.1l, not in a footnote nobody reads.

**Nothing measured was altered.** Latencies, frame counts, percentile tables, byte
sizes and `rc=` values stay verbatim from the saved logs, because this project's rule
is that a document quotes a saved log literally. Where a path had to change for the
repo to be buildable elsewhere (`launcher/bin`, `dist/GamingScrcpy`, `out/`), the
change is functional, the harness that owns it was re-run, and the result is recorded
in `BUILD_REPORT.md` under the §5.2.x of that change.

## Verification artifacts this repo points at

| Claim | Evidence |
|---|---|
| gate green | `out/gate_v5_s0.log` — `216 passed, 0 failed`, produced 01:23 with `tools/overlay_test.sh` as of that time |
| packaged layout works | `out/pkg_selftest_v5_final.log` — `PKGSELFTEST OK (165 files, 3 dirs)`; read it **by section**, it also runs `(must FAIL)` control arms on purpose and those print `FAIL` |
| the archive carries the fixed instrument | extracted `tools\overlay_test.sh` is 18,801 B and `cmp`-identical to the committed file; `FRAMES=4000`, `REPS=2` and both paired estimators present (`BUILD_REPORT.md` §5.2.6) |
| deliverable size and identity | 126,572,779 B, both copies, SHA-256 in `SHA256SUMS.txt` at release time |
| known gap | no **full** gate run exists for the final `overlay_test.sh` (written 02:19, after the 01:23 run). Tracked; it is the last thing to clear before the repo goes public. |

## Machine assumptions a stranger will hit

Built and verified on Windows 10 22H2 x64 with MSYS2 UCRT64 on `PATH`, .NET 8 SDK and
Git Bash — see `doc/gaming/PHASE1_AUDIT.md` for the toolchain audit that started this
project, including the fact that the environment was **not** what the original brief
claimed it was. Six harnesses had this machine's absolute paths in live code; those
are derived from the repo root now, and each of those harnesses was re-run after the
change.
