# Linux-side continuation — macOS AppleAVD init reversing handoff (EN)

Hand this file verbatim (as a prompt) to the agent on the Linux side. All
data collection that can only be done on macOS is complete; the disassembly
and comparison work continues here.

## Background (why this task)

- Machine: MacBook Pro 13" M1 2020 (MacBookPro17,1 / J293 / t8103) running
  Asahi-derived fairydust kernels. The same stack works for AVD hardware
  decoding on a Mac mini M1 (j274), but on this j293 the `apple-avd` driver's
  `avd_boot()` always times out (`failed to boot` — the CM3 never sets FLAG0).
  Details: `research-avd-bringup.md` in the project root.
- Hypothesis: macOS's AppleAVD init performs a clock/power/reset step that the
  Linux driver does not. Reverse the macOS 15.7.1 (24G231) AppleAVD.kext
  (v865) to find that sequence and diff it against the Linux driver.
- macOS-side results (already done): `AVD_MACOS_FINDINGS.md` + artifacts in
  `rev/`. The firmware binary is not present anywhere on the macOS disk
  (ioreg shows size 34676, version 0x89255e13 — the boot chain supplies it
  out of band), so the comparison target is the kext code.

## Input files (under `rev/` in this zip)

- `AppleAVD.__TEXT_EXEC.bin` — code segment (flat, 0x59abc bytes, vmaddr
  **0xfffffe0009226370**). `__TEXT.bin` (0xe44f8 bytes, base
  0xfffffe000715a500 — os_log/cstring/const), `__DATA{,_CONST}.bin` (small).
- `AppleAVD.slim.map.txt` — per-segment vmaddr/size + an objdump example.
- `avd_symbols.txt` — 3710 symbols (addr + mangled name).
  `avd_key_functions.txt` — 830 __TEXT_EXEC functions.
- `avd_kext_strings.txt` — 2281 kext-local strings.
- `avd_kernel_log.txt` — boot-time AppleAVD kernel log. Chip family is
  **Viola** (`CAvdApCommViola(): map frameParams`), `m_coreCount: 1,
  avdTier: 2`, ADS status 0x0 → 0x7f0.
- `ioreg_avd_decoded.txt` — decoded DT properties: clock-ids [0x15d],
  clock/power-gates [0x12a, 0x12c, 0x12d], pmgr function **ARST**
  (function-avd_reset), IODeviceMemory **0x269010000+0x4000** (note: differs
  from the Linux map's mbox 0x269098000 / ctrl 0x269100000 — reconcile with
  the avd node reg in Asahi `t8103.dtsi`), interrupts [0x21c, 0x21d].

## Task (deliverable)

Disassemble the functions below with `aarch64-linux-gnu-objdump` (or rizin)
and extract **every MMIO store (register offset : value) in the init/power-on
path, in order**, then compare with the Linux driver sequence (baseline,
drivers/media/platform/apple/apple-avd.c + avd-regs.h):

| region | offset | action |
|---|---|---|
| mbox 0x269098000 | +0x48 | IRQ enable |
| mbox | +0x5c | MBOX1 enable |
| mbox | +0x08 | RUN_CTRL=1 |
| mbox | +0x90 | (fw FLAG0 ack) |

Writes macOS performs **before** RUN_CTRL (clock gates, ADS polling, pmgr
ARST, ctrl-window writes, fast clock, ...) are the answer candidates.

### Primary disassembly targets (vmaddrs, relative to AppleAVD.__TEXT_EXEC.bin)

1. `CAvdM3Mcpu::enableMCPUE()` 0x9226458 / `disableMCPUE()` 0x92263f0
   — coprocessor power switch. (file offset = vmaddr − 0xfffffe0009226370)
2. `CAvdM3Mcpu::WaitForM3Boot()` 0x9226510 (0x260 B) — which register is
   polled and what value is expected (FLAG0 = mbox +0x90?).
3. `CAvdM3Mcpu::loadFirmwareImage()` 0x9226770 — where the image is copied
   to (SRAM window?), header handling.
4. `AppleAVD::setPowerStateOn(u32)` 0x924a660 — core of the power sequence.
   Record whether the order is clock-enable → reset-deassert → RUN_CTRL.
5. `AppleAVD::enableFastClockInternal(u32)` 0x924b18c /
   `disableFastClockInternal` 0x924b318 — a concept with no Linux equivalent.
   Identify the register touched (pmgr? clkgen? DDOMAIN?).
6. `AppleAVD::enableDeviceClockWrapper(AppleARMIODevice*, u32, u32, bool)`
   0x9243d74 — how DT clock-ids/gates (0x15d, 0x12a/0x12c/0x12d) are used.
7. `CAvdWrapCtrlViola::PwmReset()` 0x92383e8 (plus the `CAvdWrapCtrl*::
   PwmReset` family) — what exactly "pwm reset" is (register write? invoking
   the ARST pmgr function?).
8. `AppleAVD::HardReset` 0x924593c / `SoftReset` 0x9245748 /
   `waitValidADSStatus` 0x924643c — the ADS status block MMIO base and the
   valid mask (0x7f0).

Cross-referencing function pointers/object constants in `__DATA_CONST` with
the os_log format strings in `__TEXT` recovers the CAvdRegisterIO base
mapping and makes offset interpretation much easier.

### Notes / tips

- The binary is arm64e, but the init path should disassemble as standard A64.
- The kext takes physical addresses from the DT at runtime, so constant
  scanning cannot recover offsets — only `str/ldr` immediates in the
  disassembly are authoritative.
- pmgr function calls are identified by the ApplePMGR function-call pattern
  (references the "ARST" name string). Compare with m1n1's `pmgr.py` /
  `t8103.dtsi` to find the ARST bit position (and check whether the Linux
  `apple_pmgr_ps_power_on` already handles that bit — if so, reset is not
  the missing piece).
- Deliverable format: fill in the empty items in §6 of
  `AVD_MACOS_FINDINGS.md` (ordered MMIO write list, disassembly snippets
  around each NEW write, power sequencing order), plus a draft fairydust
  kernel patch (diff) if a candidate step is found.

### Do not

- Redistribute Apple binaries/artifacts externally (this zip is for the
  owner's local hand-carry only).
- No ESP/NVRAM changes on the j293 machine — analysis only.
