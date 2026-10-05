# macOS AVD init reverse-engineering — field guide

Run this **on macOS** (this machine's macOS 15.7.1 install, build 24G231 —
the fixed firmware baseline; snapshot in `rev/env.txt`, kernelcache hash
in `rev/kc_sha256.txt`). Target: find what macOS does to bring up
the Apple AVD (video decoder) that the Linux `apple-avd` stack does not,
so we can replicate it in the fairydust kernel.

Everything here is **read-only**. Do NOT disable SIP, install kexts,
flash firmware, or write to MMIO. Collect data, write it to a results
file, bring it back to Linux.

Deliverables: fill in `AVD_MACOS_FINDINGS.md` per the checklist at the
bottom, plus artifact tarballs as noted. Round 2 (provider-kext
extraction) fills `AVD_CLOCKGATE_FINDINGS.md` instead — see §6.

---

## 0. Environment snapshot

```sh
sw_vers > env.txt
uname -a >> env.txt
system_profiler SPDisplaysDataType -detailLevel mini >> env.txt 2>/dev/null
sysctl -a | grep -iE 'hw\.(target|product|chip)' >> env.txt
```

Confirm: MacBookPro17,1 (j293, t8103), macOS 13.5 (22G74).

## 1. Locate the AVD driver and firmware

```sh
kmutil showloaded 2>/dev/null | grep -i avd
ioreg -l -w0 | grep -iE 'AppleAVD|avd' | head -40
find /System/Library/Extensions /System/Library/DriverExtensions -iname '*avd*' -maxdepth 3 2>/dev/null
```

Expected: `AppleAVD.kext` (and possibly `AppleAVDUserClient` /
`AppleAVEVideoEncoder`-adjacent kexts). Save:
- the kext path(s) and bundle version (`defaults read <kext>/Contents/Info.plist CFBundleShortVersionString`)
- `shasum -a 256` of `Contents/MacOS/*`

The AVF firmware blob macOS loads is usually inside the kext or in
`/usr/share/firmware`:

```sh
find /usr/share/firmware -iname '*avf*' -o -iname '*avd*' 2>/dev/null
ls -laR <AppleAVD.kext>/Contents 2>/dev/null | grep -iE 'fw|im4p|firmware'
```

Copy any firmware blob out (`cp` to your workdir, note path+size). If it
is an im4p container, unpack with asahi-fwextract's logic (clone
https://github.com/AsahiLinux/asahi-fwextract on macOS and run its avf
extraction, or eyeball the payload with `xxd`), then compare against
Asahi's open-source fw (`avd-fw-v2-t0.bin`): entry offsets, vector
table, total size. Record differences in the findings file.

## 2. Kernel log — AVD init trace

```sh
log show --last 1h --predicate 'sender == "kernel"' --style compact \
  | grep -iE 'avd|avf|AppleAVD|269080000|video.*decoder' > avd_kernel_log.txt
```

Also right after playing a video in QuickTime/Safari (hardware decode
exercise) capture again — power-on traces are gold:
```sh
log show --last 5m --predicate 'sender == "kernel"' --style compact \
  | grep -iE 'avd|avf|AppleAVD' > avd_kernel_log_active.txt
```

Look for: firmware load lines, power-state transitions, clock/reset
mentions, MMIO error strings. These strings also seed the binary search
in step 3.

## 3. Static disassembly of the init path

Install tools (admin once): `xcode-select --install` gives `otool`,
`nm`, `objdump`, `lldb`. Optionally `brew install rizin` for a nicer
disasm (not required).

Targets in `AppleAVD.kext/Contents/MacOS/AppleAVD` (arm64e):

```sh
KEXT=<path>/AppleAVD.kext/Contents/MacOS/AppleAVD
nm -arch arm64e "$KEXT" | grep -iE 'start|power|clock|reset|enable|firmware|load|init|AVD' | head -40
otool -arch arm64e -tvV "$KEXT" > avd_disasm.txt   # full text disasm
strings -a "$KEXT" | grep -iE 'avd|avf|clock|power|firmware|2690|timeout' > avd_strings.txt
```

