# AVD clock-gate / pmgr function-object RE — Linux bring-up conclusions (j293, t8103)

Date: 2026-10-05. Static disassembly of `rev/kexts/{AppleARMPlatform,ApplePMGR,AppleT8103PMGR,AppleSMC,AppleSPMI,AppleSPMIPMU}` segment bins (macOS 15.7.1 arm64e kernelcache, same as `AVD_PMGR_RE.md`), tool `/usr/bin/aarch64-linux-gnu-objdump`, scratch dumps in `/tmp/cgre/` (tmpfs, not committed).

Pointer-decode conventions (from `AVD_POWER_RE.md` §0, re-verified here on 6 vtables):

- vtable word stored in `__DATA_CONST` = `0x80xx<SALT><low32>`; target = `(low32 + 0x07004000) & 0xffffffff` (KC TEXT_EXEC truncated to 32 bits).
- Object's vtable pointer = `ZTV symbol + 0x10` (two zero header quads; metaClass/superClass pointers sit at ZTV−0x10/ZTV−0x8). A call site loading `[vt + 0x8a8]` therefore hits ZTV index `(0x8a8+0x10)/8 = 0x8b8/8` — i.e. "vtable[277]" in earlier notes was `0x8a8/8` without the +0x10 header correction.
- `blraa` salt must equal bits [47:32] of the stored vtable word — used throughout as the slot-identity check.

---

## 0. TL;DR — the one-paragraph answers

**What does clock 0x15d toggle?** Nothing. `clock-ids = <0x15d>` on the avd node has **no hardware consumer on t8103**: `gAppleARMPerformanceControllerNomenclature` turned out to be an **os_log trace-format string table** (PERF_* event/argument names), not a clock-id→hardware map; the clock-id is only looked up by `getClockFrequency`/`getClockName` in a descriptor table built from the optional DT property `clock-frequencies` (absent on the avd node → lookup returns NULL). The boot/fast-clock enable call `io->vtable[277](io, 1, 0)` → `AppleARMIODevice::enableDeviceClock(enable=1, index=0)` → `clock-gates[0] = 0x12b` → parent `AppleARMIO::enableDeviceClock` which is a **stub returning 0xe00002c7 (kIOReturnUnsupported)** in AppleARMPlatform.kext (vtable entry verified by salt match 0x61db). **macOS writes zero clock-gate MMIO for AVD.** The exact "enable writes" that do exist on the macOS path are the generic **pmgr ps-register write with GO-bit handshake** performed by the IOKit power-state=2 chain (ps@0x23b700410: `(old & ~0x300) | target<<0 | GO(bit31)`, poll BUSY(bit11)==0), which the Linux `apple-pmgr` genpd driver already replicates.

**ARST semantics one-liner:** `ApplePMGRFunctionAssertReset::assertReset(true)` for DT arg 0x66 writes the AVD_SYS ps register at **0x23b700410** — read; write `(old & ~0x300) | 0x400` (clear WAS_CLKGATED/WAS_PWRGATED bits 9:8, set DEV_DISABLE bit 10); poll BUSY(bit11)==0 (to 720); write `(old & ~0x300) | 0x80000400` (add RESET/GO bit31); poll bit31==1, rewrite `(old & ~0x300) | 0x400`, poll bit31==0; then sleep 100 ms + poll the per-device status block — while **`assertReset(false)` is a no-op returning 0**, and macOS only ever calls it with `true` (PwmReset).

**Surprises:** (1) the nomenclature "table" is logging metadata — the round-2 hypothesis was wrong; (2) the entire AppleARMPlatform clock/power surface (`AppleARMIO::enableDeviceClock/Power/PinGroup`) is **deliberately stubbed** on this kernelcache — clock gating on t8103 is owned by PMGR, not by the legacy fclk/aclk path; (3) **no `function-set_perf_state_floor` property exists anywhere in the t8103 DT**, so AppleAVD's perf-floor handle is NULL and the floor object is never invoked at runtime (the ps[27:24] floor = 0xf comes from PMGR's own init, and is already 0xf on Linux); (4) nothing in the macOS enable path writes into the AVD MMIO aperture **except** the 7 known DeviceInit writes at wrap offsets 0x1400018/0x1070000/0x11001cc/0x110e6d0… — and those land at 0x269140018+, i.e. inside the region the j293 bisection called "wrap 0x269140000 dark", which contradicts "dark ⇒ unusable" (macOS writes it at every boot) — recheck that bisection result; (5) all pmgr-side writes are to the **pmgr block 0x23b700000**, never the dark AVD regions, so no macOS-mandated write falls in a hanging region.

