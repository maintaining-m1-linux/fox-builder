# AppleAVD.kext (v865, macOS 15.7.1, arm64e) — Reconstructing the MMIO sequence of the AVD CM3 init/power-on path

> **ERRATA (2026-10-05): Some slot guesses and the A2 interpretation were wrong. The runtime
> wrap-ctrl is CAvdWrapCtrlViola (not the base class); A2 is not a 0x1000000<-0xfff write but a
> power-state=2 request. The full corrections follow AVD_POWER_RE.md.**


Target: MacBook Pro 13" M1 2020 (j293, t8103, Viola). Disassembly of `AppleAVD.__TEXT_EXEC.bin` (base 0xfffffe0009226370),
`AppleAVD.__TEXT.bin` (base 0xfffffe000715a500), `AppleAVD.__DATA_CONST.bin` (base 0xfffffe0007e160d8).
Tool: `aarch64-linux-gnu-objdump -D -b binary -m aarch64`. vtable pointer recovery rule: stored value (low 32 bits) + 0x7004000 = actual TEXT_EXEC address
(Mach-O chained-fixup encoding, verified against CAvdMcpu::start etc.).

---

## 0. Summary (conclusions first)

Unlike the 4 lines of Linux `apple-avd`'s `avd_boot()`, the macOS AVD power-up is a 3-stage structure:

1. **Clock/perf-state**: `setPowerStateOn` → `enableDeviceClockWrapper` → AppleARMIODevice clock gate + **function-set_perf_state_floor**(pmgr perf state) — executed *before* FW load.
2. **Wrap/PWM block programming**: `DevicePwrOn` (0x1000000←0xfff), `DeviceInit` after CM3 boot (0x1400018/0x1070000/0x1104064/0x110cac8+... 8 writes), `initAvdWrap` (0x1070024←0x26907000). **Linux does not touch this block at all.**
3. **CM3 boot**: `restoreM3context` → mcpu `init()` (fw load) → `ConfigureDMA(1)` → `start()` (disableMCPUE→enableMCPUE→WaitForM3Boot) → ADS poll.

**Top 3 candidates for steps missing on Linux** (detailed rationale in §6):

1. **Wrap/PMM block initialization** (total of 10 MMIO writes from `DevicePwrOn`/`DeviceInit`/`initAvdWrap`, offsets 0x1000000–0x110cxxx) — no equivalent concept in Linux. Most likely to contain the clock/power gates needed for CM3 start.
2. **Pre-boot clock enable / pmgr perf-state floor** (set_perf_state_floor + clock gate from `enableDeviceClockWrapper`) — the Linux driver has no clock/power gate code at all (CLK 0x15d, gates 0x12a/0x12c/0x12d unused).
3. **Additional mbox writes in `enableMCPUE`** (+0x50, +0x68, +0x74 ← 1, +0x4c ← 0) — Linux only writes +0x5c/+0x48/+0x08.

---

## 1. Ordered MMIO Write List for the init/power-on path

Offset notation: "window offset" = byte offset within the unified VA mapping the kext creates (see the base mapping in §5).
Region attribution rationale is in §5. Write order follows the actual call order.

### Phase A — power-up start (`AppleAVD::setPowerStateOn(u32 core)`, 0x924a660)

| # | function | region (estimated) | offset | value | notes |
|---|------|--------------|--------|----|------|
| A1 | enableDeviceClockWrapper | pmgr/clk (not direct MMIO) | — | — | AppleARMIODevice clock gate + function-set_perf_state_floor (§3.3) |
| A2 | DevicePwrOn (wrapctrl vtable[5]) | **wrap/pwm** | **0x1000000** | **0xfff** | "pwm" power-on. `str w2,[x9+off]`, x9=[wrap+16] |

### Phase B — CM3 boot (`CAvdApComm::restoreM3context(bool)`, 0x923cc1c)

mcpu = CAvdMcpuViola→**CAvdM3Mcpu** (regIO base 0x1080000, mbox = +0x28000 → absolute 0x10a80xx).

