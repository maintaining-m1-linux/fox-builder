# Linux-side disassembly results — t8103 AVD init path (2026-10-02)

Analyzed on the Linux side per `LINUX_HANDOFF.en.md`, using
`aarch64-linux-gnu-objdump` on `rev/AppleAVD.__TEXT_EXEC.bin` + vtables in
`rev/AppleAVD.__DATA_CONST.bin`.

## Vtable pointer encoding (needed to read any __DATA_CONST pointer)

On-disk arm64e KC pointers keep the target's low 32 bits; for code pointers
inside AppleAVD's own __TEXT_EXEC the low-32 file value + `0x07004000` yields
the true KC vmaddr (verified against 12+ consecutive vtable slots). Data
pointers use their own segment delta. The blraa salt for a virtual call at
slot N = `(slot address) | (0x???? << 48)`, the `0x????` matching bits
[47:32] of the stored slot word. Signature bits [63:48] (`0x8011`) are
ignored for analysis.

## Memory map reconciliation (answers the §4 "delta vs Linux map" note)

Apple `avd` node `reg` (16 raw bytes from ioreg, little-endian u64 pair) =

    addr = 0x68000000  (+ SoC base 0x200000000) -> 0x268000000
    size = 0x1404000

i.e. macOS maps **one 20.5 MB window at 0x268000000**; the register offset
table in `CAvdMcpuViola::C2` (constants at `__TEXT` 0x71f80b0, base addend
0x1080000) then lands exactly on the Asahi-split regions:

    0x268000000 + 0x1080000 + 0x8008 = 0x269098008  (mbox + 0x08, RUN_CTRL)
    0x268000000 + 0x1080000 + 0x8090 = 0x269098090  (mbox + 0x90, FLAG0)

The `IODeviceMemory 0x269010000+0x4000` in §4 is the dart-avd range
(= `iommu@269010000` in Asahi `t8103.dtsi`), not the AVD window.

t8103 instantiates **CAvdMcpuViola** (vtable `__ZTV13CAvdMcpuViola`), which
inherits `disableMCPUE`/`enableMCPUE`/`WaitForM3Boot` from `CAvdM3Mcpu`
(Cortex-M3 coprocessor class). Chip device type 26 (0x1a) selects it in the
`AppleAVD::start` factory switch (disasm at 0x9241f0c-0x9242054).

## Ordered MMIO write list — M3 boot path (all offsets relative to mbox
## 0x269098000)

`CAvdMcpu::start()` = **disableMCPUE() -> enableMCPUE() -> WaitForM3Boot()**
(disasm 0x9259c70; slots 8, 9, 7 of the Mcpu vtable).

1. `CAvdM3Mcpu::disableMCPUE()` (0x92263f0), also run once earlier inside
   `CAvdMcpu::init()` before the firmware upload:

   | order | reg    | value | meaning                     |
   |-------|--------|-------|-----------------------------|
   | 1     | +0x08  | 0xe   | RUN_CTRL = STOP             |
   | 2     | +0x98  | 1     | FLAG0_CLR                   |
   | 3     | +0x10  | 0     | IRQ/status                  |
   | 4     | +0x50  | 0     | MCPUE control               |

2. `CAvdMcpu::loadFirmwareImage()` (0x9259bf4): memcpy firmware to the code
   region (0x269080000), zero-fill up to 0xc000.

3. `CAvdM3Mcpu::enableMCPUE()` (0x9226458), in this exact order:

   | order | reg    | value | meaning                                   |
   |-------|--------|-------|-------------------------------------------|
   | 1     | +0x50  | 1     | MCPUE control                             |
   | 2     | +0x74  | 1     | MCPUE control                             |
   | 3     | +0x68  | 1     | MCPUE control                             |
   | 4     | +0x5c  | 1     | MBOX1_STATUS enable (= Linux AVD_MBOX_ENABLE)|
   | 5     | +0x48  | \|= 8 | IRQ enable bit3 (enableRXInterrupt(0);    |
   |       |        |       | identical to Linux AVD_MBOX1_NOT_EMPTY)   |
   | 6     | +0x08  | 1     | RUN_CTRL = RUN                            |

4. `CAvdM3Mcpu::WaitForM3Boot()` (0x9226510): polls +0x90 (FLAG0) until == 1.
   Same register and value as the Linux driver's poll.

