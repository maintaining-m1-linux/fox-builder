# avd8 bisection result 1 — the ADS write itself panics, power is NOT the blocker

Date: 2026-10-05
Kernel: avd8 (`dd43d0587`), j293

## Test results

| mask | result |
|---|---|
| `0x00` | boots. fw upload + readback OK, `run_ctrl rb=1`, `TIMEOUT flag0=00000000` (known baseline: CM3 never starts) |
| `0x01` | **instant boot failure (SError panic)**. Stage 1 is exactly one MMIO write: `0x269000000 = 0xfff` |

The panic source is therefore the single ADS power-register write. All other
apertures (code/SRAM/mbox) read and write fine at the same time.

## pmgr device table decoded (from rev/ioreg_armiodev.txt, 268 devices)

Parsed with `rev/pmgr_parse.py` (48-byte records; validated: AVD_SYS, FPWM1,
MMX, DPA1 all resolve to their known ps offsets `0x410/0x1e0/0x358/0x2f0` —
so ID→address computation is exact).

- pmgr base `0x23b700000`, 57 reg regions; ps-regs table has 13 blocks.
- **avd clock-gates decode correction**: they are `[0x12b, 0x12c, 0x12d]`
  (base64 `KwEAACwBAAAtAQAA`), not `0x12a` as noted earlier.
- All three gates are **VIRTUAL** devices: `AVD-SYS-V`, `AVD-SOC-VNOM`,
  `AVD-SOC-VMAX`. VIRTUAL = no ps register; only parents get powered:
  - `AVD-SYS-V (0x12b) → AVD_SYS (id 0x66, ps@0x23b700410) → MMX (id 0x4f, ps@0x23b700358)`
  - `AVD-SOC-VNOM/VMAX (0x12c/0x12d)` — no parents (SMC-managed voltage rails)
  - dart-avd's gate `AVD-SYS-DART (0x145) → AVD_SYS → MMX`
- Linux genpd already drives AVD_SYS and MMX to ACTIVE(0xf) (dmesg
  `ps_set ... state 0xf ret=0`). **Power-wise Linux already does everything
  m1n1's `pmgr_adt_power_enable()` does for avd.**

Conclusion: the "unpowered ADS block" hypothesis is dead. AVD_SYS+MMX are on
and the write still SErrors.

## m1n1 fw/avd re-check (exact order)

`AVDDevice.__init__`: pmgr_adt_power_enable(avd) → pmgr_adt_power_enable(dart-avd)
→ dart.initialize(). `boot()`: ADS 0xfff → dart masks → **CODE clear
0x1080000 (missing from our stage 3)** → SRAM clear → wrap init → DMA tunables.
m1n1's sequence was proven only on j274; macOS is the only reference proven on
j293.

## macOS (j293) order per rev/DISASM_INIT_PATH.md

1. `enableDeviceClockWrapper`: AppleARMIODevice **clock gate + pmgr
   `set_perf_state_floor`** — before any AVD MMIO. This is the known Linux gap
   (no clk driver for ID 0x15d, no perf-state code at all).
2. `DevicePwrOn` 0x1000000←0xfff.
3. fw load → M3 start → DeviceInit/wrap → ADS valid poll (mask 0x7f0).

## Results / next experiments

1. **DONE — boot-time ordering ruled out.** The avd9 mask=0x00 boot log
   (log_buf_len=8M) shows `ps_set: avd_sys state 0xf` ~20ms *before* the
   avd_boot attempt at 1.93s, i.e. AVD_SYS+MMX were provably ACTIVE during
   the mask=0x01 panic.  Not a power-ordering problem.
2. **DONE — adsprobe (0x40): hard hang, not a panic.** The very first ADS
   read (`readl(0x269002010)`) stalled the bus forever: no backtrace is
   possible, and because `quiet` was on the cmdline not even the AVDBG
   banner reached the screen — the machine sat at the GRUB "Loading initial
   ramdisk..." text.  The hung boot left no journal entry (journald starts
   after the ~1.9s hang point; verified via `journalctl --list-boots`), no
   pstore (not configured), and the ring buffer died with the reset.  The
   ADS aperture is completely unreachable on j293 (reads don't fault, they
   hang) even with AVD_SYS+MMX ACTIVE — clock (ID 0x15d, nobody enables
   it), ARST reset (function register below), or the SMC-managed rails.
3. **pmgr function registers (read-only probe from a live boot):** Apple
   function properties decode as `<u32 offset>, <4CC type>, [args]` with the
   register at `pmgr_base + offset*4`.  `function-avd_reset = [0x8b "ARST" 0x66]`
   → pmgr+0x22c, which reads back 0.  The ARST write semantics are unknown
   (the arg 0x66 is a command value, not a bit index), so do NOT poke it
   blindly.  Wide-area dump: 0x220=ff 0x228=2ff 0x22c=0 0x230=2ff 0x238=300.
4. **NEXT — mask=0x3e (all preinit except the ADS write):** tests whether
   the rest of the sequence is safe and whether flag0 flips without ADS.
   The GRUB test entry now runs without `quiet` so a hang leaves the last
   AVDBG line on the console — photograph the screen in that case.
5. **Voltage rails**: AVD-SOC-VNOM/VMAX are parentless virtual devices —
   powering them means an SMC interaction that neither Linux nor m1n1
   performs explicitly. If the SMC doesn't auto-sequence the rail with
   AVD_SYS, the block is clocked-but-undervolted.
6. Runtime test via `/sys/module/apple_avd/parameters/preinit_mask` + a
   `/dev/video0` open remains available but is moot for the panic question
   (ordering ruled out by experiment 1).