---

## 1. `gAppleARMPerformanceControllerNomenclature` @ 0xfffffe0007df9de8 — decoded

Location: `AppleARMPlatform.__DATA_CONST.bin` file offset **0xc9b0** (DATA_CONST base 0xfffffe0007ded438 + 0xc9b0 = 0xfffffe0007df9de8). Symbol is the last object before `AppleARMPerformanceControllerFunctionClockGate::metaClass` (0x7df9f78); table size = 0x190 = **50 × 8-byte entries**.

Entry format: `{ u32 kc_fileoff; u32 tag }` where tag = 0x1000 and kc_fileoff points into the kext's own `__TEXT` cstring pool (kc_fileoff 0x144920 = __TEXT segment base in the KC file). This is a **table of `{pointer,0x1000}`-shaped os_log "nomenclature" records** — the same pattern as `ApplePMGR.__ZL18_traceNomenclature` (0x803bee0). It names kdebug/os_log events and their argument labels for the performance-controller's trace buffer (`traceBufferAddEntry`).

Decoded entries (all 50; strings verified at file offsets kc_fileoff − 0x144920):

| idx | string | idx | string |
|---|---|---|---|
| 0 | PERF_PCEVENT | 25 | **PERF_CLOCK_GATE** |
| 1 | Event | 26 | **ClockID** |
| 2–4 | UnusedArg | 27 | **Enable** |
| 5 | PERF_CPU_IDLE | 28–29 | UnusedArg |
| 6 | CpuNumber | 30 | PERF_SRAMEMA_DOMx |
| 7 | EnterExit | 31 | NewEMASt |
| 8 | NewEvent | 32–34 | UnusedArg |
| 9 | CpusActive | 35 | PERF_CPU_TICKS |
| 10 | PERF_CPU_IDLE_TIMER | 36 | CpuIdleTicksHigh |
| 11 | NewEvent | 37 | CpuIdleTicksLow |
| 12–14 | UnusedArg | 38 | CpuActiveTicksHigh |
| 15 | PERF_VOLT_CHG_DOMx | 39 | CpuActiveTicksLow |
| 16 | ReqVoltSt | 40 | PERF_ARBITER_NOTIFY |
| 17 | DVCVoltSt | 41 | Reason |
| 18 | CurrentVoltSt | 42–44 | UnusedArg |
| 19 | NewVoltSt | 45 | PERF_ARBITER_SET_PERF |
| 20 | PERF_PERF_CHG_DOMx | 46 | ctrlEffort |
| 21 | LimitVoltSt | 47 | voltLevel |
| 22 | ActualPerfSt | 48–49 | UnusedArg |
| 23 | NewPerfSt | | |
| 24 | UnusedArg | | |

Raw bytes of the first entries at file offset 0xc9b0 (hex, 8 B/entry):

```
b9 c9 14 00 00 00 10 00    c6 c9 14 00 00 00 10 00
cc c9 14 00 00 00 10 00    ...                        (idx 2..4 = 0x14c9cc "UnusedArg")
```

**This is not a clock-id→hardware-description table.** It exists so `traceBufferAddEntry(0x2700c001, clockId, gate, -1, -1)` can be rendered as `PERF_CLOCK_GATE {ClockID=…, Enable=…}` — event code 0x2700c001/0x2700c002 (used by both `AppleARMPerformanceController::_enableDeviceClockGated` and `ApplePMGR::_enableDevice`, see §2/§4) is the trace id for nomenclature index 25.

Confidence: **high** — 50/50 entries decode to sensible trace names; entry 25–27 exactly match the two trace call sites' argument registers (clockId, gate).

### Where clock id 0x15d *is* looked up (and why it still does nothing)

`AppleARMIODevice` field map (from `initDeviceWithProvider` 0x91d7310 + `getClockName` 0x91d6bd0/`getClockFrequency` 0x91d6c28):

| offset | content (DT property) |
|---|---|
| +136 | provider `AppleARMIO*` (the nub driver instance) |
| +144 / +152 | `clock-ids` count / u32 array |
| +160 / +168 | `clock-gates` count / u32 array |
| +176 | power-gates array |