| # | function | region | offset | value | notes |
|---|------|--------|--------|----|------|
| B1 | CAvdMcpu::init→**disableMCPUE** (vtable[8]) | mbox | +0x08 (0x10a8008) | 0xe | RUN_CTRL stop (matches Linux AVD_RUN_CTRL_UNK_STOP=0xe) |
| B2 | disableMCPUE | mbox | +0x98 (0x10a8098) | 1 | FLAG0 clear |
| B3 | disableMCPUE | mbox | +0x10 (0x10a8010) | 0 | |
| B4 | disableMCPUE | mbox | +0x48 (0x10a8048) | 0 | IRQ enable clear |
| B5 | loadFirmwareImage | **CM3 SRAM** | 0x1080000 | fw 0xef78 B | copy of the fw built into the kext (`__TEXT` 0x7175e30) via WriteBufferToRegister |
| B6 | loadFirmwareImage | CM3 SRAM | 0x1080000+0xef78 … 0x1092000 | 0 | remaining 0x12000 bytes of the window filled with 0 |
| B7 | ConfigureDMA(1) (vtable[31], conditional) | — | — | — | only when [PQ+3300]==1 |
| B8 | CAvdMcpu::start→**disableMCPUE** | mbox | same as B1–B4 | | re-execution |
| B9 | start→**enableMCPUE** (vtable[9]) | mbox | **+0x50** | 1 | **absent in Linux** |
| B10 | enableMCPUE | mbox | **+0x68** | 1 | **absent in Linux** |
| B11 | enableMCPUE | mbox | +0x5c (0x10a805c) | 1 | MBOX1 enable — **only Linux match** |
| B12 | enableMCPUE | mbox | **+0x74** | 1 | **absent in Linux** |
| B13 | enableMCPUE | mbox | +0x4c (0x10a804c) | 0 | IRQ clear (vtable[15] stub — the actual write) |
| B14 | enableMCPUE | mbox | +0x08 (0x10a8008) | 1 | RUN_CTRL run |
| B15 | initAvdWrap (ApCommViola vtable[25]) | **wrap** | **0x1070024** | **0x26907000** | writes a physical address to a wrap register (estimated DART/SID configuration) |

### Phase C — immediately after CM3 boot (`setPowerStateOn` continues, wrapctrl vtable[4])

`CAvdWrapCtrlViola::DeviceInit` (0x92384d8), in order (all `str w2,[x9+off]`, x9=[wrap+16]):

| # | offset | value | notes |
|---|--------|----|------|
| C1 | **0x1400018** | 1 | 0x1400000 block |
| C2 | **0x1070000** | 0 | |
| C3 | **0x1104064** | 3 | ≈ Linux ctrl + 0x4064 (immediately below VP FIFO) |
| C4 | **0x110cc90** | 0xffffffff | |
| C5 | **0x110cc94** | 0xffffffff | |
| C6 | **0x110ccd0** | 0xffffffff | |
| C7 | **0x110ccd4** | 0xffffffff | |
| C8 | **0x110cac8** | 0xffffffff | |

### Phase D — ADS validity poll (`CAvdApCommViola::waitValidADSStatus`, vtable[8] of ApComm)

Read-only: poll offset **0x1002010** via ReadRegister32 until `(val & 0x7f0) == 0x7f0`; 10ms intervals, max 500 iterations (5s).
Matches the boot log: status 0x0; about 400ms later, 0x7f0.

### (reference) reset path — `CAvdWrapCtrlViola::PwmReset` (0x92383e8, called from HardReset)

1. `waitForOutstandingAXITransaction`: poll offsets **0x738** and **0x798**, wait for `(val & 0xfe00fe00) == 0` (drain AXI outstanding transactions).
2. Call vtable[41] on [wrap+32] (w1=1): [wrap+32] = the provider's **"function-avd_reset"** property object — **pmgr ARST reset trigger** (DT function-avd_reset, 4CC "ARST").
3. `AVDDart::setActive([wrap+96], 1)`.

`Idle(bool x1)` = offset **0x1400014** ← x1 (idle entry/exit).

---

## 2. Power-sequence call order (reconstructed call graph)

