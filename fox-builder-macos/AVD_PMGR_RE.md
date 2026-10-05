# AVD clock/pmgr reversing — macOS continuation (2026-10-05)

Follow-up to `AVD_POWER_RE.md` §7 "Next extraction targets". Done on macOS
15.7.1 (24G231), same Preboot kernelcache (sha256 in `rev/kc_sha256.txt`).
Method: `rev/im4p_decode.rb` + `rev/kc_extract.rb` (segments mode) +
`rev/kext_analyze.rb` + `rev/decode_pmgr_dt.rb`; live `ioreg -p IODeviceTree`.

## 1. Extracted kexts (`rev/kexts/<name>/`, per-segment bins + symbols + strings)

| kext | symbols | relevance |
|---|---|---|
| AppleARMPlatform | 2806 | `AppleARMIODevice::enableDeviceClock` 0x91d6db4 (the io->vtable[277] clock-gate entry), `AppleARMPerformanceController::_enableDeviceClockGated(mm)` 0x91e3dd4, `gAppleARMPerformanceControllerNomenclature` 0x7df9de8 (clock id→HW table) |
| ApplePMGR | 2441 | all pmgr function-object classes (below) |
| AppleT8103PMGR | 2723 | chip-specific pmgr (no AVD-specific symbols) |
| AppleSMC / AppleSPMI / AppleSPMIPMU | 1123/376/203 | SMC rail path for the virtual VNOM/VMAX rails |

**Clock-gate call chain (A1/candidate 2)**: `AppleAVD::enableDeviceClockWrapper`
→ `io->vtable[277]` = `AppleARMIODevice::enableDeviceClock(0x91d6db4)`
→ `AppleARMPerformanceController::_enableDeviceClockGated(0x91e3dd4)`
(id,gate) → per-id work via the nomenclature table. Also
`AppleARMPerformanceControllerFunctionClockGate::callFunction` 0x91e7c98
(pmgr-side twin). **No pmgr-base constants in any kext TEXT_EXEC** — bases are
DT-derived at runtime; offsets exist only as instruction immediates →
disassembly required (Linux).

## 2. pmgr function-object family (ApplePMGR) — with addresses

`ApplePMGRFunction<Name>::callFunction(void*,void*,void*)` unless noted:

- `ClockGate` **0x9f00164** · `PowerGate` 0x9f00450 · `VideoClock` 0x9f02148
- `SetPerfState` **0x9f05b90** (the "function-set_perf_state_floor" object —
  payload {u32 val; u32; bool}, val only 0/1 per AVD_POWER_RE §2)
- `GetValidPerfState` 0x9ec…(see symbols file)
- `AssertReset::assertReset(bool)` **0x9f00754** — no callFunction; this is
  the ARST object behind `function-avd_reset` (slot41, w1=1)
- `EnableAutoClockGate` 0x9f04d2c, CPUIdle, CLPCEnabled, ROSC, PLLOffMode,
  USBClock, ISPRefClock, PMPInterrupt, SEPSleepPrep, EnableCPUCore,
  StartS2RTimer, PDMClockBypass, PerfCycleCount, ReconfigTrigger,
  EnableTouchClock, WaitForDeviceEvent, SetATCDpClockSource,
  SetTouchClockSource, Stub (full list: `rev/kexts/ApplePMGR/ApplePMGR.symbols.txt`)

All take their register description via
`initWithTargetDataAndSymbol(IOService*, OSData*, OSSymbol*)` — the OSData is
the DT function property bytes (see §3).

## 3. Live device-tree decodes (`rev/ioreg_devicetree.txt`, `ioreg_pmgr_devices_decoded.txt`, `ioreg_clocks_decoded.txt`)

### ERRATA (correction to AVD_MACOS_FINDINGS.md §4)
The avd node's MMIO is **IODeviceMemory = 0x268000000, length 0x1404000** —
one unified window (reg prop `<0x68000000 0x1404000>` + parent ranges
+0x200000000). The earlier "0x269010000+0x4000" was **dart-avd's** range
(misattributed). All kext window offsets now line up exactly:
`wrap 0x269000000 = base+0x1000000`, `code/SRAM 0x269080000 = base+0x1080000`,
`mbox 0x269098000 = base+0x10a8000`, `ctrl 0x269100000 = base+0x1100000`.
The DISASM_INIT_PATH §7.2 "possible 0x1000 shift" concern is resolved — no shift.

