# AppleAVD.kext (v865, macOS 15.7.1, arm64e) — AVD CM3 init/power-on 경로 MMIO 시퀀스 복원

> **ERRATA (2026-10-05): 일부 슬롯 추측과 A2 해석이 틀렸습니다. 런타임 wrap-ctrl은
> CAvdWrapCtrlViola(베이스 클래스 아님), A2는 0x1000000<-0xfff 쓰기가 아니라
> power-state=2 요청입니다. 정정 전체는 AVD_POWER_RE.md를 따릅니다.**


대상: MacBook Pro 13" M1 2020 (j293, t8103, Viola). `AppleAVD.__TEXT_EXEC.bin` (base 0xfffffe0009226370),
`AppleAVD.__TEXT.bin` (base 0xfffffe000715a500), `AppleAVD.__DATA_CONST.bin` (base 0xfffffe0007e160d8) 디스어셈블.
도구: `aarch64-linux-gnu-objdump -D -b binary -m aarch64`. vtable 포인터 복원 규칙: 저장값(하위 32bit) + 0x7004000 = 실제 TEXT_EXEC 주소
(Mach-O chained-fixup 인코딩, CAvdMcpu::start 등으로 검증됨).

---

## 0. 요약 (결론 먼저)

macOS의 AVD 파워업은 Linux `apple-avd`의 `avd_boot()` 4줄과 달리 3단 구조:

1. **클록/perf-state**: `setPowerStateOn` → `enableDeviceClockWrapper` → AppleARMIODevice clock gate + **function-set_perf_state_floor**(pmgr perf state) — FW 로드 *전*에 실행.
2. **래퍼(Wrap/PWM) 블록 프로그래밍**: `DevicePwrOn` (0x1000000←0xfff), CM3 부트 후 `DeviceInit` (0x1400018/0x1070000/0x1104064/0x110cac8+... 8개 쓰기), `initAvdWrap` (0x1070024←0x26907000). **Linux는 이 블록을 전혀 건드리지 않음.**
3. **CM3 부트**: `restoreM3context` → mcpu `init()`(fw 로드) → `ConfigureDMA(1)` → `start()`(disableMCPUE→enableMCPUE→WaitForM3Boot) → ADS 폴.

**Linux 누락 단계 후보 Top 3** (상세 근거는 §6):

1. **래퍼/PMM 블록 초기화** (`DevicePwrOn`/`DeviceInit`/`initAvdWrap`의 총 10개 MMIO 쓰기, offset 0x1000000–0x110cxxx) — Linux에 동급 개념 없음. CM3 시작에 필요한 클럭/전원 게이트가 이 블록에 있을 가능성이 가장 높음.
2. **부팅 전 클럭 인에이블 / pmgr perf-state floor** (`enableDeviceClockWrapper`의 set_perf_state_floor + clock gate) — Linux 드라이버는 클럭/파워 게이트 코드가 전무(CLK 0x15d, gates 0x12a/0x12c/0x12d 미사용).
3. **`enableMCPUE`의 mbox 추가 쓰기** (+0x50, +0x68, +0x74 ← 1, +0x4c ← 0) — Linux는 +0x5c/+0x48/+0x08만 씀.

---

## 1. Init/power-on 경로 Ordered MMIO Write List

오프셋 표기: "윈도우 오프셋" = kext가 만드는 통합 VA 매핑 내 바이트 오프셋 (§5 베이스 매핑 참조).
region 추정 근거는 §5. 쓰기 순서는 실제 호출 순서.

### Phase A — 파워업 시작 (`AppleAVD::setPowerStateOn(u32 core)`, 0x924a660)

| # | 함수 | region (추정) | 오프셋 | 값 | 비고 |
|---|------|--------------|--------|----|------|
| A1 | enableDeviceClockWrapper | pmgr/clk (비 MMIO 직접 아님) | — | — | AppleARMIODevice clock gate + function-set_perf_state_floor (§3.3) |
| A2 | DevicePwrOn (wrapctrl vtable[5]) | **wrap/pwm** | **0x1000000** | **0xfff** | "pwm" 파워온. `str w2,[x9+off]`, x9=[wrap+16] |