```
AppleAVD::start (probe; chip id 0x1a → Viola factory)
  ├─ AVDDart::setActive(1), AVDDart::initialize/registerWithIOSurface
  ├─ enableDeviceClockWrapper(io, 1, 0, 1)          ← clock gate + perf floor
  ├─ initForPM
  └─ (PM registration; the first power-up goes initializeDevice → requestPowerChange)

Power-up (per core):
AppleAVD::initializeDeviceInternal gated fn (arg=1)
  └─ AppleAVD::setPowerStateOn(core)                0x924a660
       1. enableDeviceClockWrapper([this+0xf8+core*8], 1, 0, 1)     ← A1
       2. ioDevice vtable[278](1,0,0)
       3. [this+0xe8+core*8] vtable[5](0)  = WrapCtrl::DevicePwrOn    ← A2 (0x1000000←0xfff)
       4. AVDDart::setActive(1) / unmapDeferralList  ([this+0xd8])
       5. PriorityQueue::setAVDCtrlIdle(1) + queue drain
       6. [[this+0xc8+core*8]+8]::restoreM3context(0)  (CAvdApComm)  ← entire Phase B
            ├─ mcpu->init(0)      = disableMCPUE + loadFirmwareImage (fw→SRAM)
            ├─ ApComm->ConfigureDMA(1) (conditional)
            ├─ mcpu->start()      = disableMCPUE → enableMCPUE → WaitForM3Boot
            ├─ mcpuRestoreContext (when arg==0)
            └─ ApCommViola::initAvdWrap()            ← B15 (0x1070024←0x26907000)
       7. [this+0xe8+core*8] vtable[4](0)  = WrapCtrl::DeviceInit     ← Phase C, 8 writes
       8. [[this+0xc8+core*8]+8] vtable[8] = waitValidADSStatus (conditional) ← Phase D

Reset:
AppleAVD::HardReset → per core: [this+0xe8+core*8] vtable[10](0) → vtable[8] = PwmReset (ARST)
```

**Key ordering**: clock (A1) → wrap power-on (A2) → **firmware load (B5,B6)** → M3 run (B9–B14) → ADS poll (D).
In other words, macOS finishes clock + wrap + SRAM load all *before* writing RUN_CTRL=1.

---

## 3. Writes absent on Linux — disassembly snippets

### 3.1 `CAvdM3Mcpu::enableMCPUE` in full (0x9226458)

```asm
0x9226458:  pacibsp
0x922646c:  ldr  w1, [x0, #340]        ; field 340 = +0x50 (constructor table base 0x1080000+0x28050)
0x9226470:  mov  w2, #1
0x9226474:  bl   0x9259dcc             ; CAvdMcpu::WriteRegister32 → mbox+0x50 = 1   [absent in Linux]
0x9226478:  ldr  w1, [x19, #364]       ; +0x68
0x9226484:  bl   ...WriteRegister32    ; mbox+0x68 = 1                                [absent in Linux]
0x9226488:  ldr  w1, [x19, #352]       ; +0x5c  (MBOX1 enable)
0x9226494:  bl   ...WriteRegister32    ; mbox+0x5c = 1                                [same as Linux]
0x9226498:  ldr  w1, [x19, #376]       ; +0x74
0x92264a4:  bl   ...WriteRegister32    ; mbox+0x74 = 1                                [absent in Linux]
0x92264a8:  ldr  x16, [x19]            ; vtable
0x92264cc:  add  x8, x16, #0x78        ; vtable[15]
0x92264d4:  mov  w1, #0
0x92264e4:  blraa x9, x17              ; M3Mcpu vtable[15] = no-op stub (bti c; ret) — TX/RX IRQ control unused
0x92264e8:  ldr  w1, [x19, #320]       ; +0x08  (RUN_CTRL)
0x92264f0:  mov  w2, #1
0x922650c:  b    0x9259dcc             ; tail: mbox+0x08 = 1 (RUN)                    [same as Linux]
```

Offset table of the constructor (0x92268a8) (`__TEXT` 0x7175dc0–0x7175e1f, default base 0x1080000):

```
fields 320..412 = 0x1080000 + {0x28008,0x28010,0x28048,0x2802c, 0x2804c,0x28050,0x28054,0x28058,
                            0x2805c,0x28060,0x28064,0x28068, 0x2806c,0x28070,0x28074,0x28078,
                            0x2807c,0x28080,0x28084,0x28088, 0x2808c,0x28090,0x28098,0x28094}
field 416 = 0x1080000 + 0x2809c ; field 12 = fw destination 0x1080000 ; field 16 = 0x12000 (window size)
field 32 = built-in fw image ptr (__TEXT 0x7175e30) ; field 40 = fw size 0xef78
```

