# AVD macOS findings — MacBookPro17,1 (J293, t8103), macOS 15.7.1 (24G231)

Collected 2026-10-02 per `MACOS_REVERSE.md`. Machine booted macOS 15.7.1
(Darwin 24.6.0, xnu-11417.140.69.701.11~1) — **deviation from the guide's
assumed 13.5/22G74 baseline** (this install is newer; firmware baseline in
`research-avd-bringup.md` was captured from the ESP on 2026-09-25 and is
independent of this macOS version). No Xcode CLT on this install (disk
constraint) — all binutils replaced by ruby scripts in `rev/`.

## 1. Environment snapshot → `rev/env.txt`

- MacBookPro17,1, hw.targettype J293, Apple M1 (T8103), 8-core, 8 GB RAM.
- macOS 15.7.1 (24G231), KernelManagement host-463.100.7 (from kernelcache IM4P).

## 2. Kext location & identity

- Bundle: `/System/Library/Extensions/AppleAVD.kext` — **on-disk stub**
  (Info.plist + _CodeSignature only, no executable; sealed-KC model).
- Real binary inside the **Preboot arm64e kernelcache**:
  `/System/Volumes/Preboot/8D5F46FC-080B-4F96-B47D-0F3FA3591BF3/boot/3963BA70.../System/Library/Caches/com.apple.kernelcaches/kernelcache`
  - Wrapped in IM4P (`type "krnl"`, desc `KernelManagement_host-463.100.7`);
    **LZFSE-compressed** (`bvx2` tag), NOT encrypted (no KBAG). 29,543,840 B
    compressed → 112,984,064 B mach-o. Decoded with
    `rev/im4p_decode.rb` (ruby + libcompression via Fiddle).
  - sha256 `726c673d7c5a6a9c5dffb19f81cc115b44f7c9b5e450113a5d561e33ba014d0a` (`rev/kc_sha256.txt`).
- kext identity: `com.apple.driver.AppleAVD` **v865** (BuildVersion 533,
  SourceVersion 865000000000000, built on DTPlatformBuild 24G211/macOS 15.7,
  "AppleAVD 865 Copyright 2016-2022").
  UUID 04EF6319-4DEF-36CD-B186-43263CBE6BE9.
- Runtime load: `0xfffffe000715a500` size `0xe44f8` (`kmutil showloaded`) —
  equals the fileset vmaddr in the KC (slide 0 for this boot).
- Extraction: `rev/kc_extract.rb`. KC mechanics discovered (reusable):
  - `LC_FILESET_ENTRY.fileoff` is a placeholder (0x20); locate entries via
    the main header's `LC_SEGMENT_64` covering the entry vmaddr.
  - Each kext's inner `LC_SEGMENT_64`s carry **final** KC vmaddrs and file
    offsets; kext segments are splayed (not contiguous). Section `fileoff`
    high nibbles are flags; low bits are the KC file offset.
  - Per-segment flat binaries for analysis: `rev/AppleAVD.__{TEXT,TEXT_EXEC,DATA,DATA_CONST}.bin`
    (+ `rev/AppleAVD.slim.map.txt`, `rev/extracted/AppleAVD.map.txt`).
  - On-disk `/System/Library/KernelCollections/*.kc` are **x86_64** (Rosetta);
    the booted arm64e cache lives only in Preboot.

## 3. Firmware

- ioreg publishes: `FirmwareSize = 34676 (0x8774)`, `FirmwareVersion = 0x89255e13`.
- **Firmware blob NOT found anywhere readable on disk.** Checked: kext image
  (no IM4P/bvx/compression magics, longest non-zero run 0x4b1 — nothing
  embedded), whole 113 MB kernelcache (no IM4P, no CM3 vector-table signature),
  `/usr/share/firmware` (only bluetooth/hidfw/isp/multitouch/wifi/wpan),
  `/usr/standalone`, Preboot dirs, `/Library/Apple`, system-wide
  exact-size(34676) find, MobileAsset dirs. No `firmware*` property on any
  IOService node; no RTBuddyDriver class instance in the registry.
