# AVD hardware decode bring-up — investigation log

Target: Apple MacBook Pro 13" M1 2020 (j293, t8103), custom
"maintaining-m1-linux" fairydust kernels, Debian trixie.

## Goal

Hardware H.264/HEVC/VP9 decode via the in-kernel `apple-avd` driver for
local playback (Firefox web video is out of scope — see README; Gecko's
Linux V4L2 path is stateful-m2m only, while apple-avd is stateless).

## Stack that was built

1. `setup-avd-fw` — builds Asahi's open-source (MIT) AVD coprocessor
   firmware from AsahiLinux/avd-fw into `/lib/firmware/apple/` and embeds
   it into the kernel image (`CONFIG_EXTRA_FIRMWARE`) so the built-in
   driver can find it before rootfs is mounted.
2. fairydust kernel `7.1.13-fairydust-avd3`:
   - `CONFIG_VIDEO_APPLE_AVD=m` (module — built-in probing races early
     boot; see git log), load ordered before the camera ISP via
     `softdep apple-isp pre: apple-avd` in `/etc/modprobe.d/apple-avd-order.conf`
   - frigate-asahi decode-stability patch series (applied/adapted)
3. `build-ffmpeg-avd` — Kwiboo's `v4l2-request` ffmpeg (pinned b57fbbe +
   patches 0001/0002 from frigate-asahi), the Annex-B → stateless
   translation layer.

## Symptom

`avd_boot()` firmware handshake times out on this machine on **every**
kernel/config combination tested:

```
avd 269080000.avd: failed to boot        # FLAG0 never set by the CM3
```

Consequences observed downstream (all secondary):
- `pm_runtime_resume_and_get()` later returns **-EINVAL (-22)** — this is
  NOT a power-domain error. `rpm_resume()` (drivers/base/power/runtime.c)
  returns a hardcoded -EINVAL whenever a sticky `power.runtime_error` is
  set. The original error recorded by `rpm_callback()` is the boot
  timeout (-110). Instrumented in commit "DEBUG: instrument PM error
  recording..." (fairydust branch).
- ffmpeg `-hwaccel v4l2request` stalls (requests never complete; reinit
  returns EBUSY). GStreamer `v4l2slh264dec` fails during userspace
  negotiation.

## What was ruled out (with evidence)

| Suspect | Evidence |
|---|---|
| Firmware image | Same-size binary as the reference build; fails identically |
| 7.1.6 → 7.1.13 regression | **Control test**: a `7.1.6-g716test` kernel (Asahi tag `asahi-7.1.6-1` + frigate patches, same config) fails to boot the FW **on this machine** with the identical signature |
| DT (avd node `ps_avd_sys`, pmgr dtsi) | `git diff asahi-7.1.6-1..<fairydust>` → identical |
| pmgr-pwrstate driver (`pmdomain/apple`) | identical between 7.1.6/7.1.13; contains no EINVAL |
| soc/apple (rtkit, smc, aop) | identical between 7.1.6/7.1.13 |
| avd driver boot/PM code | identical (probe/pm_ops/boot); only format/slot paths rewritten |
| Kernel config (PM options) | identical to Debian 6.17.9-asahi |
| Timing / probe order | True late module load (159 s, system fully up) fails identically |
| Power domain path | avd runtime-resume callback executes ⇒ genpd power_on succeeded ⇒ the -22 is only the sticky-recorded boot timeout |

## Working reference

aquarat/frigate-asahi reports AVD hw decode working on a **Mac mini M1
(j274)** with Fedora kernel 7.1.6-400 + the same firmware binary. The
failure on this j293 unit is therefore machine/environment-specific.

## j293-specific debugging (this machine)

Instrumentation commits on the fairydust branch (AVDBG prints):
- `avd_boot()`: fw size, hw version read, FLAG0/mbox at timeout
- `rpm_callback()` (runtime.c): print + dump_stack when power.runtime_error
  is recorded
- `rpm_resume()`: print on the sticky-error branch
- `_genpd_power_on()`, `apple_pmgr_ps_power_on()`, `apple_pmgr_ps_set()`:
  result + register dump

Findings:

1. The recurring **-EINVAL (-22) from pm_runtime_resume_and_get() is a
   red herring**: `rpm_resume()` (drivers/base/power/runtime.c) returns a
   hardcoded -EINVAL whenever a sticky `power.runtime_error` is set. The
   original error is the **firmware boot timeout (-110)**, recorded once
   by `rpm_callback()`; every later resume just returns -22.
2. The **power domain is fully functional**: `apple_pmgr_ps_set()` trace
   shows `avd_sys` reaching PS_ACTUAL=0xf (ACTIVE) on resume and 0 at
   idle, `power_on` ret=0. genpd resume succeeds before the driver
   callback runs.
3. Primary failure unchanged: after the domain is ACTIVE, the CM3
   firmware never sets FLAG0 within 10 ms. The `ctrl` region reads
   hw version 0x0000; the mbox registers return varying non-zero values.
4. Secondary (noise): under rapid open/close cycling, suspend-side
   `ps_set(PWRGATE)` occasionally times out (100 µs poll) and records
   -110 again. Bit 13 (0x2000) of the avd_sys pmgr register is set at
   all times; meaning unknown (not defined in the Linux driver).
