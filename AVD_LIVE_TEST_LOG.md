# AVD j293 live module test log — 2026-10-02 evening

Live kernel-module testing session against the stuck AVD bring-up on
MacBookPro17,1 (j293, t8103). Companion to `research-avd-bringup.md`
(static bring-up log) and `fox-builder-macos/LINUX_HANDOFF.md` (macOS
side). Everything here happened on kernel
`7.1.13-fairydust-avd3-g08bd715e05bc` unless noted.

## Infrastructure built (persists, reusable)

- `~/linux-m1-avd-wt` — git worktree of `~/linux-m1` at `08bd715e0`
  (the running kernel's commit), configured with
  `/boot/config-7.1.13-fairydust-avd3-g08bd715e05bc` (vermagic-identical
  module builds). Main tree's dirty AVDBG WIP preserved untouched;
  backed up to `patches/avd-dbg3-instrumentation.patch`.
- Test-only debugfs hooks added to `drivers/media/platform/apple/avd/avd-drv.c`
  (marked "TEST-ONLY … Not for upstream"):
  - `avd_dbg/pmgr_read` — read ps_avd_sys (pmgr 0x23b700410)
  - `avd_dbg/force_power` — write PS_TARGET=0xf (mirror of genpd power-on)
  - `avd_dbg/do_boot` — call `avd_boot()` directly
  - Purpose: bypass runtime PM entirely (see below).
- `~/avd-test/test-module.sh` — staged rmmod→insmod→trigger with
  `~/avd-test/progress` markers + `sync` after every step (marker survives
  a hang; attributes the crash to the exact stage).
- Baseline module build (`~/avd-test/baseline/apple-avd-dbg.ko`) builds and
  loads cleanly; the unmodified driver probes fine.

## Key software finding: sticky runtime_error

`drivers/base/power/runtime.c`: `power.runtime_error` is only cleared by
`pm_runtime_init()` (device registration) or `__pm_runtime_set_status()`
(driver-only). **No userspace clear exists.** One failed `avd_boot`
(-110) poisons every later resume with -EINVAL forever (matches the
documented "-22 red herring"). Consequence: any test loop must reach
`avd_boot` outside runtime PM (the debugfs hooks) or reboot between
attempts. The failed boot also happens **automatically at every boot**
(something resumes the device early), so the device is born poisoned on
every boot.

## Crash event #1 (~20:56) — during end-to-end test

- First end-to-end run (older combined `force_boot` hook): rmmod ok →
  insmod of test module → trigger → **hard hang**.
- Evidence: previous boot's journal ends 20:55:59 with
  `apple_avd: loading out-of-tree module taints kernel.` — no Oops/BUG,
  no AVDBG lines (script had cleared the ring with `dmesg -C`; the empty
  `last-test.log` shows the crash landed before userspace could flush
  page cache). Downtime ~4 min; booted again 21:00:14 by itself.
- Interpretation: hang occurred inside the insmod→pmgr-poke→`avd_boot`
  window. Most likely culprit: **CM3 start (RUN_CTRL) without macOS-style
  clock/reset init wedges the SoC** — exactly what the macOS-init
  hypothesis predicts.

## Crash event #2 (~21:05–21:10) — IDLE, no test running

- The 21:00 boot: normal boot-time AVD failure at 21:00:14 (same
  signature: `hw 0000`, TIMEOUT, flag0=0, mbox varying), my read-only
  diagnostics at ~21:02, journal's last line 21:05:26 (PackageKit
  get-updates — routine userspace). System silent-crashed sometime
  21:05–21:10 with **zero test activity** (no progress markers — the
  staged script never ran).
- Decisive comparison: earlier the same day this exact kernel ran
  **11 h 51 min** (07:45 boot) with the identical boot-time AVD failures.
  Boot-time failure alone is stable. The instability began **after crash
  #1**.
- Conclusion: **the 20:56 test left the AVD block / its clock/reset state
  wedged in a way that survives warm reboots**, and the wedged state
  kills the SoC at random while idle. pmgr always-on-domain state is the
  prime suspect for what persists.
- Corollary: the macOS init sequence (clock gates → ARST → fast clock →
  ADS wait) is not optional polish. Starting the CM3 unprepared is unsafe
  on this silicon and can leave the machine unstable across reboots.