### Phase B — CM3 부트 (`CAvdApComm::restoreM3context(bool)`, 0x923cc1c)

mcpu = CAvdMcpuViola→**CAvdM3Mcpu** (regIO 베이스 0x1080000, mbox = +0x28000 → 절대 0x10a80xx).

| # | 함수 | region | 오프셋 | 값 | 비고 |
|---|------|--------|--------|----|------|
| B1 | CAvdMcpu::init→**disableMCPUE** (vtable[8]) | mbox | +0x08 (0x10a8008) | 0xe | RUN_CTRL stop (Linux AVD_RUN_CTRL_UNK_STOP=0xe와 일치) |
| B2 | disableMCPUE | mbox | +0x98 (0x10a8098) | 1 | FLAG0 clear |
| B3 | disableMCPUE | mbox | +0x10 (0x10a8010) | 0 | |
| B4 | disableMCPUE | mbox | +0x48 (0x10a8048) | 0 | IRQ enable 클리어 |
| B5 | loadFirmwareImage | **CM3 SRAM** | 0x1080000 | fw 0xef78 B | kext 내장 fw (`__TEXT` 0x7175e30)를 WriteBufferToRegister로 카피 |
| B6 | loadFirmwareImage | CM3 SRAM | 0x1080000+0xef78 … 0x1092000 | 0 | 나머지 0x12000 바이트 윈도우 0으로 채움 |
| B7 | ConfigureDMA(1) (vtable[31], 조걸) | — | — | — | [PQ+3300]==1 일 때만 |
| B8 | CAvdMcpu::start→**disableMCPUE** | mbox | B1–B4와 동일 | | 재실행 |
| B9 | start→**enableMCPUE** (vtable[9]) | mbox | **+0x50** | 1 | **Linux 없음** |
| B10 | enableMCPUE | mbox | **+0x68** | 1 | **Linux 없음** |
| B11 | enableMCPUE | mbox | +0x5c (0x10a805c) | 1 | MBOX1 enable — **Linux 유일 일치** |
| B12 | enableMCPUE | mbox | **+0x74** | 1 | **Linux 없음** |
| B13 | enableMCPUE | mbox | +0x4c (0x10a804c) | 0 | IRQ clear (vtable[15] 스텁, 실질 쓰기) |
| B14 | enableMCPUE | mbox | +0x08 (0x10a8008) | 1 | RUN_CTRL run |
| B15 | initAvdWrap (ApCommViola vtable[25]) | **wrap** | **0x1070024** | **0x26907000** | 물리주소를 래퍼 레지스터에 기록 (DART/SID 설정 추정) |

### Phase C — CM3 부트 직후 (`setPowerStateOn` 계속, wrapctrl vtable[4])

`CAvdWrapCtrlViola::DeviceInit` (0x92384d8), 순서대로 (전부 `str w2,[x9+off]`, x9=[wrap+16]):

| # | 오프셋 | 값 | 비고 |
|---|--------|----|------|
| C1 | **0x1400018** | 1 | 0x1400000 블록 |
| C2 | **0x1070000** | 0 | |
| C3 | **0x1104064** | 3 | ≈ Linux ctrl + 0x4064 (VP FIFO 바로 아래) |
| C4 | **0x110cc90** | 0xffffffff | |
| C5 | **0x110cc94** | 0xffffffff | |
| C6 | **0x110ccd0** | 0xffffffff | |
| C7 | **0x110ccd4** | 0xffffffff | |
| C8 | **0x110cac8** | 0xffffffff | |

### Phase D — ADS 유효 폴 (`CAvdApCommViola::waitValidADSStatus`, vtable[8] of ApComm)

읽기만 수행: offset **0x1002010** ReadRegister32, `(val & 0x7f0) == 0x7f0` 폴, 10ms 간격, 최대 500회(5s).
부트 로그와 일치: status 0x0 → 약 400ms 후 0x7f0.

