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

## Open questions / next experiments

1. **Ordering**: at the boot-time avd_boot (~1.95s) the surviving dmesg
   (ring buffer wrapped, 0–2.2s lost) cannot tell whether AVD_SYS was
   actually ACTIVE. At runtime the domain is re-powered on every
   `/dev/video0` open. Runtime test on the running avd8 system:
   `echo 0x01 > /sys/module/apple_avd/parameters/preinit_mask` then open
   `/dev/video0` → avd_boot reruns stage 1 with AVD_SYS freshly on.
   Decisive for ordering; ~90% likely panics (session dies).
2. **Read vs write fault**: nobody has ever read `0x269000000` on j293 Linux
   (avd6 removed reads pre-emptively; stage 1 always ran first in avd5/6/7).
   If the runtime test still panics, add an avd9 "adsprobe" stage (reads with
   logging, then write+readback) to characterize which access faults.
3. **Clock / perf-state floor**: A1 (`enableDeviceClockWrapper`) is the
   remaining macOS-vs-Linux difference. Clock provider for ID 0x15d not yet
   located in DT/dumps (no nclk node/driver in this tree).
4. **Voltage rails**: AVD-SOC-VNOM/VMAX are parentless virtual devices —
   powering them means an SMC interaction that neither Linux nor m1n1
   performs explicitly. If the SMC doesn't auto-sequence the rail with
   AVD_SYS, the block is clocked-but-undervolted.