## Current state at documentation time

- Boot at 21:10:57 (third since the test), again showing the standard
  boot-time AVD failure (`mbox=fe48eeda`). Stability of this boot unknown
  — treat the machine as flaky until a cold reset.

## Safety rules going forward (binding for this project)

1. **No live AVD module tests** until
   `fox-builder-macos/rev/DISASM_INIT_PATH.md` defines the exact macOS
   init sequence (ordered MMIO writes) and the patch implements it fully.
2. Before any future test: **cold boot** (full power-off, ≥30 s, power
   on) — warm reboots do not clear the wedged state. User saves all work;
   a spontaneous reboot is an accepted outcome.
3. One test attempt per boot; staged script with markers; if stage
   attribution shows the hang at `do_boot` again, stop and go back to
   static analysis.
4. If the machine keeps crashing on its own: boot **macOS once** (its
   AppleAVD init reinitializes the block), or blacklist `apple_avd`
   (`/etc/modprobe.d/blacklist-avd.conf`) to stop boot-time probing.

## Pending

- ~~Disassembly subagent~~ **DONE** — `fox-builder-macos/rev/DISASM_INIT_PATH.md`:
  ordered MMIO write list + power sequence + top-3 Linux-missing candidates.
- Worktree debugfs-hook diff is uncommitted in `~/linux-m1-avd-wt`
  (intentionally; test-only code).

## Patch v1 "macos-init" (2026-10-02 ~21:20, built OK)

`~/linux-m1-avd-wt` `avd-hw.c`, guarded to `revision == 3` (t8103 only;
rev4+ chips keep the upstream path). Implements, in `avd_boot()`:

- **pre-boot** (`avd_t8103_macos_pre_boot`): disableMCPUE preamble
  (RUN_CTRL←0xe, FLAG0_CLR←1, +0x10←0, IRQ_EN←0); **DevicePwrOn**
  wrap `0x269000000`←0xfff with before/after readback prints.
- **boot**: enableMCPUE order per kext — +0x50←1, +0x68←1, +0x5c←1,
  +0x74←1, +0x4c←0 — then Linux's own +0x48←NOT_EMPTY and RUN_CTRL←1.
- **post-boot** (`avd_t8103_macos_post_boot`, success path only):
  initAvdWrap `0x269070024`←0x26907000, C2 `0x269070000`←0,
  C1 `0x269140018`←1, DeviceInit C3–C8 at `0x269100000`+{0x4064←3,
  0xcc90/0xcc94/0xccd0/0xccd4/0xcac8←0xffffffff}, then ADS poll at
  `0x269002010` for `(val&0x7f0)==0x7f0` (5 s, diagnostic).
- timeout path now also one-shot-reads ADS status.

Physical mapping anchors (both verified): fw window kext 0x1080000 ==
Linux `code` resource 0x269080000; B15 self-reference value 0x26907000 ==
0x269070000>>4. mbox low offsets (+0x08/+0x48/+0x5c/+0x90…) match
`avd-regs.h` exactly, so Linux resource bases are used for all mbox/code
accesses; only wrap/aux/ctrl2/ads use new hardcoded phys maps.

Artifact: `~/avd-test/patched/apple-avd-macos-init.ko` (with the debugfs
`pmgr_read`/`force_power`/`do_boot` hooks still present; `do_boot` runs
the new sequence).

### Deferred (if v1 fails)

- Candidate 2 (clocks): pmgr perf-state floor / clock gates 0x15d,
  0x12a/0x12c/0x12d — needs pmgr function/gate pokes.
- Candidate 2b: order sensitivity of DevicePwrOn vs fw load.

### Live test protocol (when user approves, after a cold boot)

1. `sudo ~/avd-test/test-module.sh ~/avd-test/patched/apple-avd-macos-init.ko`
   (staged markers; do NOT touch `do_boot` stage manually unless scripted
   stages 1–3 survive).
2. Success = `AVDBG boot: OK` + FLAG0=1 + `/dev/video0` decode smoke test.
3. Hang/reboot → read `~/avd-test/progress` to attribute the stage,
   check `journalctl -k -b -1`, update this doc.