5. `asahi-fwupdate` re-extraction is a no-op: the ESP capture
   (`all_firmware.tar.gz`, 2026-09-25) predates AVF and is the only
   source. macOS partitions still exist on nvme0n1 (p1-p3), so a
   firmware refresh is possible by booting macOS and re-running
   collection.
6. m1n1 is a hand-installed custom build (2026-09-27) at
   /usr/local/lib/m1n1/m1n1.bin; the dpkg m1n1 is 1.4.21-3.

## Boot-time forensics (dbg3 kernel, definitive)

A kernel with `AVDBG boot` prints + a modified avd-fw that writes the
FLAG0 ack as its *first instruction* produced:

```
fw[0..2]=000007c0 00000001 00000838  rb=000007c0 00000001 00000838  rst=0
run_ctrl rb=00000001
TIMEOUT flag0=00000000
```

i.e. the firmware image lands in SRAM byte-identical (readback
verified), the reset framework reports deasserted, RUN_CTRL writes and
reads back — and the CM3 still never executes the first instruction.
Every software-side prerequisite checked out; the coprocessor core is
not starting. No unexplored CM3 clock/enable register exists in either
the driver's or the firmware's register map.

Conclusion: on this j293 unit the AVD coprocessor does not start under
the Linux stack for a reason not observable from driver/firmware level
(candidates: a clock/provisioning step performed by macOS's AppleAVD
init or the SMC that this stack doesn't replicate; or a board-level
difference vs the working j274 reference). Next progress requires
either a working j293 comparison dump, or reverse-engineering macOS's
AVD init sequence.

## Firmware baseline (fixed)

Captured at install time (2026-09-25) from the machine's own ESP:
**macOS 13.5, build 22G74, RestoreVersion 22.7.74.0.0** (Ventura-era).
This is the supported reference for the stack below — work against this
baseline and document deviations; do not require firmware upgrades.

- m1n1: hand-installed custom build (2026-09-27) at
  /usr/local/lib/m1n1/m1n1.bin; dpkg has 1.4.21-3 (unused).
- boot.bin embeds the vendorfw cpio from the baseline above.

## Next candidates

1. **In-branch analysis of the avd-fw boot requirements** (active):
   read the firmware's startup sequence against `avd-regs.h` to find any
   clock/enable poke the driver must perform before RUN on this silicon.
2. Compare register dumps (pmgr 0x400/0x410, ctrl hw-version read) with
   a working machine of any model — held in-branch until data exists.
3. Update m1n1 to latest (cheap, minor hope).

## Linux-side baseline for the macOS diff (2026-10-02, worktree @08bd715e0)

Facts established from `~/linux-m1-avd-wt` (t8103, driver =
drivers/media/platform/apple/avd):

- **MMIO map** (t8103.dtsi `avd@268000000`): code 0x269080000+0xc000,
  sram 0x26908c000+0xc000, mbox 0x269098000+0x4000, ctrl 0x269100000+0x10000.
  IRQs AIC 540/541 = ioreg interrupts [0x21c,0x21d] ✓.
- **Boot sequence** (`avd_boot`, avd-hw.c): memcpy fw→code; mbox+0x5c=ENABLE;
  mbox+0x48=NOT_EMPTY; mbox+0x08 RUN_CTRL=1; poll mbox+0x90==1 (10 ms).
  No reset assert/deassert here — `avd->rstc` is only used by the watchdog
  path (`avd_reset`). No clocks. No ADS interaction.
- **Reset** (`resets = <&ps_avd_sys>`): pmgr-pwrstate toggles the avd_sys PS
  register RESET(bit31) + DEV_DISABLE(bit10). This is the PS-register reset,
  NOT the macOS `function-avd_reset` → pmgr function **"ARST"** mechanism,
  for which Linux has no driver at all (no `function-*` support anywhere).
- **Power**: ps_avd_sys = pmgr 0x23b700000 + 0x410; PS_TARGET(3:0),
  PS_ACTUAL(7:4); ACTIVE=0xf reached per earlier traces. **Bit13 (0x2000) is
  set at all times and is not defined/used in the Linux driver** — candidate
  meaning: clock-gate/ISO hint; check against macOS disasm.
- **macOS-only mechanisms to look for in the kext disasm**: ARST pmgr
  function call, clock-ids [0x15d] + gates [0x12a,0x12c,0x12d] enables,
  fast-clock switch, ADS valid (0x7f0) wait before FW RUN, PwmReset
  (DT-conditional per kext string "No avd pwm reset, pls check device tree
  settings!!" — j293 DT has the properties; j274's may lack them, which
  would explain why j274 boots without any of this).

## Live module testing — STOPPED, see AVD_LIVE_TEST_LOG.md

2026-10-02 evening: built a staged debugfs test harness in a worktree,
ran one end-to-end test → **hard hang + spontaneous reboot**; the next
boot then crashed again while fully idle. Evidence points to the test
leaving retained AVD/SoC state that survives warm reboots. Live tests are
frozen until the kext disasm yields the exact macOS init sequence. Full
timeline, infrastructure, and safety rules: **`AVD_LIVE_TEST_LOG.md`**.