`getClockFrequency(io, idx)` → `clockId = io->clockIds[idx]` → `provider->getClockFrequency(clockId, …)` → `AppleARMIO::getClockFrequency` (0x91d61b4, real) checks a **0x48-byte descriptor table at AppleARMIO+200** `{count @+212, startId @+208}` built by `AppleARMIO::processDevice` from the optional DT properties `clock-frequencies` (u32 id array) + `clock-frequencies-nclk` (type array; 1="pclk", 2="nclk", 3="sclk") — and falls back to the legacy 6-name table `{fclk,aclk,hclk,pclk,nclk,usbphyclk}` at AppleARMIO+160/+168/+176.

The avd node has **no `clock-frequencies` property** (live ioreg: only `clock-ids = <5d010000>`, `clock-gates = <2b010000 2c010000 2d010000>`, `power-gates = <same>`), and 0x15d is not in the pmgr "clocks" registry (max 0x149, see `ioreg_clocks_decoded.txt`). So `getClockFrequency(0x15d)` returns NULL/0 on macOS too. **Clock 0x15d is inert on macOS** — confirmed three ways (nomenclature ≠ HW table, no descriptor entry, no pmgr clocks entry).

---

## 2. `AppleARMPerformanceController::_enableDeviceClockGated` (0x91e3dd4) — full walk

Prologue: `x27 = this->[800] + cpu * 0x450` (per-cpu state block, cpu = `this->[1912]`); validates `clockId < this->[700]` and a device bitmap (`this->[728]`/`this->[736]`); early-out `0xe00002c2` if unknown. **Contains no MMIO instructions.** Execution order (enable path, gate = x22 where gate==0 means "query/derive"):

| # | site | action |
|---|---|---|
| 1 | 0x91e3e00–0x10 | trace perf-cpu state select (`movk #0x80` PA-fixup of the per-cpu block) |
| 2 | 0x91e3e24–0x38 | `this->[1944]` ? `0x88ecf60()` : x20=0 (trace timestamp) |
| 3 | 0x91e3e8c–0x90 | take lock `0x88e513c(this->[680])` |
| 4 | 0x91e3ec0–0xeec | **traceBufferAddEntry(0x2700c001, clockId, gate, −1, −1)** — PERF_CLOCK_GATE "begin" (vtable +0xa80 slot; decodes to idx 338 = `traceBufferAddEntryEjjjjj` by salt 0xcd2e) |
| 5 | 0x91e3ef0–0xf48 | vtable +0x9b8 slot (salt 0x797e → xnu fn 0x8e75a08): `(this, clockId, gate!=0)`; then vtable +0x9c0 slot (same target): `(this, ret, gate)` |
| 6 | 0x91e3f50–0xfa8 | vtable +0xa00 slot (idx 322 = `findNewVoltageState EjPj`): `(this, cpu, &x27->[0x41c])`; store ret `x27->[1084]` |
| 7 | 0x91e3fb4–0x40f4 | vtable +0xa08 (idx 323) then +0xa10 (idx 324) slots: `max(x27->[1052], x27->[1056]) → x27->[1048]` (statistics) |
| 8 | 0x91e3fbc–0x4018 | if `x27->[769]==1 && ret==0`: spin on `x27->[0x22]` byte via `this->[656]` vtable +0x200 slot (lock primitive) |
| 9 | 0x91e40f8–0x15c | **traceBufferAddEntry(0x2700c002, clockId, gate, −1, −1)** — PERF_CLOCK_GATE "end" |
| 10 | 0x91e4160–0x84 | unlock `0x88df798(this->[680])`; `0x88ecf60` timestamp delta → `0x8f8c8ac(this->[1944], delta)` |

For **gate=0** (disable) the same sequence runs with gate-derived values (x22 forced to the "off" selector, w23 = 0); the only divergence is the trace argument and the state-machine inputs downstream (step 5/6 pass `gate!=0`). All hardware effects are delegated through the vtable slots above; the ps-level writes happen inside ApplePMGR (§4), not here.

**How it uses the nomenclature table:** only as the label source for the 0x2700c001/2 trace events (via the traceBufferAddEntry machinery). It never indexes it by clock id.

**SMC/mailbox calls:** none.

## 3. `AppleARMIODevice::enableDeviceClock` (0x91d6db4) + vtable verification

```
enableDeviceClock(io, w1=enable, w2=gateIndex):        // arg order per validation + tail call
    if (io->[160] (clock-gates count) <= w2) return 0xe00002c7
    if (debugEnabled(io->[168] as "IODeviceClock" site)):
        0x8c90748(0x5070000, io, gateIndex, io->clockGates[gateIndex], enable, 0)   // kdebug PERF_CLOCK_GATE-style
    x0 = io->[136]  (provider, the AppleARMIO nub driver object)
    w1 = io->clockGates[gateIndex]        // for avd boot call: clock-gates[0] = 0x12b (AVD-SYS-V)
    w2 = enable
    tail-call [x0]->vtable[+0x8a8](x0, w1, w2)     // blraa salt 0x61db
```