## Linux driver diff and patch (drivers/media/platform/apple/avd)

Old `avd_boot()` wrote only: +0x5c=1, +0x48=8, +0x08=1, then polled FLAG0.
Missing vs macOS: the disable pre-step (+0x08=0xe, +0x98=1, +0x10=0, +0x50=0)
and the three MCPUE control writes (+0x50=1, +0x74=1, +0x68=1).  The driver
now mirrors the full macOS sequence (commit "media: apple: avd: apply macOS
enable/disableMCPUE sequence" on the 7.1.13-fairydust branch).

These three registers sit in the mailbox page between MBOX1_RETRIEVE (0x64)
and FLAG0 (0x90); macOS writes them on *every* boot as part of "enableMCPUE"
(the M-coprocessor power switch), and they are the only M3-boot-related MMIO
that Linux never performed.  Machines whose boot chain already has them
enabled (j274) are unaffected; on j293 the CM3 never sets FLAG0 without them.

## Power sequencing order — `AppleAVD::setPowerStateOn(u32)` (0x924a660)

1. `enableDeviceClockWrapper(avd_dev, 1, 0, 1)` — enables the DT clocks
   (`clock-ids = [0x15d]`, `clock-gates = [0x12a,0x12c,0x12d]`) through the
   AppleARMIODevice clock method (vtable +0x8a8). **No Linux equivalent**
   (the driver requests no clocks; Asahi kernels have no pmgr clk-gate
   consumer for these). Left for later if the register sequence alone is
   not sufficient.
2. IODelay (~164 ms), then the clock method again (1,0,0).
3. `AVDDart::setActive(dart, 1)` + `AVDDart::unmapDeferralList()` (IOMMU).
4. `PriorityQueue::setAVDCtrlIdle(core, 1)` + drain pending queue entries.
5. `CAvdApComm::restoreM3context(0)` -> `CAvdMcpu::init(0)` (disableMCPUE,
   clearDMEM, loadFirmwareImage) then `CAvdMcpu::start()` (the boot sequence
   above).
6. `reqMemCacheInit(state)`.

## Other findings asked for in the handoff

- `CAvdWrapCtrlViola::HReset()` (0x9237e90) is a **no-op returning 0** on
  Viola — the pmgr ARST hard-reset path is not the missing piece.
- `CAvdWrapCtrlViola::PwmReset()` (0x92383e8): waitForOutstandingAXITransaction
  -> reset service call ([obj+32], the `function-avd_reset` pmgr function,
  vtable +0x148, arg 1) -> `AVDDart::setActive(dart, 1)`.
- `CAvdWrapCtrlViola::getAdsStatus()` (0x9238d68) returns -1 unconditionally
  on Viola; the ADS block (status 0x0 -> 0x7f0, mask 0x7f0 seen in the boot
  log) is polled through the ApComm layer (`CAvdApComm*::waitValidADSStatus`,
  e.g. slot calls at 0x922b620/0x9270224), not wrap-ctrl MMIO.
- `CAvdWrapCtrlViola::DeviceInit` (0x92384d8) writes, relative to the same
  0x268000000 window: +0x1400018=1, +0x1070000=0, +0x1104064=3,
  +0x110cac8=0xffffffff, +0x110cc90=0xffffffff, +0x110cc94=0xffffffff,
  +0x110cd30=0xffffffff, +0x110cd34=0xffffffff (irq masks etc.; run during
  device init, not part of the M3 boot gate).
- `CAvdWrapCtrlViola::DevicePwrOn` (0x92384a4): +0x1000000 = 0xfff.
- `CAvdMcpuViola::EnableMailboxInterrupts()` = WriteRegister32(+0x48, 8);
  sendCmd doorbell registers: +0x54 (arg==0) / +0x6c (arg!=0).

## Residual risks / next steps if FLAG0 still does not set

1. The pmgr clock gates (0x15d / 0x12a,0x12c,0x12d) — implement via a
   pmgr clk-gate consumer or an m1n1/ESP-side enable; check whether the
   +0x50/+0x68/+0x74 writes alone wake the CM3 first.
2. Firmware-side: macOS runs the same avd-fw-v2-t0 open-source firmware
   entry layout; FLAG0 polling register/values match Linux exactly, so the
   remaining surface is the enable path documented above.