### (참고) 리셋 경로 — `CAvdWrapCtrlViola::PwmReset` (0x92383e8, HardReset에서 호출)

1. `waitForOutstandingAXITransaction`: offset **0x738** 및 **0x798** 폴, `(val & 0xfe00fe00) == 0` 대기 (AXI outstanding transaction 드레인).
2. vtable[41] 호출 on [wrap+32] (w1=1): [wrap+32] = 프로바이더의 **"function-avd_reset"** 프로퍼티 객체 — **pmgr ARST 리셋 트리거** (DT function-avd_reset, 4CC "ARST").
3. `AVDDart::setActive([wrap+96], 1)`.

`Idle(bool x1)` = offset **0x1400014** ← x1 (idle 진입/해제).

---

## 2. 파워 시퀀스 호출 순서 (복원된 call graph)

```
AppleAVD::start (probe; chip id 0x1a → Viola 팩토리)
  ├─ AVDDart::setActive(1), AVDDart::initialize/registerWithIOSurface
  ├─ enableDeviceClockWrapper(io, 1, 0, 1)          ← 클록 게이트 + perf floor
  ├─ initForPM
  └─ (PM 등록, 최초 파워업은 initializeDevice → requestPowerChange)

파워업 (per core):
AppleAVD::initializeDeviceInternal gated fn (arg=1)
  └─ AppleAVD::setPowerStateOn(core)                0x924a660
       1. enableDeviceClockWrapper([this+0xf8+core*8], 1, 0, 1)     ← A1
       2. ioDevice vtable[278](1,0,0)
       3. [this+0xe8+core*8] vtable[5](0)  = WrapCtrl::DevicePwrOn    ← A2 (0x1000000←0xfff)
       4. AVDDart::setActive(1) / unmapDeferralList  ([this+0xd8])
       5. PriorityQueue::setAVDCtrlIdle(1) + 대기 큐 재생
       6. [[this+0xc8+core*8]+8]::restoreM3context(0)  (CAvdApComm)  ← Phase B 전체
            ├─ mcpu->init(0)      = disableMCPUE + loadFirmwareImage (fw→SRAM)
            ├─ ApComm->ConfigureDMA(1) (조걸)
            ├─ mcpu->start()      = disableMCPUE → enableMCPUE → WaitForM3Boot
            ├─ mcpuRestoreContext (arg==0 일 때)
            └─ ApCommViola::initAvdWrap()            ← B15 (0x1070024←0x26907000)
       7. [this+0xe8+core*8] vtable[4](0)  = WrapCtrl::DeviceInit     ← Phase C 8개 쓰기
       8. [[this+0xc8+core*8]+8] vtable[8] = waitValidADSStatus (조걸) ← Phase D

리셋:
AppleAVD::HardReset → per core: [this+0xe8+core*8] vtable[10](0) → vtable[8] = PwmReset (ARST)
```

**핵심 순서 관계**: 클럭(A1) → 래퍼 파워온(A2) → **펌웨어 로드(B5,B6)** → M3 구동(B9–B14) → ADS 폴(D).
즉 macOS는 RUN_CTRL=1을 쓰기 *전에* 클럭+래퍼+SRAM 로드를 전부 마친다.

---

## 3. Linux에 없는 쓰기 — 디스어셈블리 스니펫

### 3.1 `CAvdM3Mcpu::enableMCPUE` 전체 (0x9226458)

