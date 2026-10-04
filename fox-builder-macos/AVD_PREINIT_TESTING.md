# avd8 — per-boot preinit stage isolation on j293

Date: 2026-10-04
Kernel: `7.1.13-fairydust` branch, commit `dd43d0587`, LOCALVERSION `-fairydust-avd8`

## Problem

avd5/6/7 (linux-m1 commits `78fcb6d28`, `93b5488f9`, `8d837d0db`) enabled the
full t8103 preinit sequence derived from the macOS AppleAVD.kext disassembly
and the m1n1 `fw/avd` bring-up RE. All three panic at boot on j293 with an
SError before userspace, so the kernel log never reaches disk and the
faulting stage is unknown. avd6 removed the ADS reads (guessed culprit) —
panic persisted, so the source is on the write side or is asynchronous
after hardware enable.

## What avd8 changes

Every preinit stage is individually selectable at boot time; no rebuild is
needed to bisect:

| mask bit | stage |
|---|---|
| `0x01` | ADS block power write (`0x269000000 = 0xfff`) |
| `0x02` | DART-AVD init masks |
| `0x04` | SRAM clear (`memset_io`, 0xc000 bytes) |
| `0x08` | wrap ctrl init table (10 regs) |
| `0x10` | DMA tunables table (~120 regs) |
| `0x20` | pmgr ps dump (read-only diagnostic) |

Default `0` runs **no** preinit — avd4-equivalent (MCPUE boot sequence
only), always safe to boot.

The driver is now **built in** (`CONFIG_VIDEO_APPLE_AVD=y`, was `=m`) so the
kernel command line reaches `module_param`. AVD firmware must therefore be
in the initramfs (probe runs `request_firmware()` before the rootfs is
mounted); the hook at `initramfs-hooks/apple-avd` in this repo is installed
as `/etc/initramfs-tools/hooks/apple-avd` and copies
`/usr/lib/firmware/apple/avd-fw-*.bin` (t8103 uses `avd-fw-v2-t0.bin`,
49152 bytes — matches the dmesg `fw 49152 bytes` line).

## Test procedure (per boot, no rebuild)

1. Boot into GRUB, highlight the avd8 entry
   (*Advanced options → 7.1.13-fairydust-avd8-g<hash>*), press `e`.
2. Append to the `linux` line:
   ```
   apple_avd.preinit_mask=0xNN
   ```
3. `Ctrl-X` (or F10) to boot.
4. Capture the result:
   - clean boot: `sudo dmesg | grep -E 'AVDBG|apple-avd|avd '` from the
     running system, **and note whether the boot ends in**
     `AVDBG boot: OK` **or** `TIMEOUT flag0=...`.
   - panic: photograph the screen; the **last `AVDBG` line** is the
     faulting register (`AVDBG wr: [addr] = val` is printed *before* each
     write). Also report the `mask=0x..` banner line to rule out typos.
5. Report back: mask used, outcome (OK / TIMEOUT / panic), last AVDBG line.

## Bisection plan

Double the mask until panic, then narrow within the newly added stage(s):

```
0x01 → 0x03 → 0x07 → 0x0f → 0x1f → 0x3f
```

The stage that flips clean→panic contains the SError source. Within a bad
table stage, the per-write log already identifies the exact register.

Interpretation guide:

- `0x01` panics → the ADS block must be powered through the pmgr first;
  gate activation becomes the next task (see below).
- everything up to `0x3f` boots but `flag0` still times out → the writes
  alone are insufficient: the ADT clock-gates for `avd`/`dart-avd`
  (ioreg clock-gates `[0x12a,0x12c,0x12d]`, clock-ids `[0x15d]`) need to
  be driven ACTIVE via the pmgr power-state registers before the preinit
  (m1n1 `pmgr_adt_power_enable()` equivalent, currently missing upstream).
- `0x3f` boots and `flag0 == 1` → boot succeeded; proceed to the FFmpeg
  `v4l2request` decode test and Firefox `media.hardware-video-decoding`.

## Safety invariants

- GRUB default stays on avd4; avd8 is entered only via manual menu edit.
- The `7.0.13-fairydust` backup kernel in /boot is never removed.
- Do not delete kernels from /boot while testing; the partition is small
  (1.5G) — plan space before adding avd9+.

## Gotchas learned on hardware

- **Ring buffer wrap**: the PM debug instrumentation (commit `05e0fb8a3`)
  dump_stacks on every genpd/ps_set operation and floods the default dmesg
  buffer within seconds; the AVDBG preinit/boot lines from the first ~2s of
  boot were evicted before they could be read.  Fixed system-wide on
  2026-10-04 by adding `log_buf_len=8M` to
  `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` (applies to every
  kernel, including avd4).  If lines are still missing, pass
  `log_buf_len=16M` manually for that boot.
- **avd7 was removed** on 2026-10-04 (it panicked at boot, useless);
  /boot holds avd4 (GRUB default), avd8, and the 7.0.13 backup.