In the disassembly, find the function(s) that run before the firmware is
handed to the hardware (the `start`/power-on path, often
`::start(IOService*)` → `enableHardware`-ish → firmware upload loop).
For every **MMIO store** (`str` to a register computed from a base),
record offset:value in order. We are hunting for any write the Linux
driver does NOT do. Known Linux sequence (diff baseline — we do all of
these already):

| region (physical)            | offset | action                         |
|------------------------------|--------|--------------------------------|
| mbox 0x269098000             | +0x48  | IRQ enable                     |
| mbox                         | +0x5c  | MBOX1 enable                   |
| mbox                         | +0x08  | RUN_CTRL = 1 (run)             |
| mbox                         | +0x90  | (fw writes FLAG0=1 when alive) |

Firmware-side register map (CM3 address space, for pattern matching in
disasm — small offsets near a 0x50010xxx or 0x40100xxx base):
- CM3_BOOT = base+0x90 (the FLAG0 ack)
- DECODE_CTRL base 0x40100000, tunables written after boot start with
  bit31 sets: MCTL_MODE +0x08, HEVC_MODE +0x1000..0x1300,
  H264_MODE +0x1400, others in `src/hw/tunables/tunables_v2t0.h` of
  AsahiLinux/avd-fw.

Specifically check whether macOS, **before** starting the coprocessor:
- writes anything in the `ctrl` window (0x269100000 + off) —
  especially a clock/mode/enable register (e.g. +0x08 MCTL_MODE bit31,
  or an unknown +0x00 control),
- toggles a reset line via a register (not the pmgr RESET bit — Linux
  already checks that),
- performs an ordered power sequence (e.g. enable clocks first, wait,
  then RUN_CTRL),
- writes a different value to RUN_CTRL (bit field beyond bit0?).

Also disassemble around the firmware-upload loop to see exactly which
region the image is copied to and any header/padding handling.

Useful anchors in the binary: the firmware filename string, error
strings from step 2, and constant pools containing the physical base
addresses (0x269080000 etc. appear as 64-bit immediates — search the
disasm for `2690800`).

## 4. IORegistry power/clock properties

```sh
ioreg -arw0 -c AppleAVD > ioreg_avd.txt
```

Inside, look for:
- `IOPowerManagement` (current power state, capability flags),
- clock related properties (`clock-ids`, `clock-gates`, `unlayered-clock-ids`),
- `firmware-*` properties (version string, load address),
- any custom property naming a reset or enable register.

Also the provider side (how the resource is published):
```sh
ioreg -arw0 | grep -B5 -A25 -i 'avd' | head -120 > ioreg_avd_context.txt
```

## 5. Firmware comparison (if blob extracted)

Compare macOS's AVF firmware with Asahi's open-source `avd-fw-v2-t0.bin`
(same 49152-byte size expected):
- vector table (first 8 words) — entry point, stack,
- presence/absence of an initial clock/enable write sequence near entry
  (disassemble both entries: `otool`-less — use `llvm-objdump -d` from
  CLT, or copy the .bin to the Linux side and `aarch64-none-elf-objdump`
  / `llvm-objdump --triple=cortex-m3` there),
- any embedded constants that look like register addresses.

## 6. Extract the provider kexts (clock-gate / function-object RE) — round 2

Follow-up round. Per `AVD_POWER_RE.md` §7, the remaining macOS-only
enabling surface for the hard-hanging AVD blocks is NOT inside
AppleAVD.kext — AppleAVD delegates it:

| Unknown | Expected owner |
|---|---|
| `io->vtable[277]` (clock gate) / `vtable[278]` (clock freq) on AppleARMIODevice — clock id 1 = boot clock, 0x15d = fast clock | `com.apple.driver.AppleARMPlatform` |
| function objects `vtable[40]` (perf floor) / `vtable[41]` (ARST; writes pmgr+0x22c) | `com.apple.driver.ApplePMGR` / `com.apple.driver.AppleT8103PMGR` / `com.apple.driver.AppleSMC` |
| virtual rails AVD-SYS-V / AVD-SOC-VNOM / AVD-SOC-VMAX handling | ApplePMGR / AppleSMC |