```asm
0x9226458:  pacibsp
0x922646c:  ldr  w1, [x0, #340]        ; 필드 340 = +0x50 (생성자 테이블 base 0x1080000+0x28050)
0x9226470:  mov  w2, #1
0x9226474:  bl   0x9259dcc             ; CAvdMcpu::WriteRegister32 → mbox+0x50 = 1   [Linux 없음]
0x9226478:  ldr  w1, [x19, #364]       ; +0x68
0x9226484:  bl   ...WriteRegister32    ; mbox+0x68 = 1                                [Linux 없음]
0x9226488:  ldr  w1, [x19, #352]       ; +0x5c  (MBOX1 enable)
0x9226494:  bl   ...WriteRegister32    ; mbox+0x5c = 1                                [Linux 동일]
0x9226498:  ldr  w1, [x19, #376]       ; +0x74
0x92264a4:  bl   ...WriteRegister32    ; mbox+0x74 = 1                                [Linux 없음]
0x92264a8:  ldr  x16, [x19]            ; vtable
0x92264cc:  add  x8, x16, #0x78        ; vtable[15]
0x92264d4:  mov  w1, #0
0x92264e4:  blraa x9, x17              ; M3Mcpu vtable[15] = no-op stub (bti c; ret) — TX/RX IRQ 제어 미사용
0x92264e8:  ldr  w1, [x19, #320]       ; +0x08  (RUN_CTRL)
0x92264f0:  mov  w2, #1
0x922650c:  b    0x9259dcc             ; tail: mbox+0x08 = 1 (RUN)                    [Linux 동일]
```

생성자(0x92268a8)의 오프셋 테이블 (`__TEXT` 0x7175dc0–0x7175e1f, 기본 베이스 0x1080000):

```
필드320..412 = 0x1080000 + {0x28008,0x28010,0x28048,0x2802c, 0x2804c,0x28050,0x28054,0x28058,
                            0x2805c,0x28060,0x28064,0x28068, 0x2806c,0x28070,0x28074,0x28078,
                            0x2807c,0x28080,0x28084,0x28088, 0x2808c,0x28090,0x28098,0x28094}
필드 416 = 0x1080000 + 0x2809c ; 필드 12 = fw 목적지 0x1080000 ; 필드 16 = 0x12000 (윈도우 크기)
필드 32 = 내장 fw 이미지 ptr (__TEXT 0x7175e30) ; 필드 40 = fw 크기 0xef78
```

`disableMCPUE` (0x92263f0): 필드320(+0x08)←0xe, 필드408(+0x98)←1, 필드324(+0x10)←0, 필드328(+0x48)←0.

### 3.2 `AppleAVD::enableFastClockInternal` 전체 (0x924b18c) — prime suspect

```asm
; [this+0x20c+idx*4](현재 fast-clk state) != [this+0x204+idx*4](요청 state) 일 때만 진행
0x924b1d4:  ldr  x1, [x25, x20, lsl #3]   ; x25 = this+0xf8  (AppleARMIODevice*)
0x924b1e8:  bl   0x9243d74                 ; enableDeviceClockWrapper(io, 1, 0, 1)
0x924b204:  ldrb w8, [x8, x20]             ; [this+0x22d+idx] (boost flag A)
0x924b210:  ldrb w8, [x8, x20]             ; [this+0x22f+idx] (boost flag B) == 1?
0x924b220:  ldrb w8, [x21, #561]           ; [this+561] perf-floor 허용 플래그
0x924b254:  bl   0x9243d74                 ; enableDeviceClockWrapper(io, clkID=[this+0x204+idx*4], 1, 1)
0x924b294:  ldr  x8, [x16, #2216]          ; ioDevice vtable[277]
0x924b2b4:  blraa x8                       ; AppleARMIODevice: 클럭 주파수/게이트 세트 (0, clkVal)
0x924b2d4:  str  w2, [x22, x20, lsl #2]    ; [this+0x20c+idx*4] = 요청 state 갱신
```

호출처: `initializeDeviceInternal` 내 `AppleAVDCoreControl::requestAVDCoreSpeed` 경로 (0x924850c–0x9248594) —
디코드 부하에 따라 fast clock 토글. 즉 **부팅 직후가 아니라 세션 중**이지만, 상시 클럭(A1)과 같은
pmgr/clk 계열이며 Linux에 동급 개념이 없다.

### 3.3 `AppleAVD::enableDeviceClockWrapper` (0x9243d74) — "clock"의 실체