- Boot log (`rev/avd_kernel_log.txt`): `start: M3 Retention Not Used!` then
  `waitValidADSStatus(): AVD ADS module valid bits not set yet! status=0x0`
  → 400 ms later `status=0x7f0`. The coprocessor firmware appears to be
  provisioned by the boot chain / retained silicon state, not from a macOS
  file — macOS only *verifies* it via the ADS status block.
- Consequence: a byte-level diff vs Asahi `avd-fw-v2-t0.bin` is not possible
  from macOS. Firmware-level comparison stays blocked (as before, the only
  manipulable image is Asahi's open-source fw).

## 4. IORegistry (`rev/ioreg_avd*.txt`, `rev/ioreg_avd_decoded.txt`)

AppleAVD node: `IOPowerManagement{MaxPowerState 1, CurrentPowerState 0(idle)}`,
`AVDKextType 1`, decode caps (H264 levels to 5.2, HEVC to 5.1/186),
`IONameMatched avd,t8103`, sleep/wake actions registered, `IOMatchedAtBoot`.

Provider `avd@68000000` (AppleARMIODevice) DT properties (base64-decoded):
- `IODeviceMemory`: **addr 10351607808 (0x269010000), len 16384** — the only
  published MMIO range. *Delta vs Linux map*: Linux apple-avd uses mbox
  0x269098000 / ctrl 0x269100000 on t8103. Reconcile against
  `ps_avd_sys`/avd node reg in Asahi `t8103.dtsi` on the Linux side.
- `reg` raw = `00000068 00000000 00404001 00000000` (decode pending; see DT).
- `clock-ids = [0x15d (349)]`; `clock-gates = power-gates = [0x12a, 0x12c, 0x12d]`.
- `function-avd_reset`: phandle 0x8b + `"TSRA"` + 0x66 → pmgr function
  **"ARST"** (LE 4CC) — the avd reset pmgr function.
- `function-mcc_dataset`: phandle 0x73 + `"M$DS"`-ish (mcc dataset).
- `interrupts = [0x21c, 0x21d]`, interrupt-parent 0x74, `avd-version = 3`,
  `ads-present = 1`, `h264-playback-level = 42`, `decode-samples-per-second = 28160`.
- `dart-avd@69010000` (AppleT8020DART) with mappers: `mapper-avd`,
  `mapper-avd-piodma`, `mapper-avd-adsbuf`; iommu-parent phandles 0xf2–0xf4.

## 5. Kernel log — AVD init trace (`rev/avd_kernel_log.txt`)

Boot at 19:38:31 (uptime 36 min at capture). Unique kernel lines (74):
`start(): Userspace parsing enabled`, physMemSize 0x200000000,
maxUserClientCount 32, `limitSpeed 0 ttype J293`, `M3 Retention Not Used!`,
`CAvdApCommViola(): map frameParams` (**t8103 chip family = Viola**),
`initVPInstrFifo … 0x100000 … count 0x7`, `m_coreCount: 1 - avdTier: 2`,
`getSupportBits … deviceType 26`, ADS status 0x0 → 0x7f0 (400 ms), plus a
real HEVC hardware-decode session at 19:39:09 via VTDecoderXPCService
(4K 3840×2160, codecType 2). No MMIO/clock lines are logged (all logging is
 behavioral; offsets are not printed).

## 6. Static analysis (symbols/strings/constants)

- `rev/avd_symbols.txt`: 3710 defined symbols (nm equivalent; whole KC
  symtab parsed, filtered to kext range). `rev/avd_key_functions.txt`: 830
  __TEXT_EXEC functions.
- Chip-family class matrix (CodenameC/D = single/dual die):
  `CAvdMcpu{Hibiscus,Daisy,Ixora,Viola,Tansy,Borage,LilyD,Radish,Dahlia,Clover,Kopsia,Thyme}`,
  `CAvdWrapCtrl<same>`, `CAvdApComm<same>`. t8103 instantiates **Viola** per boot log.
- **Init/power-path functions** (vmaddrs for disasm):
  - `CAvdM3Mcpu::C2()` 0x9226370, `C2(u32,CAvdRegisterIO*)` 0x92263a4
  - `CAvdM3Mcpu::disableMCPUE()` 0x92263f0, `enableMCPUE()` 0x9226458 (tiny — power switch)
  - `CAvdM3Mcpu::WaitForM3Boot()` 0x9226510 (0x260 B), `loadFirmwareImage()` 0x9226770 (0x138 B)
  - `AppleAVD::SoftReset(int)` 0x9245748, `HardReset(int,int,eAppleAVDHardResetSourceType)` 0x924593c
  - `AppleAVD::waitValidADSStatus(u32)` 0x924643c
  - `AppleAVD::setPowerStateOn(u32)` 0x924a660, `setPowerStateOff(u32)` 0x924aa80
  - **`AppleAVD::enableDeviceClockWrapper(AppleARMIODevice*,u32,u32,bool)` 0x9243d74**
  - **`AppleAVD::enableFastClockInternal(u32)` 0x924b18c / `disableFastClockInternal(u32)` 0x924b318** ← prime suspect: no equivalent in Linux apple-avd
  - `CAvdWrapCtrlViola::PwmReset()` 0x92383e8 (per-chip; find t8103's)
- Strings (`rev/avd_kext_strings.txt`, 2281 entries): `PwmReset`,
  `"No avd pwm reset, pls check device tree settings!!"`, `HardReset`,
  `SoftReset`, `waitForPowerChangeDone`, `requestPowerChange`,
  `setPowerStateGated`, `"AVD avd_reset = %p"`, `function-avd_reset`,
  `WaitForM3Boot`, `FirmwareSize`, `FirmwareVersion`, `"AVDM3 not ready"`,
  `"Saving M3 Context before forcing panic"`, ADS strings.
- Constants: **no hardcoded t8103 physical MMIO bases** in the kext (all
  ranges come from DT/IODeviceMemory at runtime) — the 36 "CM3-region" scan
  hits were bit-flag false positives. Offsets exist only as instruction
  immediates → disassembly required (Linux-side).

## 7. Checklist status (from MACOS_REVERSE.md §6)

- [x] macOS/kext versions, kext hashes (segment hashes in `rev/kc_sha256.txt`)
- [x] AppleAVD ioreg dump (power/clock/firmware properties)
- [x] kernel log excerpts (boot + a real HEVC hw-decode session)
- [~] firmware blob location/size/hash; vector-table vs Asahi fw — **blob not
      on disk**; size/version from ioreg only; vector-table scan negative
- [x] ordered MMIO write list in init path — **done, see `AVD_LINUX_DISASM.md`**
- [x] disasm snippets around NEW writes — **done, same file** (+0x50/+0x68/+0x74 MCPUE sequence vs Linux)
- [x] power sequencing order — **done, same file** (setPowerStateOn order; clock gates flagged as the only step with no Linux equivalent)

## 8. Artifacts (all under `rev/`)

`env.txt` (project root), `kc_sha256.txt`, `AppleAVD.__TEXT{,_EXEC}.bin`,
`AppleAVD.__DATA{,_CONST}.bin`, `AppleAVD.slim.map.txt`, `extracted/AppleAVD.map.txt`,
`avd_symbols.txt`, `avd_key_functions.txt`, `avd_kext_strings.txt`,
`avd_sections.txt`, `avd_kernel_log.txt`, `ioreg_avd.txt`, `ioreg_avd_node.txt`,
`ioreg_avd_decoded.txt`, `ioreg_armiodev.txt` (1.4 MB, avd+dart-avd nodes),
`kc_fileset_arm64e.txt`, `kmutil_fileset.txt`, `im4p_decode.rb`, `kc_extract.rb`,
`avd_analyze.rb` (reproducible; re-run: decode KC → extract → segment bins).

Rules kept: read-only on macOS (no SIP/kext/NVRAM changes); Apple-copyrighted
binaries stay local — the zip is for hand-carrying to the owner's Linux side,
not redistribution.