Extract all four from the SAME kernelcache (macOS 15.7.1). Its path is
recorded in `rev/kc_sha256.txt`; if the Preboot UUID no longer matches,
get the current boot KC path from `kmutil inspect --boot`:

```sh
KC='/System/Volumes/Preboot/8D5F46FC-080B-4F96-B47D-0F3FA3591BF3/boot/3963BA7014BAF3865E02F2D5D9BF6CB7C1BA5E151E2FCC9110953C5239087A322AB795B57C1E49544D6039281414F426/System/Library/Caches/com.apple.kernelcaches/kernelcache'
ruby rev/kc_extract.rb "$KC" list | grep -iE 'AppleARMPlatform|ApplePMGR|T8103PMGR|AppleSMC'
ruby rev/kc_extract.rb "$KC" extract 'com\.apple\.driver\.(AppleARMPlatform|ApplePMGR|AppleT8103PMGR|AppleSMC)$' rev/extracted
```

`kc_extract.rb extract` writes `rev/extracted/<short>.image` +
`<short>.map.txt`. That directory is gitignored on purpose: the `.image`
binaries are Apple-copyrighted and stay local — only the derived
knowledge (register offsets, values, sequence) enters the repo.

Analysis targets (disassemble on macOS with `otool -tvV`, or bring only
the `.map.txt` descriptors back and disassemble on Linux):

1. **AppleARMPlatform** — the AppleARMIODevice clock-gate method (vtable
   slot 277, method pointer at vtable +0x8a8): for t8103, which physical
   register block it touches for clock id 1 (gate on/off, w3 = enable)
   and clock id 0x15d (frequency set), and the exact values written.
   Record `offset:value` in call order for both the gate call and the
   freq call.
2. **ApplePMGR / AppleT8103PMGR** — the classes that answer the
   "function-set_perf_state_floor" and "function-avd_reset" function
   names; dump their vtable[40]/[41] implementations. For
   function-avd_reset confirm the ARST register (pmgr+0x22c) semantics:
   which bit, what value, any wait/poll afterwards.
3. **AppleSMC** — whether AVD enablement involves an SMC message (the
   virtual rails above); note any AVD-related routines and message IDs.

Deliverable: a new `AVD_CLOCKGATE_FINDINGS.md` in this workspace with
per-kext findings — function names, disasm snippets around every MMIO
store, and the ordered `offset:value` list for the Linux driver diff.
No binaries, no full symbol/string dumps of these kexts in the repo.

## 7. Results checklist (fill AVD_MACOS_FINDINGS.md; round 2 → AVD_CLOCKGATE_FINDINGS.md)

- [ ] macOS/kext versions, kext sha256
- [ ] AppleAVD ioreg dump (power/clock/firmware properties)
- [ ] kernel log excerpts (boot + active decode)
- [ ] firmware blob location/size/hash; vector table vs Asahi fw
- [ ] ordered list of MMIO writes in the init/power-on path, annotated
      which are already in the Linux driver (table above) and which are
      NEW (the actual answer we need)
- [ ] the init function's disasm snippet around each NEW write
- [ ] power sequencing order (clocks before run? reset ordering?)
- [ ] (round 2) 4 provider kexts extracted; `.image` bins kept local, gitignored
- [ ] (round 2) AppleARMIODevice vtable[277]/[278] implementation — clock-gate
      register + values for clock id 1 (boot clock) and 0x15d (fast clock)
- [ ] (round 2) function-object classes for perf-floor / ARST identified
      (which kext), vtable[40]/[41] dumped
- [ ] (round 2) ARST register (pmgr+0x22c) write semantics — bit, value, polling
- [ ] (round 2) SMC involvement for the virtual rails (yes/no, message IDs)

## Rules

- Read-only on macOS; no SIP changes, no kext installs, no NVRAM writes.
- Everything you extract may be Apple copyrighted — keep artifacts
  local, do not redistribute the firmware/kext dumps; only the
  *knowledge* (offset lists, sequence) goes into the repo.
- If something in this guide is impossible on 13.5 (e.g. kmutil
  restrictions), note it and move on — partial data is fine.