- 로그 문자열: `"AppleAVD: %s() :: Calling function-set_perf_state_floor failed !"` (0x71655c0),
  `"function-set_perf_state_floor"` cstring (0x71733ee).
- [this+0x17590] 객체 vtable[40]에 {u32, u32, bool} 구조체 포인터 전달 → pmgr 함수 호출 래퍼.
- `AppleAVD::callPlatformFunction`(0x924b414) 오버라이드: 함수명이 두 캐시된 OSSymbol과 일치하면
  [this+561]을 1/0으로 세팅(= fast clock 허용/해제) 후 super로 위임. 클럭 인에이블의 실질 동작은
  **AppleARMIODevice(=pmgr)의 set_perf_state_floor + clock gate**임을 로그가 직접 증명.
- 0x9243f40 의 함수: chip id → 42/129/36/32 값 매핑 (클록 주파수/perf-state 추정).

### 3.4 `CAvdWrapCtrlViola::WriteRegister32` (0x9237df4) — 직접 MMIO

```asm
0x9237df8:  mov  w8, w1
0x9237dfc:  ldr  x9, [x0, #16]        ; 베이스 VA (생성자에서 regs 포인터로 저장)
0x9237e00:  ldrb w10, [x0, #24]       ; endian 플래그 (Viola=1)
0x9237e04:  cmp  w10, #2
0x9237e0c:  rev  w10, w2              ; (endian==2 일 때 byte-swap)
0x9237e10:  add  x8, x9, x8
0x9237e14:  str  w10, [x8]            ; *(u32*)(base + off) = val
```

DeviceInit/DevicePwrOn/Idle의 "offset"은 전부 이 베이스 기준.

---

## 4. ADS wait 의미론

- 함수: `CAvdApCommViola::waitValidADSStatus` (0x9259410), `waitValidADSStatusWithMask(j)` (0x9259a28) 동일 구조.
- 레지스터: **offset 0x1002010** (ApComm의 CAvdRegisterIO 기준; wrap 베이스 윈도우 내 0x1002000 블록).
- 의미: `(status & 0x7f0) == 0x7f0` 이 될 때까지 폴. 10ms 간격, 최대 0x1f4(500)회 ≈ 5s.
- 로그(한국 시험 기록과 동일): 첫 폴 시 "AVD ADS module valid bits not set yet! Waiting until valid. status=0x0",
  성공 시 "AVD ADS status valid bits set! status=0x7f0" — 실측 약 400ms.
- 의미 해석: 0x7f0 = 상위 7비트(0x80..0x400) + 0x70 — ADS 모듈(복호화 엔진)의 valid/ready 비트 마스크.
  이 폴은 CM3 부트(B14)와 wrap DeviceInit(C1–C8) **이후**에 이루어짐 → ADS는 래퍼+CM3 초기화가
  끝난 뒤에야 ready가 된다. Linux는 ADS 개념 자체가 없음(복호화를 FW가 아닌 드라이버가 처리).

## 5. 레지스터 베이스 매핑 테이블

kext는 AVD 전체 공간을 **하나의 큰 VA 윈도우**로 맵하고, 각 객체는 그 안의 바이트 오프셋을 쓴다.
(근거: wrap ctrl [this+16]에 저장된 베이스에 0x1000000~0x110cxxx 오프셋 직접 str; mcpu regIO에
0x1080000+0x280xx; 둘이 Linux mbox/ctrl 물리 주소와 구조적으로 일치 — 아래 대응.)