Nothing else — **no locking, no refcounting, no power assertions** in this function itself (the gated locking lives one level up in `AppleARMPerformanceController::_enableDeviceClockGated`, and the trace-side `IODeviceClock` spin lock at `x27->[0x22]`).

**Vtable verification (slot 277 / +0x8a8):**

- `ZTV16AppleARMIODevice` = 0xfffffe0007df3f48; object vtable pointer = ZTV+0x10.
- AppleAVD `enableDeviceClockWrapper` (0x9243d74) loads `[io_vt + 0x8a8]` with call-site salt **0xd07d**; stored word at ZTV+0x8b8 (index 279) = `0x8011d07d021d2db4` → `(0x021d2db4 + 0x07004000) & 0xffffffff = 0x091d6db4 = AppleARMIODevice::enableDeviceClock` ✓. Salt match ✓. (Earlier "vtable[277]" = 0x8a8/8 without the +0x10 header correction; same slot.)
- The provider-side slot: `[provider]->vtable[+0x8a8]` with salt **0x61db**; the only stored word with that salt in any extracted kext = `ZTV10AppleARMIO+0x8b8` = `0x801161db021d23b4` → **0x091d63b0 = `AppleARMIO::enableDeviceClock` — an 8-byte stub `mov w0, #0xe00002c7; ret`** (ZTV10AppleARMIO idx 275–281: getClockName/getClockFrequency×3 are real; enableDeviceClock/enableDevicePower/enableDevicePinGroup are all stubs returning 0xe00002c7).

**Consequence:** on t8103 the io->vtable[277] enable path executes a kdebug trace and then a guaranteed-unsupported stub. AppleAVD ignores the return value, so macOS boot is unaffected — but there is **no clock-gate MMIO anywhere in this path to replicate on Linux**.

`AppleARMIODevice::setDevicePowerState` (0x91d6d20, states 5–8) and `enableDevicePower` (0x91d6e90) forward to the same provider slot (+0x8a8 / the enableDevicePower stub) with a small state map table @0x714a0e0 = {0,2,1,0} — equally inert.

## 4. ApplePMGR function objects

Common infrastructure (all verified by vtable salt decode, `ZTV9ApplePMGR` = 0x8037348, object vt = ZTV+0x10):

| obj vtable slot | function | semantics |
|---|---|---|
| +0xd80 (salt 0x73ce) | `readReg32(RegMap, offset)` | `*(u32*)(regmap_block_base + offset)` |
| +0xd88 (salt 0xfd0b) | `writeReg32(RegMap, offset, value)` | `*(u32*)(regmap_block_base + offset) = value` (store `str w23,[x8, w20, uxtw]` at 0x9ee8010) |
| +0xd90 (salt 0x007f) | `waitReg32(RegMap, offset, mask, value, timeout)` | poll `(reg & mask) == value` |
| +0xd98 (salt 0x8c12) | `isPsReg(RegMap, offset, x)` | bounds check helper |

Register-block base resolution (`ApplePMGR::getRegMap`, 0x9ed8ab8): regmap descriptors at `pm+0x2578`, 80 B each (`base + regmap*0x50`), 40 B region entries inside (`+ region*0x28`), region `[+24]` = mapped base; region count bound = `pm->[0x557c]` (0x5578+4). **All bases are DT-derived** (pmgr node `reg` property, 54 regions on t8103, see §6). `writePMGRSOCPwrGateReg(off, val, gate)` = `writeReg32(regmap = 0x65, off, val)`.

Function-object creation: `AppleARMFunction::withProvider(entry, name)` (0x91cff1c) → `getProperty(entry, name)` → OSData; **no property ⇒ NULL object**. `initWithTargetDataAndSymbol(provider, OSData, symbol)` then parses the property bytes per class; `[this+40]` = the ApplePMGR singleton (found via `ApplePMGR::gMetaClass`); all callFunction bodies funnel into `[[this+40]+6040]->runAction(gated_fn, …)` (IOCommandGate, vtable +0x1e8, salt 0xf9ff).

### 4a. `ApplePMGRFunctionClockGate::callFunction` (0x9f00164) — pmgr-side clock gate

