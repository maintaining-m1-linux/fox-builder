# AppleAVD power/enable path RE — full report (j293 Viola, macOS 15.7.1 v865)

Date: 2026-10-05. Static disasm of rev/AppleAVD.__TEXT_EXEC.bin etc.
Method notes (incl. the corrected blraa-salt slot table) in §0 below;
errata for DISASM_INIT_PATH.md at the end.

## TL;DR for the Linux bring-up

macOS's j293 enable path contains **no hidden AVD-complex MMIO write at
boot**. On Viola, "DevicePwrOn" (A2) does NOT write 0x1000000<-0xfff — it
issues an IOKit power-state=2 request. ARST is reset-only, never boot. The
ADS poll failure path is log-only. The only remaining macOS-only enabling
surface for the hard-hanging blocks is:

- the **clock gate behind `io->vtable[277]`** (AppleARMIODevice, clock id 1
  = boot clock; AppleARMPlatform.kext), and
- whatever ApplePMGR/AppleSMC do for the virtual rails
  (AVD-SYS-V / AVD-SOC-VNOM / AVD-SOC-VMAX) and the function objects.

Everything else (AVD_SYS/MMX power, perf floor bits 27:24) is already at
macOS parity on Linux (verified via /dev/mem: floor bits already 0xf).

## §0 Decoding-rule refinements (verified against 4 vtables)

- Target rule unchanged: stored_low32 + 0x07004000 -> TEXT_EXEC address;
  signature bits [63:48]=0x8011 ignored.
- Salt correction: bits [47:32] of stored vtable words follow one global
  per-slot-position sequence. blraa salt -> absolute slot: 0x5a12->2,
  0xa84f->3, 0x66fa->4, 0x1f78->5, 0xfe2c->6, 0x30c5->7, 0x63cf->8,
  0x9368->9, 0x244a->10, 0x5840->11, 0x28f7->12, 0x11fc->13, 0xeaea->14,
  0x00c0->15, 0xaafe->16, 0x0bd0->17, 0xdc5b->18, 0x3553->19, 0xacbe->20,
  0xca7e->21. This disproves the slot guesses in DISASM_INIT_PATH.md §7.

## §1 enableDeviceClockWrapper (0x9243d74)

Signature: `enableDeviceClockWrapper(this, io, w2, w3, w4)`,
`io = [this+0xf8 + core*8]` (per-core AppleARMIODevice*):

```
x22 = this + 0x17590
x0  = [x22]                       // m_setPerfStateFunctionHandle
if (x0 == 0)        -> io->vtable[277](io, w2, w3)            [0x9243e14-6c]
if (w4 == 0)        -> return
if (w2==1 && w3==0) -> io->vtable[277](io, 1, 0)              [0x9243dcc-e00]
                       stack {u32=0; u32=0; bool=0}
else                -> stack {u32=(w2==0?0:w3); u32=0; bool=0} [0x9243e70]
perfobj->vtable[40](perfobj, &field2, &field1, &flag)          [0x9243e80-b4]
if (ret) log "Calling function-set_perf_state_floor failed !"
if ((w3|w2)==0) -> io->vtable[277](io, 0, 0)                  [0x9243ef0-f24]
```