### function-avd_reset format (decoded)
`<8b000000 54535241 66000000>` = **type 0x8b**, name **"ARST"** (LE 4CC),
**arg 0x66**. 0x66 is the pmgr device-table id of **AVD_SYS** → the ARST
function targets the AVD_SYS ps block (reset bit at pmgr 0x23b700410 area).
Same pattern on CPU nodes: function-enable_core = <0x8b "eroC" core-mask>.

### pmgr device table (268 records, validated: AVD_SYS→0x410, MMX→0x358,
FPWM1→0x1e0, DPA1→0x2f0 all MATCH — decode is exact)
- AVD clock-gates: **AVD-SYS-V (0x12b)** VIRTUAL → parent AVD_SYS(0x66);
  **AVD-SOC-VNOM (0x12c) / AVD-SOC-VMAX (0x12d)** VIRTUAL, **no parents —
  SMC-managed voltage rails**; dart gate **AVD-SYS-DART (0x145)** → AVD_SYS.
- pmgr has **54 reg regions** (0x3b700000, 0x3d280000, 0x3b000000, 0x3d200000, …)
  and 13 ps-regs triplets.

### clocks registry (pmgr "clocks" property, 27 entries)
ids 0x136–0x149: FAST_AF, SBR, DISP0, ISP_SENSOR0-3_REF, **VENC (0x13d)**,
PMP, PLL0–7, PLL_GFX, PLL_ANE, PLL_PCIE; ids 0x12–0x18: LPPLL_FAST,
AOP_CLK_SEL_0–4, LPPLL_FAST.

### open question handed to Linux: avd `clock-ids = <0x15d>` does NOT resolve
in the pmgr clocks registry (max id 0x149) nor sensibly in the device table
(0x15d = "AUSB0_AONUSB-V", an unrelated USB rail) — so clock-ids uses a
separate numbering, mapped inside AppleARMPerformanceController
(`gAppleARMPerformanceControllerNomenclature` @ 0x7df9de8, an absolute/N_ABS
symbol pointing into KC-shared DATA_CONST). **Decode this table +
`_enableDeviceClockGated` (0x91e3dd4) to learn what clock 0x15d actually
toggles (PLL? CLKGEN register?) and replicate it in the Linux patch.**

## 4. What macOS could NOT answer (→ Linux, with inputs)

1. Actual MMIO writes of `_enableDeviceClockGated` / `FunctionClockGate::
   callFunction` / `SetPerfState::callFunction` / `AssertReset::assertReset`
   — disassemble from `rev/kexts/*/*.bin` (bases in each map.txt; objdump
   one-liners in `AppleAVD.slim.map.txt`).
2. Nomenclature table decode (§3).
3. Whether the SMC manages AVD-SOC-VNOM/VMAX automatically at genpd power-on
   or needs an explicit message (AppleSMC bins included).
4. Live test of patch v2 (candidate 2) — per AVD_LIVE_TEST_LOG.md safety
   rules: cold boot first, one attempt, staged markers.

## 5. Artifacts added this round

`rev/kexts/{AppleARMPlatform,ApplePMGR,AppleT8103PMGR,AppleSMC,AppleSPMI,AppleSPMIPMU}/`
(per-kext .bin segments + symbols + strings + map),
`rev/ioreg_devicetree.txt` (full DT plane), `rev/ioreg_t8103pmgr.txt`,
`rev/ioreg_pmgr_devices_decoded.txt`, `rev/ioreg_clocks_decoded.txt`,
`rev/decode_pmgr_dt.rb`, `rev/kext_analyze.rb`, plus the previously missing
AppleAVD segment bins / strings / kernel log / ioreg dumps copied in from the
first round. `kernelcache.macho` removed (regenerable via im4p_decode.rb).