```
callFunction(this, arg1, arg2, arg3):
    gate  = arg1[31:28]                      // ubfx x8, x1, #28, #4
    pm    = this->[40]
    if (gate >= pm->[0x557c]) panic(0x9f1acfc)
    if (arg2 & ~3)           panic(0x9f1ad40)   // arg2 must be 0..3
    state bit2 = arg2[1]; enable = arg2 & 1
    ApplePMGR::_enableDevice(pm, device = arg1 & 0xfffffff, enable, bit2, gate)
```

`_enableDevice` (0x9ef76a0): kdebug trace `0x2700c001` (same PERF_CLOCK_GATE id as §2) → `runAction(_enableDeviceGated 0x9ef7808, device, enable, bit2, gate)`.

`_enableDeviceGated` (0x9ef7808): DeviceData lookup (`_deviceIDToDeviceData`, 0x9ed8b3c; records are 0x118 B expanded from the 48 B DT "devices" records); checks DeviceData flags byte `[+0]` bits 4/5; computes `newState = enable ? (bit2 << 2) : 0xf` (i.e. on = 4, off = 0xf — same encoding as Linux `APPLE_PMGR_PS_CLKGATE/PWRGATE`); per-gate current-state byte at `pm+0x3562c + gate*0x2a8 + device`; on change → `_updateDeviceStatus` (0x9edaac4) which maintains the on/off counters (`pm+0x34498`/`pm+0x34b8c` + gate*0x2a8 arrays), calls `_checkNotifyPMP`, and finally `ApplePMGRNub::_notifyDeviceStatusChange` (0x9f0cb74) to registered clients. The ps-register commit itself uses the read/write/wait slot trio of the parent device's ps block (same scheme as 4c; the per-gate `×0x2a8` bookkeeping at pm+0x3562c is the gate-domain state).

**Virtual-gate scheme (what AVD-SYS-V 0x12b / VNOM 0x12c / VMAX 0x12d would write if used):** the device table (`ioreg_pmgr_devices_decoded.txt`) shows all three as `flags=0x10/0x50 VIRTUAL` — AVD-SYS-V's parent is AVD_SYS (ps 0x23b700410); VNOM/VMAX have **no parents**. A virtual gate carries no register of its own; enabling it walks the parent chain (AVD_SYS ps write); VNOM/VMAX are state-machine-only entries whose effect is aggregated voltage intent (see §5). On macOS, none of this is exercised for AVD because §3's stub intercepts the call before PMGR is ever reached.

`initWithTargetDataAndSymbol` (0x9f001b8) parses nothing register-specific — only stores the pmgr reference; the gate/device numbers arrive at callFunction time in arg1.

### 4b. `ApplePMGRFunctionSetPerfState::callFunction` (0x9f05b90) — perf floor

```
callFunction(this, arg1, arg2, arg3):
    arg1 = {u8 domain; …}  domain < 4 else panic(0x9f1b428)
    val  = *(u8*)arg2                      // 0 or 1 (boot/off vs fast-clock)
    pm   = this->[40]
    mask = (this->[52] >> (domain*8)) & 0xff     // per-domain mask byte from DT
    runAction(0x9ef9f34, offset = this->[48], mask, val, 0)
```

Gated action (0x9ef9f34): `device = *(u16*)(pm + 0x5598 + domain*2)` (per-domain device id table) → DeviceData; for each of DeviceData `[+8]`-count entries: `_setBit(deviceId, DeviceData->[168] + i*0x54, val)` (84 B perf-state bookkeeping records); special case `*(pm + 0x350dc + deviceId*4) == 0xf` → `_setBit(deviceId, entry + val*0x54, 1)`; then `_syncDevicePerfDomainRequirement` (0x9ef8070) → `_setDevicePerfState` (0x9efa084) which recomputes the aggregate over all devices sharing the domain and issues the ps-register update through the same `readReg32/writeReg32` scheme (no explicit ack poll in the traced portion; the ps BUSY/GO handshake is in the generic ps-write path).

`initWithTargetDataAndSymbol` (0x9f05c2c): **`this->[48] = OSData.u32[2]` (register offset), `this->[52] = OSData.u32[3]` (mask byte set, one byte per perf domain)** — that is the whole address formula: `reg = regmap_block(ps-style) + offset`, `byte_mask(domain)`.

**Runtime reality on t8103:** the string `set_perf_state_floor` appears **nowhere in the device tree** (verified over the full ioreg dump), and `AppleARMFunction::withProvider` returns NULL without the property — so AppleAVD's floor handle is NULL and this object is **never invoked**. The ps[27:24] floor = 0xf is instead programmed by PMGR's own init, and `AVD_POWER_RE.md` already verified `/dev/mem` reads 0xf on Linux j293. **Not the gap.**