- No MMIO, no SMC message buffer, no doorbell — pure delegation.
- [this+0x17590] = the "function-set_perf_state_floor" function object,
  created in AppleAVD::start (0x923ffec): bl 0x91cff1c(this,
  "function-set_perf_state_floor") at 0x9241130, stored [x23,#2808],
  x23=this+0x16a98 -> this+0x17590.
- Call sites decode: w3 = enable flag, w2 = clock id (1 = boot clock),
  w4 = master enable. Floor payload {u32 val; u32; bool}, val=0 on boot/off,
  1 on fast-clock. The chip-specific numbers (42/129/36/32) are the clock
  FREQUENCY for io->vtable[277](0, clkVal) in enableFastClockInternal —
  not a pmgr floor.

## §2 set_perf_state_floor value

Only ever 0 (boot/off) or 1 (fast-clock). Reaches hardware only via the
function object's vtable[40] — a provider in another kext, never direct
MMIO. Floor bits (pmgr ps 27:24) already 0xf on Linux — not the gap.

## §3 PwmReset / ARST

Runtime wrap-ctrl class is **CAvdWrapCtrlViola** (vtable 0x7e187c0, built by
C2 at 0x925c868 from AppleAVD::start 0x9242388, stored [this+0xe8+core*8]):

- slot4 = DeviceInit 0x925d1f4 (real Phase C): writes via WriteRegister32
  (base [wrap+16]): 0x1400018=1, 0x1070000=0, 0x11001cc=0x20,
  0x110e6d0/d4/710/714 = 0xffffffff.
- slot5 = DevicePwrOn 0x925d1c0 -> slot21 0x925dc98: bl 0x922c7d4
  ([wrap+104]+4, 2); tail 0x922c964([wrap+104]+4) -> out-of-kext
  0x8f3e91c(ptr,4,3) -> obj; obj->vtable[67](0), vtable[69](0) -> child,
  child->vtable[39]() -> p; store/read power-state value 2 at [p];
  obj->vtable[68](0), vtable[5]. **No MMIO — IOKit power-state=2 request.**
- slot8 = PwmReset 0x925d104:
  x8 = [wrap+32] (function-avd_reset object; 0 -> log error)
  bl waitForOutstandingAXITransaction (0x925cc14)
  x0->vtable[41] (obj+0x148) with w1=1        [0x925d13c-58]
  [wrap+96]; w1=1; tail AVDDart::setActive (0x925ab14)
  All 4 vtable[41] call sites use w1=1; **no deassert (w1=0) exists**.
  The write to pmgr+0x22c happens inside the function object's slot41 —
  another kext. [wrap+32] created in C2 via bl 0x91d0700(provider,
  "function-avd_reset"); [wrap+40] gets function-mcc_dataset (bl 0x91cff1c);
  [wrap+56] gets constant 0xf3000000ff from __TEXT 0x7199708.

## §4 ADS valid poll (waitValidADSStatus 0x9259410)

- Register offset 0x1002010 via ReadRegister32 (0x923dde0 -> regIO
  [ApComm+0xcc0] -> vtable[3], mapped 0x268000000 window).
- Mask 0x7f0, success (val & 0x7f0) == 0x7f0.
- First sample, then sleep 10 ms x max 0x1f4=500 iterations (~5 s).
- Strings: "AVD ADS module valid bits not set yet! Waiting until valid.
  status=0x%x"; "AVD ADS status valid bits set! status=0x%x";
  "Timed out waiting for ADS STATUS bits to become valid, timeoutCount=%u,
  status=0x%x".
- **Failure path: log only, then return. No retry, no ARST, no
  escalation.** Caller ignores the result.

## §5 setPowerStateOn (0x924a660) — ordered external actions

1. enableDeviceClockWrapper(this, io, 1, 0, 1) — A1, first & only pre-action.
2. bl 0x922ccb8([[this+0x160a8]][0], core, 1, 0) — analytics/lock helper.
3. bl 0x8c90748(0x2b680128, 0,0,0,0,0) — ~726 ms delay (not 164 ms).
4. io->vtable[278](io, 1, 0, 0).
5. wrap->slot[5](0) = Viola DevicePwrOn (power-state=2 chain).
6. AVDDart::setActive / unmapDeferralList.
7. PriorityQueue setAVDCtrlIdle(1), queue drain.
8. ApComm restoreM3context(0) — fw load + M3 boot.
9. Second delay; queue drain.
10. wrap->slot[4](0) = Viola DeviceInit (the 7 writes).
11. bl 0x924ad3c(this, core) under lock.
12. If [this+0x16cce]==0: waitValidADSStatus.

## §6 pmgr MMIO constants

None. No 0x23b7xxxxx constants anywhere in the kext — all pmgr/SMC access
is delegated to function objects and AppleARMIODevice. Only hardcoded
physical addresses: __TEXT 0x71c92c0 = {0x268000000, 0x269000000} (ApComm
ctor 0x9250940, w5==0 = t8103 window); other chips use {0x226000000,
0x225000000}.

## §7 Next extraction targets

| Site | Expected owner |
|---|---|
| io->vtable[277]/[278] (clock gate / clock freq / power) | AppleARMPlatform.kext (AppleARMIODevice) |
| function objects vtable[40]/[41] (perf floor, ARST) | ApplePMGR.kext / AppleT8103PMGR.kext / AppleSMC.kext |
| A2 chain 0x8f3e91c + vtable[67..69]/[39]/[5] | xnu IOKit |
| 0x8e8996c log, 0x8c90748 delay, 0x8eb37f8 sleep, OSNumber helpers | xnu libkern |

Extract from the SAME kernelcache (macOS 15.7.1) using rev/kc_extract.rb:
com.apple.driver.AppleARMPlatform, com.apple.driver.ApplePMGR,
com.apple.driver.AppleT8103PMGR, com.apple.driver.AppleSMC.
(Bins stay local-only per the rev/ binary policy.)

## Errata for DISASM_INIT_PATH.md

1. Runtime wrap-ctrl = CAvdWrapCtrlViola (vtable 0x7e187c0): slot4 =
   DeviceInit, slot5 = DevicePwrOn, slot8 = PwmReset. The 0x9238xxx set is
   the base class (not on the runtime power-on path).
2. A2 does NOT write 0x1000000<-0xfff on Viola — power-state=2 request.
   The 0xfff write may still matter for Linux (m1n1 does it on j274), but
   macOS-j293 does not do it at boot.
3. Viola DeviceInit = 7 writes: 0x1400018=1, 0x1070000=0, 0x11001cc=0x20,
   0x110e6d0/d4/710/714=0xffffffff.
4. Use the salt->slot table in §0 for all future virtual-call work.
5. setPowerStateOn delay = 0x2b680128 (~726 ms), not 164 ms.