`disableMCPUE` (0x92263f0): field320(+0x08)←0xe, field408(+0x98)←1, field324(+0x10)←0, field328(+0x48)←0.

### 3.2 `AppleAVD::enableFastClockInternal` in full (0x924b18c) — prime suspect

```asm
; proceeds only when [this+0x20c+idx*4] (current fast-clk state) != [this+0x204+idx*4] (requested state)
0x924b1d4:  ldr  x1, [x25, x20, lsl #3]   ; x25 = this+0xf8  (AppleARMIODevice*)
0x924b1e8:  bl   0x9243d74                 ; enableDeviceClockWrapper(io, 1, 0, 1)
0x924b204:  ldrb w8, [x8, x20]             ; [this+0x22d+idx] (boost flag A)
0x924b210:  ldrb w8, [x8, x20]             ; [this+0x22f+idx] (boost flag B) == 1?
0x924b220:  ldrb w8, [x21, #561]           ; [this+561] perf-floor allow flag
0x924b254:  bl   0x9243d74                 ; enableDeviceClockWrapper(io, clkID=[this+0x204+idx*4], 1, 1)
0x924b294:  ldr  x8, [x16, #2216]          ; ioDevice vtable[277]
0x924b2b4:  blraa x8                       ; AppleARMIODevice: set clock frequency/gate (0, clkVal)
0x924b2d4:  str  w2, [x22, x20, lsl #2]    ; [this+0x20c+idx*4] = requested-state update
```

Call sites: the `AppleAVDCoreControl::requestAVDCoreSpeed` path inside `initializeDeviceInternal` (0x924850c–0x9248594) —
toggles the fast clock depending on decode load. So it runs **mid-session, not right after boot**, but it is in the same
pmgr/clk family as the always-on clock (A1), and Linux has no equivalent concept.

### 3.3 `AppleAVD::enableDeviceClockWrapper` (0x9243d74) — the true nature of the "clock"

- Log strings: `"AppleAVD: %s() :: Calling function-set_perf_state_floor failed !"` (0x71655c0),
  `"function-set_perf_state_floor"` cstring (0x71733ee).
- Passes to the [this+0x17590] object's vtable[40] a pointer to a {u32, u32, bool} struct → wrapper for a pmgr function call.
- Override of `AppleAVD::callPlatformFunction` (0x924b414): if the function name matches one of two cached OSSymbols,
  sets [this+561] to 1/0 (= allow/release fast clock) then delegates to super. The log directly proves that the actual
  work of the clock enable is the **set_perf_state_floor + clock gate of AppleARMIODevice (=pmgr)**.
- The function at 0x9243f40: chip id → 42/129/36/32 value mapping (estimated clock frequency/perf-state).

### 3.4 `CAvdWrapCtrlViola::WriteRegister32` (0x9237df4) — direct MMIO

```asm
0x9237df8:  mov  w8, w1
0x9237dfc:  ldr  x9, [x0, #16]        ; base VA (stored as regs pointer in the constructor)
0x9237e00:  ldrb w10, [x0, #24]       ; endian flag (Viola=1)
0x9237e04:  cmp  w10, #2
0x9237e0c:  rev  w10, w2              ; (byte-swap when endian==2)
0x9237e10:  add  x8, x9, x8
0x9237e14:  str  w10, [x8]            ; *(u32*)(base + off) = val
```

The "offsets" of DeviceInit/DevicePwrOn/Idle are all relative to this base.

---

## 4. Semantics of the ADS wait