| 윈도우 오프셋 | 내용 | 물리 대응 추정 (base+0x268000000 가정) | 근거 |
|---|---|---|---|
| 0x1000000 | wrap/pwm 파워 블록 (PwrOn 0xfff, AXI 상태 0x738/0x798, ADS 0x1002010) | ≈0x269000000 대 | ioreg 유일 MMIO 0x269010000+0x4000와 같은 하위 공간; Linux 미매핑 |
| 0x1070000–0x1070fff | wrap 제어 (Init 0x1070000, 0x1070024←0x26907000) | ≈0x269070000 | 물리주소 0x26907000이 이 레지스터에 기록됨(자기 공간 참조) |
| 0x1080000–0x1091fff | CM3 펌웨어 SRAM 윈도우 (크기 0x12000) | Linux "code" 리소스 | fw 카피 대상; 사용자 측 바이트동일 로드 확인과 일치 |
| 0x10a8000–0x10a80a0 | **mbox** (RUN_CTRL +0x08, IRQ +0x48, MBOX1 +0x5c, RETRIEVE +0x64, FLAG0 +0x90/+0x98) | Linux mbox 0x269098000 | 필드 오프셋이 Linux avd-regs.h(+0x08/+0x48/+0x5c/+0x64/+0x90/+0x98)와 **완전 일치** |
| 0x1104000, 0x110c000–0x110ccd8 | DeviceInit 대상 (0x1104064←3, 0x110cac8+...←0xffffffff) | Linux ctrl 0x269100000 영역 | Linux t8103 vp_slot 0x4004/insn fifo 0x4068과 같은 0x40xx 군 |
| 0x1400014/0x1400018 | idle/pwm 보조 | ≈0x269140018? (미확정) | Idle/DeviceInit이 사용 |

베이스 VA의 출처: `AppleAVD::start` (0x923ffec)에서 `[this+384]` 객체(AppleARMIODevice 계열)의
vtable[226] → [this+296] 객체의 vtable[39]로 베이스 포인터 획득(0x9240118, [sp+120]) 후
`CAvdWrapCtrlViola::C2(u32* regs, ...)`/`CAvdApCommViola::C2(void*, CAvdRegisterIO*)`에 전달.
정확한 물리 베이스는 런타임 DT/IODeviceMemory에서 획득(하드코딩 물리주소 없음 — 과제 전제 확인).

객체 배열 (AppleAVD this 기준):
- +0xc8: CPriorityQueue* 배열 (→ [+8] = CAvdApComm*)
- +0xd8: AVDDart* 배열
- +0xe8: **CAvdWrapCtrl* 배열** (vtable[4]=DeviceInit, [5]=DevicePwrOn, [8]=PwmReset — §2 순서)
- +0xf8: AppleARMIODevice* 배열
- +0x160: wrap ctrl 배열(팩토리), +0xb0(176): 칩별 wrap ctrl
- +0x17590: perf-state/클록 관리 객체, +0x16000 대역: AppleAVDDiagnostic

## 6. Linux baseline과의 diff — 누락 단계 후보 Top 3

Linux `avd_boot()` (drivers/media/platform/apple/avd/avd-hw.c): `memcpy_toio(code, fw)` →
`mbox+0x5c=1` → `mbox+0x48=8` → `mbox+0x08=1` → `mbox+0x90` 폴. 리셋은 `reset_control_reset()` (pmgr ARST).

### 후보 1: 래퍼/PMM 블록 초기화 (가장 유력 — j293 특이 가능성)
- 근거: macOS는 CM3 부트 전(A2: 0x1000000←0xfff)과 직후(C1–C8: 8개, B15: 0x1070024←물리주소)로
  총 10개의 래퍼 레지스터를 프로그램. Linux는 이 공간(0x1000000–0x110cxxx)에 한 번도 쓰지 않음.
- 0x1000000←0xfff는 "전 파워도메인 온" 스타일 값. j293(j274와 달리)은 래퍼가 CM3 클럭/파워를
  게이팅한다면, 이 쓰기 없이는 RUN_CTRL을 써도 CM3이 동작하지 않고 FLAG0는 영원히 0 — **현상과 정확히 일치**.
- C3(0x1104064←3) 및 C4–C8(0x110cxxx←0xffffffff)은 Linux ctrl 영역 0x40xx/0xcxxx로,
  VP/DMA 파이프라인 설정일 가능성.