### 4c. `ApplePMGRFunctionAssertReset::assertReset(bool)` (0x9f00754) — the ARST object

DT binding: avd node `function-avd_reset = <8b000000 "ARST" 66000000>` (type 0x8b phandle-tag, 4CC "ARST", arg 0x66). `AppleARMFunctionAssertReset::withProvider` (0x91d0700) matches the 4CC and instantiates `ApplePMGRFunctionAssertReset`.

```
assertReset(this, w1):
    if (w1 == 0) return 0              // DEASSERT = pure no-op
    pm = this->[40]
    runAction(0x9ef99bc, devId = this->[48], shift = this->[52], 0, 0)
```

`initWithTargetDataAndSymbol` (0x9f007cc): **`this->[48] = OSData.u32[2] & 0xffff` (= 0x66), `this->[52] = OSData.u32[2] >> 28` (= 0)** — arg = `(shift << 28) | device_table_id`.

Gated action (0x9ef99bc): DeviceData(0x66) → `psidx = DeviceData->[11]` (= 0x0c), `off = DeviceData->[10]` (= 0x02), `val = DeviceData->[15] >> 5 & 1` (raw DT flags byte for AVD_SYS = 0x22 → bit5 = **1**; medium confidence the expanded +15 equals the raw flags byte). `_setPSReset(psidx=0x0c, off=0x02, devId=0x66, shift=0, val=1)` under `pm->[21304]` lock, then `IOSleep(100)` and a completion poll over the DeviceData `[+0x1c]` sub-entry list (76 B records at `pm->[21728]`, index table u16 at `pm->[0x54ec]`, count gate `pm->[0x54dc]`).

`_setPSReset` (0x9eec5c4) — the exact register program for AVD_SYS (regmap 0 block = 0x3b700000, triplet[12] offset 0x400, +off·8 = 0x410):

| step | op | address | value | note |
|---|---|---|---|---|
| 0 | readReg32 | 0x23b700410 | — | old |
| 1 | writeReg32 | 0x23b700410 | `(old & ~0x300) \| 0x400` | clear WAS_CLKGATED(9)/WAS_PWRGATED(8) (w1c), set DEV_DISABLE(10) |
| 2 | waitReg32 mask=0x800 val=0 tmo=720 | 0x23b700410 | — | BUSY(11) must clear |
| 3 | writeReg32 | 0x23b700410 | `(old & ~0x300) \| 0x80000400` | add RESET/GO(31) |
| 4 | waitReg32 mask=0x80000000 val=1 tmo=720 | 0x23b700410 | — | wait "accepted" |
| 5 | writeReg32 | 0x23b700410 | `(old & ~0x300) \| 0x400` | drop GO |
| 6 | waitReg32 mask=0x80000000 val=0 tmo=720 | 0x23b700410 | — | GO cleared |

