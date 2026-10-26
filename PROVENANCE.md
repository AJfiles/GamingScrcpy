# PROVENANCE

What this repository is, where its numbers come from, and what was changed on the
way to publishing. Written so that a claim in the documentation can still be traced
to the artifact that produced it after history is rewritten.

## Code lineage

```
Genymobile/scrcpy  tag v5.0.1  =  a60891aea193d92e7e5c3942700eca63f9d19a5f   (Apache-2.0)
  └─ cd91ccf  GamingScrcpy fork: host-side gaming engine plus the real-time filter panel
     47072dd  overlay: build the panel window on first show, add the stall watchdog
     c1d2a77  overlay: fade the filter panel in over 120 ms, on the OS's terms
     8c7e55c  borderless: re-assert the display geometry past both upstream owners
     f6f931b  telemetry: stop a quiet scene from reading as a dead stream
```

Those five commits are the whole C-side change: **14 files, +6566 / −16** (`git diff
--stat v5.0.1..HEAD` in the scrcpy clone). They were developed in a nested clone and
are published in the same repository as the launcher from this point on.

The application layer (launcher, harnesses, docs) has its own 41 commits, authored by
`GamingCapture <agent@local>` and `GamingScrcpy <agent@local>`. **The implementation
work was performed by an AI agent working for the repository owner**, and the commits
say so rather than being re-attributed.

## History rewrites

| Event | Effect on hashes | Record |
|---|---|---|
| cherry-pick of the 41 app commits onto the scrcpy fork | **new hashes** for all 41; messages and authorship preserved | old→new table below |
| removal of `tools/scrcpy-stock.zip` and `tools/platform-tools.zip` from history | new hashes again for every commit that contained them (the baseline commit only) | see below |
| the five C commits and tag `v5.0.1` | **unchanged** — they are the base, never rewritten | `cd91ccf f6f931b` |

`tools/publish_audit.sh` re-checks that no commit message that cites a hash has been
silently orphaned. Fill in the table when the rewrite happens:

```
<old hash>  ->  <new hash>   <subject>
```

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