### 후보 2: 부팅 전 클럭 인에이블 + pmgr perf-state floor
- 근거: A1은 FW 로드 *전*에 실행. 낶부는 `function-set_perf_state_floor`(pmgr) + clock gate.
  ioreg DT 사실: clock-ids [0x15d], clock-gates/power-gates [0x12a,0x12c,0x12d] — kext가 실제로
  사용( enableDeviceClockWrapper → AppleARMIODevice ). Linux 드라이버에는 clk/pwr 코드가 전무하고
  (`avd_probe`에 clk_prepare_enable 없음), t8103 게이트(0x12a/0x12c/0x12d)가 U-Boot/m1n1에서
  켜져 있을 보장이 j293에서는 없을 수 있음.

### 후보 3: enableMCPUE의 mbox 추가 쓰기 (+0x50, +0x68, +0x74 ← 1, +0x4c ← 0)
- 근거: 동일 함수 내, RUN_CTRL 직전에 실행. +0x5c(유일 Linux 공통)와 나란히 있어 동일한 필수
  init 시퀀스일 가능성이 높음. 의미는 불명(mbox 블록 내 보조 게이트/마스크 추정)이나,
  "SRAM/리셋은 확인됐는데 FLAG0가 안 올라온다"는 현상을 설명하는 후보 중 Linux가 유일하게
  건드리지 않는 mbox 레지스터들.

기타 diff (우선순위 낮음): fw 0 패딩 0x12000(B6, 이미 바이트동일 확인으로 제외 가능), ADS 폴(복호화 전용),
IRQ clear(+0x4c), DisableM3InboxEmptyInterrupt 경로.

---

## 7. 막힌 부분 / 한계 (시도한 방법)

1. **DeviceInit/DevicePwrOn의 직접 call site를 텍스트 매칭으로 완전 확정하지 못함**.
   가상 호출(vtable+0x20/+0x28/+0x40) 패턴 전수검사(`mov x17,#imm; add x16,x16,x17`,
   `add x16,x16,#imm`, `ldr x8,[x16,#imm]!` 3종)를 했으나 CAvdWrapCtrlViola 생성자 외 명확한
   호출 지점이 검출되지 않아, [this+0xe8] 배열 객체의 vtable[4]/[5] 호출이 DeviceInit/DevicePwrOn임을
   **슬롯 번호 일치**(DATA_CONST vtable 디코딩, delta 0x7004000 규칙)로 추정. §2 순서는 이 추정에 기반.
2. **정확한 물리 베이스**: ioreg상 유일 MMIO range(0x269010000+0x4000)와 kext 윈도우 오프셋
   (0x1000000+)를 완전히 대응시키지 못함. Linux mbox(0x269098000)/ctrl(0x269100000)와
   kext 오프셋(0x10a8000/0x1100000)의 *상대 간격*이 어긋나 0x1000 시프트 가능성이 남음.
   §5의 물리 추정은 "base+0x268000000" 가정 명시.
3. 커널 외부 함수(0x8e8996c=os_log 계열, 0x8c90748=thread 신호, 0x8f08bc4=IOService 파워 등)는
   kernelcache 심볼 없이 행위로만 식별.
4. `writeHxRegister`의 가상 호출 6개(vtable+0x218/0x228/0x138/0x28/0x220/0x40)는
   IODeviceMemory→VA 변환/배리어 래퍼로 보이나 클래스( RegisterIO, __ZTV10RegisterIO 확인)의
   정확한 메서드 이름은 미확정 — MMIO 시맨틱(단일 `str w`)에는 영향 없음.

## 8. 재현 명령

```sh
cd rev/
aarch64-linux-gnu-objdump -D -b binary -m aarch64 --adjust-vma=0xfffffe0009226370 \
  AppleAVD.__TEXT_EXEC.bin > /tmp/text_exec.asm
# 함수 슬라이스: 0x9226458–0x9226510 (enableMCPUE), 0x92384d8–0x9238720 (DeviceInit),
# 0x924a660–0x924aa80 (setPowerStateOn), 0x924b18c–0x924b318 (enableFastClockInternal),
# 0x9259410–0x9259550 (waitValidADSStatus), 0x923cc1c–0x923cdb8 (restoreM3context)
```