- Functions: `CAvdApCommViola::waitValidADSStatus` (0x9259410), `waitValidADSStatusWithMask(j)` (0x9259a28) — same structure.
- Register: **offset 0x1002010** (relative to ApComm's CAvdRegisterIO; the 0x1002000 block within the wrap base window).
- Meaning: poll until `(status & 0x7f0) == 0x7f0`. 10ms intervals, max 0x1f4(500) iterations ≈ 5s.
- Log (identical to the Korean test record): on the first poll "AVD ADS module valid bits not set yet! Waiting until valid. status=0x0",
  on success "AVD ADS status valid bits set! status=0x7f0" — measured at about 400ms.
- Interpretation: 0x7f0 = the upper 7 bits (0x80..0x400) + 0x70 — the valid/ready bit mask of the ADS module (decryption engine).
  This poll happens **after** CM3 boot (B14) and wrap DeviceInit (C1–C8) → ADS becomes ready only after wrap + CM3
  initialization finishes. Linux has no concept of ADS at all (decryption is handled by the driver, not FW).

## 5. Register base mapping table

The kext maps the entire AVD space as **one large VA window**, and each object uses byte offsets within it.
(Rationale: direct str to the base stored in wrap ctrl [this+16] of 0x1000000~0x110cxxx offsets; mcpu regIO at
0x1080000+0x280xx; the two structurally match the Linux mbox/ctrl physical addresses — correspondences below.)

| window offset | content | estimated physical counterpart (assuming base+0x268000000) | rationale |
|---|---|---|---|
| 0x1000000 | wrap/pwm power block (PwrOn 0xfff, AXI status 0x738/0x798, ADS 0x1002010) | ≈0x269000000 range | same lower address space as the only MMIO range in ioreg, 0x269010000+0x4000; unmapped on Linux |
| 0x1070000–0x1070fff | wrap control (Init 0x1070000, 0x1070024←0x26907000) | ≈0x269070000 | physical address 0x26907000 is written to this register (self-space reference) |
| 0x1080000–0x1091fff | CM3 firmware SRAM window (size 0x12000) | Linux "code" resource | fw copy destination; matches the user's byte-identical load check |
| 0x10a8000–0x10a80a0 | **mbox** (RUN_CTRL +0x08, IRQ +0x48, MBOX1 +0x5c, RETRIEVE +0x64, FLAG0 +0x90/+0x98) | Linux mbox 0x269098000 | field offsets **match exactly** Linux avd-regs.h (+0x08/+0x48/+0x5c/+0x64/+0x90/+0x98) |
| 0x1104000, 0x110c000–0x110ccd8 | DeviceInit targets (0x1104064←3, 0x110cac8+...←0xffffffff) | Linux ctrl 0x269100000 region | same group as Linux t8103 vp_slot 0x4004/insn fifo 0x4068, i.e. the 0x40xx cluster |
| 0x1400014/0x1400018 | idle/pwm auxiliary | ≈0x269140018? (unconfirmed) | used by Idle/DeviceInit |

Source of the base VA: in `AppleAVD::start` (0x923ffec), the base pointer is obtained from the [this+384] object's
(AppleARMIODevice family) vtable[226] → the [this+296] object's vtable[39] (0x9240118, [sp+120]), then passed to
`CAvdWrapCtrlViola::C2(u32* regs, ...)`/`CAvdApCommViola::C2(void*, CAvdRegisterIO*)`.
The exact physical base is obtained at runtime from DT/IODeviceMemory (no hardcoded physical address — confirming the premise of the task).

Object arrays (relative to AppleAVD this):
- +0xc8: array of CPriorityQueue* (→ [+8] = CAvdApComm*)
- +0xd8: array of AVDDart*
- +0xe8: **array of CAvdWrapCtrl*** (vtable[4]=DeviceInit, [5]=DevicePwrOn, [8]=PwmReset — see §2 order)
- +0xf8: array of AppleARMIODevice*
- +0x160: wrap ctrl array (factory), +0xb0 (176): per-chip wrap ctrl
- +0x17590: perf-state/clock management object, +0x16000 band: AppleAVDDiagnostic

## 6. Diff against the Linux baseline — Top 3 candidates for missing steps

Linux `avd_boot()` (drivers/media/platform/apple/avd/avd-hw.c): `memcpy_toio(code, fw)` →
`mbox+0x5c=1` → `mbox+0x48=8` → `mbox+0x08=1` → poll `mbox+0x90`. Reset is `reset_control_reset()` (pmgr ARST).

### Candidate 1: wrap/PMM block initialization (strongest candidate — possibly j293-specific)
- Rationale: before CM3 boot (A2: 0x1000000←0xfff) and right after it (C1–C8: 8, B15: 0x1070024←physical address),
  macOS programs a total of 10 wrap registers. Linux never writes to this space (0x1000000–0x110cxxx).
- 0x1000000←0xfff is an "all power domains on"-style value. If on j293 (unlike j274) the wrap gates the CM3 clock/power, then
  without this write CM3 does not run even after RUN_CTRL is written, and FLAG0 stays 0 forever — **exactly matching the observed symptoms**.
- C3 (0x1104064←3) and C4–C8 (0x110cxxx←0xffffffff) fall in the Linux ctrl region 0x40xx/0xcxxx;
  possibly VP/DMA pipeline settings.

### Candidate 2: pre-boot clock enable + pmgr perf-state floor
- Rationale: A1 runs *before* FW load. Inside it: `function-set_perf_state_floor` (pmgr) + clock gate.
  ioreg DT facts: clock-ids [0x15d], clock-gates/power-gates [0x12a,0x12c,0x12d] — actually used by the kext
  ( enableDeviceClockWrapper → AppleARMIODevice ). The Linux driver has no clk/pwr code at all
  (no clk_prepare_enable in `avd_probe`), and the guarantee that the t8103 gates (0x12a/0x12c/0x12d)
  were turned on in U-Boot/m1n1 may not hold on j293.

### Candidate 3: additional mbox writes in enableMCPUE (+0x50, +0x68, +0x74 ← 1, +0x4c ← 0)
- Rationale: within the same function, executed right before RUN_CTRL. Sitting next to +0x5c (the only one shared
  with Linux), they are likely part of the same mandatory init sequence. Meaning unknown (estimated to be auxiliary
  gates/masks inside the mbox block), but among the candidates explaining the symptom "SRAM/reset check out but
  FLAG0 never rises", these are the mbox registers that Linux alone leaves untouched.

Other diffs (low priority): fw 0 padding 0x12000 (B6, likely excludable as byte-identical loading is already
confirmed), ADS poll (decryption only), IRQ clear (+0x4c), DisableM3InboxEmptyInterrupt path.

---

## 7. Blockers / limitations (methods tried)

1. **Could not fully pin down the direct call sites of DeviceInit/DevicePwrOn by text matching**.
   Exhaustive scan of virtual-call (vtable+0x20/+0x28/+0x40) patterns (`mov x17,#imm; add x16,x16,x17`,
   `add x16,x16,#imm`, `ldr x8,[x16,#imm]!`, 3 variants) found no clear call site other than the CAvdWrapCtrlViola
   constructor; the [this+0xe8] array objects' vtable[4]/[5] calls are therefore inferred to be DeviceInit/DevicePwrOn
   by **slot-number match** (DATA_CONST vtable decoding, delta 0x7004000 rule). The §2 ordering is based on this inference.
2. **Exact physical base**: could not fully reconcile the only MMIO range in ioreg (0x269010000+0x4000) with the
   kext window offsets (0x1000000+). The *relative spacing* between Linux mbox (0x269098000)/ctrl (0x269100000) and
   the kext offsets (0x10a8000/0x1100000) does not line up, leaving a possible 0x1000 shift.
   The physical estimates in §5 state the "base+0x268000000" assumption explicitly.
3. Out-of-kernel functions (0x8e8996c = os_log family, 0x8c90748 = thread signal, 0x8f08bc4 = IOService power, etc.)
   are identified by behavior only, without kernelcache symbols.
4. The 6 virtual calls of `writeHxRegister` (vtable+0x218/0x228/0x138/0x28/0x220/0x40) appear to be
   IODeviceMemory→VA conversion/barrier wrappers, but the exact method names of the class ( RegisterIO,
   __ZTV10RegisterIO confirmed) are unconfirmed — no impact on MMIO semantics (single `str w`).

## 8. Reproduction commands

```sh
cd rev/
aarch64-linux-gnu-objdump -D -b binary -m aarch64 --adjust-vma=0xfffffe0009226370 \
  AppleAVD.__TEXT_EXEC.bin > /tmp/text_exec.asm
# function slices: 0x9226458–0x9226510 (enableMCPUE), 0x92384d8–0x9238720 (DeviceInit),
# 0x924a660–0x924aa80 (setPowerStateOn), 0x924b18c–0x924b318 (enableFastClockInternal),
# 0x9259410–0x9259550 (waitValidADSStatus), 0x923cc1c–0x923cdb8 (restoreM3context)
```
