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

## Next candidates

1. **Vendor firmware refresh via macOS** (strongest): boot macOS, apply
   any SMC/firmware updates, then re-run the Asahi installer's firmware
   collection (or refresh all_firmware.tar.gz) and regenerate m1n1's
   boot.bin. The boot log shows `apple-pmgr ... always-on domain msg is
   not on at boot`, i.e. the pmgr messaging was unhealthy from the start
   — consistent with stale SMC-side firmware.
2. Update m1n1 to latest.
3. Find another j293 owner with working AVD to compare register dumps
   (esp. bit 13 and the `hw version` read).