(val=0 path skips steps 4–5's first wait and the intermediate rewrite; AVD uses val=1.) Bit names per Linux `drivers/pmdomain/apple/pmgr-pwrstate.c`: bit31 = RESET (GO), bit11 = BUSY, bit10 = DEV_DISABLE, bits 9:8 = WAS_CLKGATED/WAS_PWRGATED, 27:24 = PS_AUTO floor, 3:0 = PS_TARGET.

Semantics: assertReset(true) = **reset-pulse the AVD_SYS power domain through its own ps register** (disable-and-reset with GO handshake, leaving DEV_DISABLE set; the subsequent power-state-2 request re-enables). This is exactly what Linux's `apple_pmgr_reset_reset()` does via the reset controller (`update_bits(FLAGS|DEV_DISABLE→DEV_DISABLE)` then `FLAGS|RESET→RESET`), except Linux omits the BUSY/GO ack polls and clears DEV_DISABLE on deassert. macOS never calls assertReset(false) (all vtable[41] sites use w1=1; `AVD_POWER_RE.md` §3) and does **not** call ARST on the boot path at all — PwmReset is the fw-recovery path.

## 5. SMC rails — do VNOM/VMAX need an explicit SMC message? **No.**

Evidence (symbols + strings only, per plan):

1. The strings `vnom` / `vmax` occur **nowhere** in `AppleSMC`, `AppleSPMI`, `AppleSPMIPMU` (symbols or strings). They exist only as pmgr device-table records (flags 0x50, VIRTUAL, no parent — `ioreg_pmgr_devices_decoded.txt` lines 11–12).
2. `AppleSMC` contains the PMU mailbox stack (`AppleSMCPMU`, `AppleAOPSMC`, `ApplePMC::readPMCMailbox`) but its voltage-related surface is battery/accessory oriented ("SCHG: cannot read battery voltage", "resolveMaxNominalVoltage") — nothing keyed to SoC power domains or the AVD rails.
3. `ApplePMGR` voltage/DVFS traffic to the always-on PMC goes through the **pmgr mailbox as DVFS hints**: strings `PTD-SOC-DEV-DVFS: Device=0x%x level=%d msg=0x%llx`, `_dvfsMsg`, `_bwrMsg` — perf-state hints, not rail enables, and issued from the perf-state path (§4b), not from device power-on.
4. On t8103 the voltage for a power domain is a function of its **ps register** (PS_AUTO 27:24 floor + PS_MIN 19:16, set at PMGR init to 0xf) — the PMC applies rails automatically when the ps block is programmed. There is no per-device "enable rail" SMC command in any extracted kext.

**Conclusion: rail voltage follows ps-register programming; AVD power-on does not require an explicit SMC message.** macOS sends none on the AVD path, and none is required on Linux beyond the genpd ps write. (Medium-high confidence; the PMC firmware itself is not in these kexts.)

## 6. Linux patch spec

### 6.1 What the driver should do before `avd_boot()` — and what it should *not* do

This round's central result is negative in the most useful way: **macOS performs no clock-gate MMIO, no SMC message, and no perf-floor call for AVD on t8103.** The only macOS-vs-Linux hardware actions on the enable path are:

1. **ps power-on of AVD_SYS with GO handshake** — done on Linux by genpd (`apple_pmgr_ps_set(ps_avd_sys, PS_ACTIVE=0xf, auto_enable=true)`) via `pm_runtime_resume_and_get()` in `avd_reset()`. macOS equivalent is the IOKit power-state=2 chain. **Already at parity** (verified: floor bits 0xf via /dev/mem, `AVD_POWER_RE.md` TL;DR). Patch requirement: none — but log the ps readback at boot (the driver already has AVDBG for this).
2. **ARST pulse (PwmReset only, not cold boot)** — Linux equivalent `reset_control_reset(avd->rstc)` → `apple_pmgr_reset_reset()`. Parity except macOS's ack polls and the DEV_DISABLE left set. If the j293 hang persists, align exactly: after `regmap_update_bits(RESET)` add `regmap_read_poll_timeout(BUSY, 0)` + `(RESET, 1)` + `(RESET, 0)` polls at 0x23b700410, and leave DEV_DISABLE set until the genpd re-power. Low priority — macOS doesn't do this at boot either.
3. **Delays:** macOS setPowerStateOn has a ~726 ms window after the clock-wrapper call and before fw upload (the `0x8c90748(0x2b680128,…)` site — note this helper is also the kdebug-trace function used for the PERF_CLOCK_GATE trace ids 0x2700c001/2, so the 726 ms may be a measured region rather than a literal sleep; treat as "macOS waits a while here"), and polls ADS-valid ~400 ms / 5 s before declaring the module up. Linux `avd_boot()` currently uploads fw immediately after reset. **Actionable patch item:** insert `msleep(700)` (start with 726) after the reset/power-on in `avd_reset()`/`avd_runtime_resume()` before `avd_boot()`, and if FLAG0 still times out, replicate `waitValidADSStatus` (poll ctrl+0x1002010 for `(v & 0x7f0) == 0x7f0`, 10 ms × 500) as a diagnostic before fw upload — macOS observes ADS 0x0→0x7f0 ~400 ms after start *without* uploading firmware first, which suggests on j293 the CM3 boot is either slow or the fw upload itself is the failing step.
4. **Do not add** clock-gate writes for "clock id 1" or "0x15d" — there is no register. Do not add SMC messages — none exist. Do not invent writes from the nomenclature table.

### 6.2 Hardcoded vs DT-derived bases

| resource | macOS source | Linux source |
|---|---|---|
| pmgr reg block 0x23b700000 | DT pmgr `reg[0]` = 0x3b700000 + bus 0x200000000 | pmgr node `reg` → `apple-pmgr` regmap (already DT) |
| ps offsets (0x410 for AVD_SYS) | DT pmgr `ps-regs` triplet[12] = {regmap 0, 0x400} + device `off`(0x02)·8 | t8103.dtsi `ps_avd_sys` — verify it decodes to offset 0x410 in the pmgr syscon |
| per-device psidx/off | DT pmgr `devices` record 0x66 bytes [10],[11] | not parsed by Linux (offsets come from dtsi ps nodes) |
| AVD MMIO window | DT `reg` = 0x268000000 + 0x1404000 (errata: unified) | already unified in `avd-regs.h` |
| `regmap 0x65` SOC pwr-gate block | DT pmgr `reg` region | n/a (no Linux user) |

Patch rule: **derive 0x23b700410 from the dtsi/ps node, not from a literal**; if a literal is used for a bring-up experiment, it must be `0x23b700410` exactly (ps-regs triplet 12 + 0x10).

### 6.3 Dark/hanging-region safety check

Earlier j293 bisection (see driver comments `avd-hw.c`): ADS 0x269000000 window — write 0x01 ⇒ panic, read 0x40 ⇒ hang; wrap 0x269140000 "dark"; DMA 0x2691xxxxx "dark".

- **All pmgr-side writes from this analysis target 0x23b700410** (pmgr block) — outside the AVD aperture, **no overlap with any dark region**. Safe to experiment.
- **macOS's only AVD-aperture boot writes** are the Viola DeviceInit 7 writes (offsets relative to the unified 0x268000000 window, per `AVD_POWER_RE.md` erratum 3): **0x1400018=1 (→0x269140018), 0x1070000=0 (→0x269070000), 0x11001cc=0x20, 0x110e6d0/d4/710/714=0xffffffff (→0x26910e6d0…)**. These land in exactly the regions the bisection called dark ("wrap 0x269140000", "DMA 0x2691xxxxx"). **Contradiction:** macOS writes them at every boot on this very machine (j293) and the driver works. Conclusion: "dark" cannot mean "writes fault/hang" — most likely those windows were not mapped (or mapped with wrong attributes) in the failing Linux experiment. **Re-test the wrap/DMA writes before trusting the bisection**; stage 3 (wrap init table) of `avd_t8103_preinit` should be re-tried in isolation now that macOS's table is confirmed byte-exact.
- The one *confirmed*-dangerous write remains the ADS power write 0x269000000←0x01 (stage 0) — macOS does **not** do it on Viola (erratum 2: power-state request instead). Keep it disabled.

### 6.4 Suggested experiment order (j293 cold boot, one variable per boot, per `AVD_LIVE_TEST_LOG.md` rules)

1. Baseline dmesg capture: AVDBG ps dump (preinit_mask bit5) + boot trace — confirm ps_avd_sys genpd actually powers on (ps[3:0] target f, AUTO bit set).
2. Add `msleep(726)` before fw upload → test.
3. If FLAG0 still 0: add ADS-valid poll diagnostic (0x1002010 & 0x7f0) before fw upload, dump result — tells whether the CM3 is alive-but-slow vs never started.
4. Retry wrap-init stage alone (bit3) now that "dark" is in question.
5. Only then consider the full ARST-with-ack-poll sequence (§4c) before power-on.

## Appendix A — key disassembly anchors

| item | address |
|---|---|
| gAppleARMPerformanceControllerNomenclature | DATA_CONST 0x7df9de8 (file 0xc9b0), 50 entries |
| AppleARMPerformanceController::_enableDeviceClockGated | TEXT_EXEC 0x91e3dd4 |
| AppleARMIODevice::enableDeviceClock / setDevicePowerState | 0x91d6db4 / 0x91d6d20 |
| AppleARMIO::enableDeviceClock (STUB) | 0x91d63b0 (ZTV10AppleARMIO idx 279, salt 0x61db) |
| state map table {0,2,1,0} | __TEXT 0x714a0e0 |
| ApplePMGRFunctionClockGate::callFunction | 0x9f00164 |
| ApplePMGR::_enableDevice / _enableDeviceGated / _updateDeviceStatus | 0x9ef76a0 / 0x9ef7808 / 0x9edaac4 |
| ApplePMGRFunctionSetPerfState::callFunction + gated action | 0x9f05b90 / 0x9ef9f34 |
| ApplePMGRFunctionAssertReset::assertReset + gated action + _setPSReset | 0x9f00754 / 0x9ef99bc / 0x9eec5c4 |
| readReg32 / writeReg32 / waitReg32 / getRegMap | 0x9ee7ea4 / 0x9ee7f24 / 0x9ee8108 / 0x9ed8ab8 |
| kdebug helper (PERF_CLOCK_GATE trace ids 0x2700c001/2) | xnu 0x8c90748 |
| ARST target register (validated) | 0x23b700410 = pmgr reg[0] 0x3b700000 + ps-regs[12] 0x400 + off 0x02·8 |
