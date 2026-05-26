# ICT 2026

Expert Advisor ICT 2026 — module hóa theo hướng ICT/SMC. **Không phụ thuộc HyperICT** (chỉ tham khảo ý tưởng swing & key level).

Phiên bản hiện tại: **1.10**

---

## Quy ước bảo trì (bắt buộc)

> **Từ giờ, mọi logic mới hoặc thay đổi hành vi phải được cập nhật vào file README này trong cùng lần sửa code.**
>
> Khi thêm module, sửa rule BOS/CHoCH, đổi veto, input mới, API mới → cập nhật các mục tương ứng bên dưới **và** mục [Changelog](#changelog).

---

## Mục lục

1. [Cấu trúc thư mục](#folder-structure)
2. [Pipeline Daily Bias](#pipeline)
3. [Logic nghiệp vụ](#business-logic)
4. [Mô tả từng file](#file-reference)
5. [API](#api)
6. [Input](#inputs)
7. [Chưa implement](#roadmap)
8. [Changelog](#changelog)

---

<a id="folder-structure"></a>

## Cấu trúc thư mục

```
MQL5/
├── Experts/
│   └── ICT_2026.mq5              ← EA chính (OnInit / OnTick)
│
└── Include/
    └── ICT2026/
        ├── README.md               ← tài liệu này (luôn cập nhật khi đổi logic)
        ├── Types.mqh               ← enum, struct
        ├── Config.mqh              ← input
        ├── Swing.mqh               ← pivot, swing set H0–L1, key level
        ├── StructureCore.mqh       ← body break, BOS/CHoCH detect (Key H0/L0)
        ├── StructureTrend.mqh      ← trend rõ vs sớm (dùng chung H1 + D1)
        ├── DailyBias.mqh           ← Daily Bias + UpdateHTFBias
        ├── IntradayStructure.mqh   ← Intraday trend H1 + IsAllowTrade
        ├── LowTfTrend.mqh        ← iTF FVG khi IsAllowTrade
        ├── Fvg.mqh               ← detect / Available-Used
        ├── FvgDraw.mqh           ← vẽ FVG + Premium/Discount
        ├── EaState.mqh             ← state machine STOP / SETUP / TRADE
        ├── Panel.mqh               ← bias + intraday + EA state (góc trên)
        └── Draw.mqh                ← label b*/i*/H0–L1 trên chart
```

**Include trong code:** `#include <ICT2026/TênFile.mqh>`

---

<a id="pipeline"></a>

## Pipeline Daily Bias

Chạy trên **mỗi nến mới** của `InpBiasTf` (mặc định D1), hoặc `force=true` lúc Init:

```
IctDailyBias_Update(sym)
  │
  ├─1─ Tính PDH, PDL, PDC, EQ (nến shift=1)
  │
  ├─2─ IctUpdateHTFBias()          ← Previous Day Model (fallback)
  │
  ├─3─ IctResolveTrend()            ← rõ (HH-HL/LH-LL) hoặc sớm (sau CHoCH)
  │     └─ IctDetectStructureEvent() trên Key H0/L0 (body close D[1])
  │
  └─4─ Fallback HTF (bias = None)  ← Previous Day Model
        └─ IctBuildDisplayReason() ← chuỗi lý do D[n] cho panel
        └─ IctPanel_Render()       ← khi có nến D1 mới (EA gọi)
```

**Notation nến:** `D[0]` = nến đang chạy (chưa đóng), `D[1]` = nến vừa đóng, `D[2]` = nến trước đó.
Bias tính từ **D[1]** và swing trên các nến đã đóng.

---

<a id="pipeline-intraday"></a>

## Pipeline Intraday Structure

Chạy trên **mỗi nến mới** của `InpIntradayTf` (mặc định **H1**):

```
IctIntraday_Update(sym)
  │
  ├─1─ IctBuildSwingSet()           ← H0–L1 trên H1
  ├─2─ IctGetKeyLevels()
  ├─3─ IctDetectStructureEvent()    ← BOS / CHoCH trên bar [1]
  ├─4─ IctApplyIntradayTrend()      ← Up / Down
  ├─5─ IctBuildIntradayDisplayReason()
  └─6─ IctIntraday_UpdateAllowTrade()
```

**Notation H1:** `H[0]` đang chạy, `H[1]` vừa đóng.

### Intraday trend (HH-HL / LH-LL + BOS / CHoCH)

**Phân loại intraday (khác Daily):** dùng **2 đỉnh + 2 đáy gần nhất** trong `InpIntradayRecentBars` (mặc định 80 bar H1), không ghép leg 4 swing dài — tránh nhầm HH-HL từ sóng cũ khi giá đã LH-LL.

| So sánh | Điều kiện |
|---------|-----------|
| **HH-HL** | Đỉnh mới > đỉnh cũ **và** đáy mới > đáy cũ |
| **LH-LL** | Đỉnh mới < đỉnh cũ **và** đáy mới < đáy cũ |

Key level cho BOS/CHoCH: Bear Key1=H0, Key2=L0; Bull Key1=L0, Key2=H0.

### Hai trạng thái trend (H1 + Daily)

| Phase | Hiển thị | Điều kiện |
|-------|-----------|-----------|
| **Rõ ràng** | `Up` / `Down` | Pivot HH-HL hoặc LH-LL |
| **Sớm** | `Bull sớm` / `Bear sớm` | Sau CHoCH, MS mới chưa rõ (pivot lộn xộn) |

**CHoCH (đảo, body close):**

| Cấu trúc trước | Điều kiện | Trend sau |
|----------------|-----------|-----------|
| LH-LL (Bear) | Body phá **H0** | **Bull sớm** |
| HH-HL (Bull) | Body phá **L0** | **Bear sớm** |

**Giữ trend sớm** khi pivot lộn xộn cho đến khi HH-HL/LH-LL rõ hoặc CHoCH ngược.

**CHoCH ưu tiên trước pivot rõ:** pivot vẫn LH-LL nhưng H[1] phá H0 → **Bull sớm** (không giữ Down).

| Pivot | Trend |
|-------|-------|
| **HH-HL** | **Up** (rõ) |
| **LH-LL** | **Down** (rõ) |
| Mixed + đang sớm | Giữ Bull/Bear sớm |
| Mixed, không sớm | **None** |

---

<a id="pipeline-lowtf"></a>

## Pipeline Low TF — iTF FVG (v1.10)

Chạy trên **mỗi nến mới** của `InpFvgTf` (mặc định H1 = Intraday):

```
IctLowTfTrend_Update(sym)
  │
  ├─1─ IsAllowTrade == true?
  │     └─ IctFvg_ScanNew() — Bull FVG nếu Bias Up, Bear nếu Bias Down
  ├─2─ IctFvg_UpdateAll() — cập nhật fill % → Available / Used
  ├─3─ IctFvg_PurgeExpired() — xóa Available quá InpFvgExpireDays (3 ngày)
  └─4─ IctFvgDraw_Render() — hình chữ nhật + Premium/Discount
```

### FVG 3 nến (A–B–C)

| Loại | Điều kiện | Vùng |
|------|-----------|------|
| **Bull** | A.High < C.Low (gap 3 nến) | [A.High .. C.Low] |
| **Bear** | A.Low > C.High (gap 3 nến) | [C.High .. A.Low] |

**Lọc gap quá nhỏ** (phải thỏa tất cả bật):

| Input | Mặc định | Ý nghĩa |
|-------|----------|---------|
| `InpFvgMinGapATRPct` | 12% | Chiều cao gap ≥ % ATR14 trên `InpFvgTf` |
| `InpFvgMinGapPoints` | 0 | Thêm ngưỡng tuyệt đối (giá), 0 = chỉ ATR |
| `InpFvgMinGapVsBarPct` | 25% | Gap ≥ % range nến giữa (B) |

Quét: init / khi `IsAllowTrade` vừa bật → full lookback; mỗi nến mới → `InpFvgScanBarsPerUpdate` bar.

### Available / Used

| State | Điều kiện |
|-------|-----------|
| **Available** | Giá chưa chạm FVG, hoặc lấp < `InpFvgUsedFillPct` (38.2%) |
| **Used** | Lấp ≥ 38.2% hoặc xuyên qua FVG |

Chỉ **quét / giữ** FVG thuận Daily Bias. **Vẽ FVG** (ngang):

| | |
|--|--|
| **Bắt đầu** | `createdTime` (lúc hình thành gap) |
| **Kết thúc** | Used (`fvgUsedTime`) **hoặc** hết hạn `InpFvgExpireDays` (3 ngày) — không kéo tới hiện tại vô hạn |

### Premium / Discount

**Một vùng P/D cho mỗi FVG** (không gộp nhóm — tránh chồng lấn).

| Bear FVG | Bull FVG |
|----------|----------|
| Swing 1: pivot **gần FVG nhất** (bar shift trước nến C), giá > `upper` → `pdHigh` | Swing 1: pivot gần FVG, giá < `lower` → `pdLow` |
| Swing 2: **đáy đầu tiên** sau FVG khi pivot xác nhận (`pdLow`) | Swing 2: **đỉnh đầu tiên** sau FVG (`pdHigh`) |

**Vẽ P/D (ngang):**

| | |
|--|--|
| **Bắt đầu** | `createdTime` FVG — **không** kéo sang trái |
| **Kết thúc** | Thời điểm swing 2 hoàn thiện; trước đó kéo tới nến hiện tại (đáy/đỉnh chạy) |
| **Sau swing 2** | `pdComplete` — **khóa** `pdHigh`/`pdLow`/`pdRangeEnd`; không đọc lại `iH0`/`iH1` live |

Swing 1 (`pdSwing1Set`) gán **một lần** khi FVG mới; swing 2 xác nhận → `pdComplete` → không cập nhật nữa khi intraday swing đổi.

FVG Used **không** kéo dài P/D thêm; P/D độc lập với Used (theo swing 2).

**`repPd`**: overlap Premium/Discount (không chỉ midpoint FVG). Bear thỏa MSS nếu **một phần FVG** nằm trên `pdEq` (Premium); fill 38.2% luôn tính từ **`lower`→`upper`** của FVG.

### Retest FVG H1 (POI) — không nhầm với retest swing H1

**Retest FVG H1** = giá **hồi vào gap Fair Value Gap trên H1** (vùng POI), đo trên **`InpFvgTf` (H1)**:

| | |
|--|--|
| **Retest** | **Giá chạm** FVG (H1/M5/bid-ask) — không cần râu H1 riêng |
| **Giữ giá H1** | Râu xuyên FVG → tiếp tục chờ MSS M5 |
| **AllowTrade** | H1 trend đồng thuận Bias — **không** đánh dấu FVG Used |
| **FVG Used (fail)** | H1 body đóng xuyên FVG — không giữ giá |
| **FVG Used (OK)** | Giữ giá + **MSS M5** khóa → Used, tiếp tục M5 FVG / entry trên cùng setup |
| **AllowTrade=false** | Tạm dừng MSS pipeline; vẫn **watch** FVG cho H1 body fail |
| **MSS M5** | Sau chạm FVG → M5 pullback → **phá L0** (bear) / **phá H0** (bull) |

**Định nghĩa MSS vs CHoCH (cùng rule Key H0/L0):**

| HTF bias | M5 cục bộ trước MSS | MSS = | SL swing |
|----------|---------------------|-------|----------|
| Bear (H1↓) | Pullback tăng (bull M5) | Body phá **L0** (đáy tạo H0) | **H0** |
| Bull (H1↑) | Pullback giảm (bear M5) | Body phá **H0** (đỉnh tạo L0) | **L0** |

CHoCH trên D/H1 = phá key level **ngược** xu hướng HTF (bull→bear phá L0; bear→bull phá H0). MSS trên M5 = cùng rule nhưng trên **pullback cục bộ** sau retest FVG H1.
| **Không phải** | Retest swing H1; bắt buộc body H1 lấp sâu vào gap (khi wick-only bật) |

**FVG size filter:** `InpFvgMinGap*` chỉ áp dụng **`InpFvgTf` (H1)**. **M5** (`InpConfirmTf`) — không lọc ATR → phát hiện FVG M5 nhỏ.

Sau retest FVG H1 OK → arm MSS trên M5.

### EA state machine (`EaState.mqh`, v1.131)

Panel luôn hiển thị 3 dòng đầu: **`[CATEGORY] CODE`**, tiêu đề, chi tiết.

| Category | State `CODE` | Khi nào |
|----------|--------------|---------|
| **STOP** | `STOP_NO_BIAS` | Daily bias = None |
| **STOP** | `STOP_BIAS_RANGE` | Bias = Range |
| **STOP** | `STOP_INTRADAY_NONE` | Bias Bull/Bear nhưng H1 trend = None |
| **STOP** | `STOP_BIAS_INTRADAY_MISMATCH` | Bias ≠ H1 (vd Bull + H1 Down) |
| **SETUP** | `WAIT_FVG_TOUCH` | AllowTrade, chờ retest FVG H1 |
| **SETUP** | `FVG_TOUCHED_WAIT_MSS` | H1 retest + M5 trong FVG; live L0/H0 M5, chờ body phá L0 (bear) |
| **SETUP** | `MSS_OK_WAIT_M5_FVG` | MSS khóa, chờ M5 FVG |
| **SETUP** | `M5_FVG_WAIT_RETRACE` | Có M5 FVG, chờ hồi fill entry |
| **SETUP** | `READY_FOR_LIMIT` | Giá trong vùng entry, sắp đặt limit |
| **TRADE** | `LIMIT_ORDER_PENDING` | Có lệnh limit MSS magic |
| **TRADE** | `ON_TRADE` | Có position MSS magic |

`ENUM_ICT_MSS_PHASE` (nội bộ) vẫn giữ; `IctEaState_Refresh()` map sang state trên sau mỗi `IctMss_Update` / `IctMssEntry_Update`.

API: `ICT2026_GetEaState()`, `ICT2026_GetEaStateCode()`, `ICT2026_GetEaStateDetail()`.

### MSS entry (Confirm TF, v1.115)

Khi `IsAllowTrade`, state machine `g_ictLowTf.mss`:

| Phase | Điều kiện |
|-------|-----------|
| `H1_TOUCH` | **Retest FVG H1** OK: bias + `repPd` + lấp ≥ `InpMssH1MinFillPct` trên H1 |
| `CHOCH` (MSS) | Sau retest FVG H1: M5 pullback → **phá L0** (bear HTF) hoặc **phá H0** (bull HTF); khóa `chochLocked` |
| `M5_FVG` | FVG `InpConfirmTf` cùng hướng bias, sau thời điểm CHoCH |
| `ENTRY_FILL` / `READY` | Giá hồi lấp ≥ `InpMssEntryFillPct` vào M5 FVG đó |

Sweep liquidity: **chưa** (phase sau). Module: `MssSetup.mqh`, pool `ConfirmFvg.mqh`.

**Lệnh limit (v1.116)** — khi có M5 FVG (`MssEntry.mqh`):

| | Bull | Bear |
|--|------|------|
| Limit | Buy @ `upper` M5 FVG | Sell @ `lower` M5 FVG |
| SL | Dưới `L0` M5 − buffer | Trên `H0` M5 + buffer |
| TP | Entry + `InpMssMinRR`×R | Entry − `InpMssMinRR`×R |
| Size | `InpMssRiskPct` % balance | |

`InpMssTradeEnabled`, `InpMssMagic`, `InpMssOnePosition`.

### IsAllowTrade

Mục tiêu: **phát hiện sớm đảo chiều H1** khi CHoCH — không cần đợi HH-HL/LH-LL rõ.

```text
true  ⟺  Daily Bias hướng Up   AND H1 hướng Up   (Up rõ HOẶC Bull sớm)
       OR Daily Bias hướng Down AND H1 hướng Down (Down rõ HOẶC Bear sớm)

false ⟺  khác hướng, hoặc Bias/Trend = None/Range
```

`Bull sớm` / `Bear sớm` vẫn map `ICT_TREND_UP` / `ICT_TREND_DOWN` — `IctIntraday_TrendAlignsWithBias()` xử lý cả hai phase.

| Daily Bias | Intraday H1 | IsAllowTrade |
|------------|-------------|--------------|
| Up / Bull sớm | Up / Bull sớm | **true** |
| Down / Bear sớm | Down / Bear sớm | **true** |
| Up | Down / Bear sớm | false |
| Down | Up / Bull sớm | false |
| RANGE / NONE | bất kỳ | false |

---

<a id="business-logic"></a>

## Logic nghiệp vụ

### Mục tiêu Daily Bias

Trả lời: **hôm nay ưu tiên BUY, SELL, RANGE, hay đứng ngoài (NONE)?**

Daily Bias là **filter hướng**, không phải tín hiệu entry.

---

### Tầng 1 — Structural Bias (ưu tiên cao nhất)

Build bộ **4 swing** trên `InpBiasTf`: **H0, L0, H1, L1** (ghép theo leg, không lấy 2 đỉnh + 2 đáy tách rời).

| Bias | Điều kiện | Thứ tự thời gian |
|------|-----------|------------------|
| **Bull** | `H0 > H1` và `L0 > L1` (HH-HL) | L1 → H1 → L0 → H0 |
| **Bear** | `H0 < H1` và `L0 < L1` (LH-LL) | H1 → L1 → H0 → L0 |
| **None** | Không đủ 4 swing hoặc cấu trúc lẫn lộn | — |

**Fib (tùy chọn):**

- Công thức: sóng hồi **H1→L0** ≥ `InpFibMinRatio` × sóng **L1→H1**
- `InpRequireFib = false` (mặc định): Fib chỉ ghi nhận `fibOk`, không chặn structural
- `InpRequireFib = true`: structural chỉ hợp lệ khi `fibOk = true`

---

### Key Level

| Structural | Key LV1 | Key LV2 |
|------------|---------|---------|
| **Bull** | L0 | H0 |
| **Bear** | H0 | L0 |

- **Phá Key** = thân nến (`max/min` open–close) trên bar **đã đóng** (shift = 1)
- Không dùng wick để xác nhận phá level

---

### BOS vs CHoCH (Key H0 / L0, body close)

| Event | Ý nghĩa | Bear (LH-LL) | Bull (HH-HL) |
|-------|---------|--------------|--------------|
| **CHoCH** | Đảo | Body phá **H0** | Body phá **L0** |
| **BOS** | Tiếp diễn | Body phá **L0** | Body phá **H0** |

- **Phá level** = thân nến bar **đã đóng** (shift = 1)
- CHoCH kiểm tra trước BOS
- Logic trong `IctResolveTrend()` (`StructureTrend.mqh`)

---

### Tầng 2 — Previous Day Model (`IctUpdateHTFBias`)

Dùng khi **bias = None** (không rõ và không ở phase sớm).

So sánh nến **shift=1** vs **shift=2** trên `InpBiasTf`:

| Điều kiện | HTF Bias | Daily Bias |
|-----------|----------|------------|
| `Close[1] > High[2]` | UP | **BULL** |
| `Close[1] < Low[2]` | DOWN | **BEAR** |
| Inside bar (`High[1] ≤ High[2]` và `Low[1] ≥ Low[2]`) | SIDEWAY | **RANGE** (range = High/Low[2]) |
| Close trong range[2] nhưng không inside | SIDEWAY | **RANGE** (range = High/Low[1]) |
| Không khớp | NONE | **NONE** |

*Nguồn tham khảo: `XAU_H1_M5_Pullback.mq5` → `UpdateHTFBias`.*

---

### Daily Bias — cùng logic rõ / sớm

Giống H1: `IctResolveTrend()` trên D1. Chưa có bias structural → fallback **Previous Day Model**.

---

### Mức giá tham chiếu (PDH / PDL / EQ)

| Field | Công thức |
|-------|-----------|
| `pdh` | High[1] |
| `pdl` | Low[1] |
| `pdc` | Close[1] |
| `eq` | (pdh + pdl) / 2 |

*Chưa dùng Premium/Discount filter — xem [Roadmap](#roadmap).*

---

### Label swing trên chart (`Draw.mqh`)

Tự động theo **TF chart đang mở** — chỉ vẽ swing TF hiện tại + TF **lớn hơn**, ẩn TF **nhỏ hơn**:

| Chart hiện tại | Hiển thị |
|----------------|----------|
| **Bias** (D1, W1…) | `bH0, bH1, bL0, bL1` |
| **Intraday** (H1, H4…) | `b*` + `i*` |
| **Confirm** (M5, M15…) | `b*` + `i*` + `H0–L1` |

Bật/tắt từng lớp: `InpDrawBiasSwingLabels`, `InpDrawIntraSwingLabels`, `InpDrawConfirmLabels`.

So sánh `PeriodSeconds(chart)` với `InpBiasTf`, `InpIntradayTf`, `InpConfirmTf`.

---

### Panel chart (góc trên trái)

Cập nhật **mỗi khi mở nến mới** của `InpBiasTf` (mặc định D1).

**Màu theo hướng (mỗi dòng riêng):**

| Dòng | Xanh (`Lime`) | Đỏ (`OrangeRed`) |
|------|---------------|------------------|
| **Bias** + lý do | Up / Bull sớm | Down / Bear sớm |
| **Intraday** + lý do | Up / Bull sớm | Down / Bear sớm |

- **Cùng xanh** hoặc **cùng đỏ** → Daily + H1 cùng hướng → canh trade (`IsAllowTrade: true`, màu Aqua)
- **Bias xanh + Intraday đỏ** (hoặc ngược lại) → lệch hướng, nhìn phát hiện ngay
- Header / separator: xám; `IsAllowTrade: false` khi lệch: xám nhạt

Ví dụ hiển thị:

```
ICT2026 PERIOD_D1 | D[0] chưa đóng
Bias: Up
Ly do: HH-HL, D[1].close > D[2].High
-------------------------
PERIOD_H1 | H[0] dang chay
Intraday: Up
Ly do: HH-HL, BOS H[1].close > Key(H0)
IsAllowTrade: true
```

| Thành phần `displayReason` | Khi nào |
|----------------------------|---------|
| `HH-HL` / `LH-LL` | Có structural bias |
| `BOS D[1].close > Key(H0)` / `< Key(L0)` | BOS trên bar D[1] |
| `CHoCH D[1].close … Key` | CHoCH trên bar D[1] |
| `D[1].close > D[2].High` | Previous day outside up |
| `D[1].close < D[2].Low` | Previous day outside down |
| `Inside D[1] trong D[2]` | Inside bar |

Màu chữ: **Up** = xanh lá, **Down** = đỏ cam, **Range** = vàng, **None** = xám.

**Lưu ý MT5:** `OBJ_LABEL` **không** hiển thị xuống dòng `\n` — panel dùng **nhiều label** (`ICT26_PNL_0`, `ICT26_PNL_1`, …) xếp dọc.

---

<a id="file-reference"></a>

## Mô tả từng file

| File | Trách nhiệm |
|------|-------------|
| `Types.mqh` | `ENUM_ICT_BIAS`, `ENUM_ICT_STRUCT`, `ENUM_ICT_MS_EVENT`, `IctSwingSet`, `IctDailyBiasState` |
| `Config.mqh` | Input: TF, swing range, lookback, Fib, debug |
| `Swing.mqh` | Pivot detection, build swing set, classify HH-HL/LH-LL, key level, Fib validate |
| `StructureCore.mqh` | `IctBodyBreak*`, `IctDetectStructureEvent` |
| `DailyBias.mqh` | `IctUpdateHTFBias`, veto, `g_ictDailyBias` |
| `IntradayStructure.mqh` | `IctIntraday_Update`, trend, `isAllowTrade`, `g_ictIntraday` |
| `Panel.mqh` | Bias + Intraday + IsAllowTrade trên chart |
| `ICT_2026.mq5` | Init/Update Daily + Intraday → panel |

---

<a id="api"></a>

## API

```cpp
#include <ICT2026/DailyBias.mqh>

// Init (gọi OnInit)
bool ok = IctDailyBias_Init(_Symbol);

// Update (gọi OnTick — return true khi có nến Bias TF mới)
if(IctDailyBias_Update(_Symbol) || IctIntraday_Update(_Symbol))
   IctPanel_Render(_Symbol);

bool allow = IctIntraday_IsAllowTrade();
ENUM_ICT_TREND t = ICT2026_GetIntradayTrend();

// Đọc state
IctDailyBiasState db;
IctDailyBias_Get(db);  // struct: tham số phải dùng &
// db.bias, db.structural, db.lastEvent, db.pdh, db.pdl, db.eq
// db.keyLv1, db.keyLv2, db.swings, db.reason

bool bull = IctDailyBias_IsBull();
bool bear = IctDailyBias_IsBear();

// EA export
ENUM_ICT_BIAS ICT2026_GetDailyBias();
```

---

<a id="inputs"></a>

## Input

| Input | Mặc định | Mô tả |
|-------|----------|-------|
| `InpBiasTf` | D1 | Timeframe xác định Daily Bias |
| `InpSwingRange` | 2 | Số nến mỗi bên để xác nhận pivot |
| `InpSwingLookback` | 300 | Số bar quét swing lịch sử |
| `InpFibMinRatio` | 0.382 | Tỷ lệ Fib tối thiểu (0 = luôn pass) |
| `InpRequireFib` | false | Bắt buộc Fib OK mới dùng structural veto |
| `InpIntradayTf` | H1 | TF intraday structure |
| `InpIntradaySwingRange` | 2 | Pivot intraday |
| `InpIntradaySwingLookback` | 120 | Lookback quét pivot |
| `InpIntradayRecentBars` | 80 | Chỉ pivot trong N bar gần nhất (2H+2L) |
| `InpDrawPanel` | true | Hiển thị panel bias góc trên trái |
| `InpPanelX` / `InpPanelY` | 12 / 28 | Vị trí panel (pixel) |
| `InpPanelFontSize` | 10 | Cỡ chữ panel |
| `InpPanelLineSpacing` | 22 | Khoảng cách giữa các dòng (px) |
| `InpDrawChartLabels` | true | Master: vẽ label swing |
| `InpDrawBiasSwingLabels` | true | bH0–bL1 |
| `InpDrawIntraSwingLabels` | true | iH0–iL1 |
| `InpDrawConfirmLabels` | true | H0–L1 (M5) |
| `InpChartLabelFontSize` | 9 | Cỡ chữ label chart |
| `InpConfirmTf` | M5 | TF confirm swing |
| `InpConfirmSwingRange` | 2 | Pivot confirm |
| `InpConfirmSwingLookback` | 80 | Lookback confirm |
| `InpConfirmRecentBars` | 40 | Pivot gần nhất confirm |
| `InpLowTf` | M5 | Low TF trend (phase sau) |
| `InpFvgTf` | H1 | TF quét iTF FVG |
| `InpFvgLookbackBars` | 60 | Lookback quét FVG (init) |
| `InpFvgUsedFillPct` | 38.2 | % lấp → Used |
| `InpFvgExpireDays` | 3 | Xóa Available sau N ngày |
| `InpDrawFvgZones` | true | Vẽ FVG + P/D |
| `InpDebug` | true | Log `[ICT2026/DailyBias]` mỗi lần update |

---

<a id="roadmap"></a>

## Chưa implement

| Tính năng | Ghi chú |
|-----------|---------|
| Tầng 3 intraday confirm (logic trade) | Chưa có — chỉ vẽ pivot M5 (H0–L1) |
| Entry từ iTF FVG Available | Chưa có — chỉ scan + vẽ |
| Premium / Discount filter | Chỉ buy discount, sell premium |
| Vẽ Key / PDH-PDL trên chart | Panel bias đã có; chưa vẽ level |
| Entry H1 / M5 | MSS, FVG, OB — module riêng |
| Roll swing incremental | Hiện rebuild full swing set mỗi nến |
| Session filter | Asia / London / NY |

---

<a id="changelog"></a>

## Changelog

### v1.142 — Fix Stats đếm thiếu lệnh

- Bug v1.141: `IctMssStats_ComputeR` gọi `HistorySelectByPosition` **bên trong vòng quét history toàn cục**
  → selection bị thay → các index sau đọc từ history của 1 position → chỉ đếm được lệnh đầu tiên
- Fix: 2-pass — collect ticket/reason/net trước (selection toàn cục còn nguyên), tính R sau
- Thêm log journal `[ICT2026/Stats] Recompute …` để verify mỗi lần quét

### v1.141 — Stats lệnh MSS trên panel

- `Stats.mqh`: `IctMssStats_Recompute` quét HistoryDeals theo magic
- Tính: total, TP, SL, khác, win, loss, sumR, netProfit
- R thực = (close - entry)/(entry - SL) lấy từ deal IN + order SL
- WR = TP / (TP+SL); Ravg = sumR/total
- Hiển thị 2 dòng cuối panel: counts + WR/Ravg/Net
- Recompute trên `OnInit` và sau mỗi `OnTradeTransaction` close

### v1.164 — Entry chọn M5 FVG vs MSS keyLV theo SL gần nhất

- **Bỏ yêu cầu phải có M5 FVG**: gating mở từ `phase >= ICT_MSS_CHOCH` (sau MSS lock) — không chờ M5_FVG
- Thêm field `chochBias` trong `IctMssState` (lưu side BEAR/BULL khi `TryLockMss` thành công)
- `IctMssEntry_ComputeLevels`: tính 2 candidate entries, chọn cái có risk = `|entry − SL|` nhỏ hơn:
  - **A) M5 FVG limit** (nếu có): `IctMssEntry_LimitPrice(m5Zone)`
  - **B) MSS keyLV**: `chochKeyLevel` (L0 phá cho BEAR, H0 phá cho BULL)
- Lọc validity: limit phải đúng phía thị trường (`entry < ask` cho BUY, `entry > bid` cho SELL), risk > 0
- Nếu có FVG nhưng entry@FVG cho risk lớn hơn entry@MSS → chọn MSS
- Nếu chưa có FVG → chọn MSS ngay khi MSS lock
- DisplayReason in nguồn entry: `"M5 FVG (risk X < MSS Y)"` hoặc `"MSS keyLV (risk X ≤ FVG Y)"` / `"MSS keyLV (no M5 FVG)"`
- Trên mỗi tick: nếu candidate mới tốt hơn (M5 FVG xuất hiện sau MSS) → cancel limit cũ + replace

### v1.160 — Pending timeout 4h → reset chờ FVG mới

- Input: `InpMssPendingExpireHours = 4` (mặc định, 0 = không timeout)
- Tracked `pendingPlacedTime` trong `IctMssState`
- Mỗi tick (`IctMssEntry_CheckPendingTimeout`): nếu `TimeCurrent() - pendingPlacedTime ≥ N×3600s` hoặc order biến mất (broker expire) → `OrderDelete` + `MarkM5FvgUsed` + `IctMss_ResetState` + set `g_ictMssAfterCloseGuard`
- Hành vi giống TP/SL close: reset về `WAIT_FVG_TOUCH`, chỉ accept H1 FVG có touch sau timeout
- Bỏ qua nếu đang có position magic (chỉ tác động lên pending)

### v1.140 — Hủy pending cuối phiên Mỹ (EOD)

- Input: `InpMssCancelPendingEod` (true), `InpMssEodHour` (23), `InpMssEodMinute` (0) — **server time**
- Mỗi tick: nếu có `pendingTicket` chưa fill + thời gian ≥ EOD → `OrderDelete` + `IctMss_ResetState`
- Idempotent theo ngày: dùng `s_lastEodHandledDate` để không lặp
- Bỏ qua nếu đang có position magic (chỉ hủy pending, không động vào lệnh đã khớp)

### v1.139 — Reset MSS pipeline sau SL/TP/close (option A)

- `OnTradeTransaction` lọc `DEAL_ENTRY_OUT` + magic → `IctMss_OnPositionClosed`
- Mark **M5 FVG → Used**, `IctMss_ResetState`, journal lý do (SL/TP/Manual/…)
- Fallback: detect transition `hadPosition → false` trong `IctMssEntry_Update` (miss OnTradeTransaction)
- Sau close: EaState = `WAIT_FVG_TOUCH` → `SelectNearestH1Poi` (H1 cũ đã Used từ v1.136 → bỏ qua)

### v1.138 — POI H1 = FVG chưa Used **gần giá nhất**

- `IctMss_SelectNearestH1Poi`: khoảng cách bid → FVG; bỏ qua Used; tie → FVG mới hơn
- H1 FVG **không** auto-Used theo % fill (chỉ MSS fail/OK đánh dấu Used)
- IDLE: luôn chọn lại POI gần nhất; chạm → `FVG_TOUCHED_WAIT_MSS`

### v1.137 — Fill FVG mặc định 25% (thay 38.2%)

- `InpFvgUsedFillPct`, `InpMssEntryFillPct`, `InpMssH1MinFillPct` = 25

### v1.136 — FVG Used khi MSS OK (giữ giá)

- MSS khóa → `IctMss_MarkFvgUsedOnMssSuccess` (POI đã phục vụ, tiếp M5 FVG/entry)
- Used fail vs Used OK: cùng `ICT_FVG_USED`, journal khác nhau
- Pipeline MSS/entry vẫn chạy sau Used nếu `chochLocked`

### v1.135 — Tách AllowTrade vs FVG Used

- `AllowTrade=false`: pause MSS (`ResetPipelineKeepWatch`), **không** Used FVG
- `FVG Used`: chỉ khi H1 **body đóng xuyên** FVG (`IctMss_FailFvgH1Body`)
- `h1WatchFvgId`: theo dõi invalidation kể cả khi H1 lệch Bias

### v1.134 — FVG Used khi H1 body xuyên; skip FVG Used trong target

- `IctMss_SelectTargetH1Fvg`: bỏ qua mọi FVG Used
- MSS chỉ khóa nếu break sau `h1TouchTime`

### v1.133 — Retest = giá chạm FVG; H1 chỉ hủy khi body đóng xuyên

- Retest: `IctMss_HasFvgPriceTouch` (H1 touch / M5 overlap / giá live trong gap)
- Không còn “chờ râu H1”; `InpMssH1RetestWickOnly` legacy (bỏ qua)
- Hủy: `iClose` H1[1] xuyên FVG — râu xuyên vẫn chờ MSS

### v1.132 — MSS đơn giản: live L0/H0 M5 + hủy H1 body phá FVG

- `FVG_TOUCHED_WAIT_MSS`: cập nhật liên tục `liveL0`/`liveH0` từ `IctBuildConfirmSwingSet` (M5 bull khi bear HTF)
- MSS bear: body phá **L0** hiện tại → vẽ MSS tại L0, SL tại H0
- Hủy setup: mỗi nến H1 mới, body đóng **trên** FVG (bear) / **dưới** FVG (bull)
- Vào setup: H1 retest + ít nhất một nến M5 overlap H1 FVG
- Bỏ gate “MSS xa H1 FVG”; vẽ L0 live (nét chấm) trước khi khóa MSS

### v1.131 — EA state machine (STOP / SETUP / TRADE)

- `EaState.mqh`: `IctEaState_Refresh()`, panel 3 dòng state đầu
- STOP: no bias, range, H1 none, bias≠H1
- SETUP: WAIT_FVG_TOUCH → … → READY_FOR_LIMIT
- TRADE: LIMIT_ORDER_PENDING, ON_TRADE

### v1.130 — MSS = phá L0/H0 M5 (định nghĩa CHoCH đúng)

- Bear HTF: hồi Bearish H1 FVG → M5 pullback (bull cục bộ) → **MSS↓ = body phá L0** (đáy tạo H0)
- Bull HTF: hồi Bullish H1 FVG → M5 pullback (bear cục bộ) → **MSS↑ = body phá H0**
- SL: H0 (sell) / L0 (buy); đường MSS = mức L0/H0 bị phá

### v1.129 — CHoCH POI: H0/L0 cục bộ trong FVG (giống ví dụ ICT)

- Bear: đỉnh phản ứng **trong H1 FVG** → L0 cục bộ → CHoCH↓ phá L0 (không dùng L1 xa POI)
- Vẽ: đường CHoCH = mức **bị phá**; `H0 POI` = đỉnh phản ứng tại gap

### v1.128 — FVG M5 nhỏ; retest H1 = râu chạm POI

- Lọc gap ATR/points/bar%: **chỉ H1**; M5 confirm FVG không lọc kích thước
- `InpMssH1RetestWickOnly` (mặc định true): arm MSS khi râu H1 chạm FVG, không cần thân lấp %

### v1.127 — CHoCH khóa thời điểm (không nhảy theo swing M5)

- `IctMss_FindFirstChochAfterFvgRetest`: nến M5 **đầu tiên** sau retest FVG H1 body phá swing
- `chochLocked`: key / H0–L0 / `chochTime` không đổi khi pivot M5 update
- Vẽ + SL dùng giá trị đã khóa, không live-detect lại

### v1.126 — Thuật ngữ: Retest FVG H1 (POI), không ghi chung “H1 retest”

- Panel/journal: “Retest FVG H1”, “Chờ retest FVG H1 … (lấp trên H1)”
- `IctMss_FailFvgH1Body`, `IctMss_CheckH1WatchInvalidation`, `chochLocked`
            |

### v1.125 — MSS = phá swing M5 (confirm), build structure như chart

- `IctBuildConfirmSwingSet`: H0/H1/L0/L1 M5 dùng chung cho vẽ + MSS
- MSS/CHoCH: chỉ xét body phá L0/L1/H0/H1 sau H1 touch (bỏ pivot trong FVG)
- Bear: phá L0 sau H0, hoặc CHoCH phá L1 (bull→bear), hoặc BOS phá L1 (bear)

### v1.124 — Sửa detect CHoCH↓ sau H1 retest (L0 M5)

- CHoCH: ưu tiên `H0/L0` M5 (`BuildSwingSetRecentPivots`) + body phá trong lookback (không chỉ bar 1)
- Key level: swing **sau** đỉnh phản ứng (`IctFindMostRecentNewer`), fallback swing cũ hơn
- Bỏ `keyLo.time < tTouch` (gây miss khi L0 hình thành trước touch H1 trên timeline)

### v1.123 — Vẽ MSS sau H1 touch + journal chặn lệnh

- `MssDraw`: từ `H1_TOUCH` — vạch touch, mức 38.2% H1, CHoCH/H0 (kể cả khi pipeline chưa advance)
- `Journal.mqh` + `InpMssLogJournal`: `[ICT2026/MSS]` pipeline, `[ICT2026/Entry] Chặn lệnh:` khi không đặt được limit

### v1.122 — MSS gần H1 FVG (không siết chặt)

- Vùng gần: buffer % gap + ATR; bear thêm `InpMssExtraBelowGapPct` dưới `lower` (CHoCH/M5 FVG ngay dưới FVG vẫn hợp lệ)
- CHoCH OK nếu **key level** hoặc **H0** nằm trong vùng gần (không bắt buộc trong FVG)
- `InpMssMaxM5BarsAfterTouch=0` mặc định = không giới hạn thời gian

### v1.121 — FVG qualify: overlap Premium/Discount; fill từ cạnh FVG

- `IctFvg_OverlapsPremium` / `OverlapsDiscount`: bear MSS khi FVG chạm vùng Premium (kể cả nửa dưới trong Discount)
- `maxFillRatio`: % lấp theo chiều cao FVG (`lower`→`upper` bear), không theo pdEq

### v1.120 — MSS đúng thứ tự: retest H1 Premium/Discount → CHoCH thuận bias

- Target H1: Premium **cao nhất** (bear) / Discount **thấp nhất** (bull) — không nhảy CHoCH khi chưa retest
- CHoCH: đỉnh phản ứng **trong** H1 FVG sau retest → phá key **down** (bear) / **up** (bull)
- Vẽ: vàng **CHoCH↓** = đáy key; nét đứt **H0** = đỉnh MSS (SL)

### v1.119 — Vẽ CHoCH + H0/L0 MSS trên chart (`MssDraw.mqh`)

- Vàng: đường **CHoCH** (key level) | Vàng nét đứt: **H0/L0** swing MSS
- Aqua/đỏ/xanh: entry / SL / TP khi có pending
- `InpDrawMssChoch`

### v1.118 — MSS phải gần / trong H1 FVG

- CHoCH/M5 FVG **gần** H1 FVG: ± buffer + mở rộng phía dưới (bear) / trên (bull); key CHoCH hoặc H0 đều được tính
- Thời gian: ≤ `InpMssMaxM5BarsAfterTouch` M5 bar sau lần chạm H1 FVG
- M5 FVG phải overlap vùng H1 FVG mở rộng

### v1.117 — MSS entry: SL = H0/L0 M5, TP min 2R

- Sell limit @ **lower** M5 FVG | Buy limit @ **upper**
- SL: trên **max(H0,H1)** M5 (bear) / dưới **min(L0,L1)** M5 (bull) + `InpMssSlSpreadMult`×spread
- TP: tối thiểu `InpMssMinRR` (mặc định 2R), không phụ thuộc swing H1

### v1.116 — MSS limit entry: FVG edge, SL swing CHoCH, TP trước iH0/iL0

### v1.115 — MSS Confirm TF (H1 touch → CHoCH → M5 FVG → fill 38.2%)

- `repPd` / MSS H1: overlap Premium (bear) hoặc Discount (bull); fill % theo biên FVG
- `MssSetup.mqh` + pool `ConfirmFvg` (M5); sweep tạm bỏ
- Panel dòng MSS; vẽ CFVG trên chart

### v1.114 — FVG: bỏ label text, màu bull xanh / bear đỏ / used xám

### v1.113 — PD swing 1: pivot gần FVG (shift), bỏ wick nến

- `IctFindNearestSwingHighBefore` / `LowBefore`: cùng logic `IctFindMostRecentOlder` neo theo `iBarShift(createdTime)`
- Không fallback `iHigh`/`iLow` từng nến (gây đỉnh PD cao hơn swing vàng trên chart)
- Swing 2: `IctFindFirstSwing*AfterShift` — đáy/đỉnh đầu tiên sau nến FVG

### v1.112 — PD lock: không cập nhật đỉnh sau pdComplete

- `pdSwing1Set`: đỉnh/đáy swing 1 snapshot một lần
- `pdComplete`: khóa toàn bộ P/D; bỏ max(iH0,iH1) live gây đỉnh bay lên

### v1.111 — Lọc FVG: gap tối thiểu theo ATR / range nến B

### v1.110 — PD bear: đỉnh = iH0/iH1 (không còn pivot thấp nhất trên gap)

### v1.109 — Định nghĩa lại vẽ FVG / P/D (gọn, không gộp nhóm)

- FVG: `createdTime` → Used hoặc expire 3 ngày; chỉ vẽ thuận bias
- P/D: `createdTime` → swing 2; đỉnh/đáy theo pivot; bỏ nhóm PD chồng chart

### v1.108 — FVG: quét N bar; gap 3 nến (không bắt B giảm)

- `InpFvgScanBarsPerUpdate` (40): mỗi nến mới quét lại N bar — fix FVG sau iH1 bị bỏ qua
- Khi `IsAllowTrade` vừa bật → full lookback một lần

### v1.107 — Fix P/D không vẽ (khóa sau SyncAllPd)

### v1.106 — P/D: đỉnh gần FVG + nhóm FVG liền kề

- Bear `pdHigh`: pivot gần nhất trên FVG (không còn `max(iH0,iH1)`)
- FVG bear liền kề → một vùng P/D chung; vẽ một lần / nhóm

### v1.105 — Khóa P/D khi FVG Used

- `pdLocked` trên `IctFvgZone`: không cập nhật `pdHigh`/`pdLow` sau khi FVG Used

### v1.104 — PD khớp iH0/iH1 (trên) và iL0 (dưới) trên chart

- Bỏ quét pivot lịch sử (gây khối PD quá cao/thấp)
- Bear: `pdHigh = max(iH0,iH1)`, `pdLow = iL0` (hoặc min low chạy trước khi có iL0)
- Bull: `pdLow = min(iL0,iL1)`, `pdHigh = iH0` (hoặc max high chạy)

### v1.103 — Premium/Discount theo từng FVG + đáy/đỉnh leg động

- Bear: `pdHigh` = pivot trên FVG; `pdLow` = min low chạy đến khi swing low xác nhận
- Bull: đối xứng (`pdLow` dưới FVG, `pdHigh` chạy / swing high)
- Cập nhật P/D mỗi `UpdateZoneState` + vẽ lại khi `pdHigh`/`pdLow` đổi

### v1.102 — FVG/P/D: cắt vẽ đúng lần chạm đầu tiên (thời gian)

- `Fvg.mqh`: `firstTouchTime` = **nến sớm nhất** sau khi tạo FVG (min `t`), không còn lấy nến mới nhất trong vòng quét
- Bỏ `return` sớm khi fill 100% (vẫn ghi nhận chạm trên mọi nến)
- Chạm: overlap wick/body với vùng; gồm nến đang hình thành (shift 0)
- `LowTfTrend.mqh`: `IctLowTfTrend_TickRefresh` — cập nhật độ dài vẽ mỗi tick khi phát hiện chạm mới

### v1.10 — iTF FVG (Available/Used) + Premium/Discount

- `Fvg.mqh`, `FvgDraw.mqh`, `LowTfTrend.mqh`
- Swing labels theo TF chart (b* / i* / H0–L1)
- Scan FVG khi `IsAllowTrade`; khóa vẽ; expire 3 ngày

### v1.09 — Label swing: b* (Bias), i* (Intraday), H0–L1 (Confirm M5)

- `Draw.mqh`: 3 lớp label, bật/tắt riêng
- Confirm: `InpConfirmTf` mặc định M5 (scaffold entry layer)

### v1.081 — CHoCH ưu tiên trước LH-LL rõ (flip Bull sớm khi phá H0)

- Fix: Bear sớm / LH-LL + H[1] phá H0 → Bull sớm (trước đó bị ghi đè Down)

### v1.08 — Bỏ lock Key; trend rõ vs Bull/Bear sớm

- Xóa `keysLocked`
- `IctResolveTrend()`: HH-HL/LH-LL = rõ; CHoCH phá H0/L0 = sớm; giữ sớm khi pivot lộn xộn
- Daily + H1 dùng chung `StructureTrend.mqh`

### v1.07 — BOS/CHoCH trên swing cũ H1/L1 + Daily lock Key

- `IctDetectTrendSwingEvent()`: BOS/CHoCH theo trend + phá H1/L1 (body close)
- Intraday: trend Down + phá H1 → CHoCH Up (fix case H0 > H1)
- Daily: cơ chế `keysLocked` giống H1; bỏ veto mỗi bar

### v1.06 — Intraday: khóa Key H0/L0, chỉ đổi trend khi phá Key

- `keysLocked`: sau khi có trend, giữ Key H0/L0
- Không reset trend khi pivot lộn xộn sau CHoCH
- CHoCH/BOS trên Key → flip hoặc continue + re-lock swing mới

### v1.051 — Bỏ nhãn trend/bias trên chart

- Xóa vẽ `Intraday trend` / `Daily Bias` trên giá (đủ thông tin ở panel góc trái)
- `Draw.mqh` chỉ còn label **H0–L1** (tắt bằng `InpDrawChartLabels = false`)

### v1.05 — Vẽ chart: label swing (đã thu gọn)

- `Draw.mqh`: H0–L1 trên pivot intraday

### v1.04 — Intraday: 2 pivot gần nhất (fix LH-LL vs HH-HL)

- `IctBuildSwingSetRecentPivots`: 2H+2L trong `InpIntradayRecentBars` thay cho leg 4 swing trên H1
- Tránh intraday Up/HH-HL khi chart đang LH-LL rõ
- Debug log H0–L1 + Key levels

### v1.03.1 — Panel line spacing

- `InpPanelLineSpacing` (mặc định 22px)
- Tách `Bias` / `Ly do` và `Intraday` / `Ly do` thành 2 dòng

### v1.03 — Panel intraday hiển thị đúng trên chart

- Tách panel thành nhiều `OBJ_LABEL` (MT5 không hỗ trợ `\n` trong 1 label)
- `OnTick`: vẽ panel lần đầu + mỗi khi nến D1/H1 mới
- `OnChartEvent(CHARTEVENT_CHART_CHANGE)`: refresh panel khi đổi chart

### v1.02 — Intraday Structure (H1) + IsAllowTrade

- `IntradayStructure.mqh`: HH-HL/LH-LL, BOS continue, CHoCH đảo trend
- `IsAllowTrade`: Bias Up + Intraday Up, hoặc Bias Down + Intraday Down
- Panel: intraday dưới bias + `IsAllowTrade: true/false`
- `StructureCore.mqh`: tách body break / detect event dùng chung
- Input: `InpIntradayTf`, `InpIntradaySwingRange`, `InpIntradaySwingLookback`
- API: `ICT2026_GetIntradayTrend()`, `ICT2026_IsAllowTrade()`

### v1.01.2 — Sửa compile MQL5 (struct reference)

- Struct **bắt buộc** truyền bằng `&` (không by value, không `const &`)
- Không return `const Struct &` — dùng `void Get(Struct &out)` hoặc return struct by value
- `IctClassifyStructure(IctSwingSet &sw)` v.v.

### v1.01.1 — Sửa compile MQL5 (lần 1)

- `IctApplyVetoBias()` / `IctDailyBias_Reset()` thao tác `g_ictDailyBias`

### v1.01 — Panel bias góc trên trái

- `Panel.mqh`: OBJ_LABEL góc trên trái, cập nhật khi nến `InpBiasTf` mới
- `IctBuildDisplayReason()`: lý do dạng `HH-HL`, `D[1].close > D[2].High`, BOS/CHoCH
- `IctBiasDisplayShort()`: Up / Down / Range / None
- `IctDailyBias_Update()` return `bool` (true = nến mới)
- Input: `InpDrawPanel`, `InpPanelX`, `InpPanelY`, `InpPanelFontSize`

### v1.00 — Daily Bias module (initial)

- Tạo module `ICT2026` độc lập (Types, Config, Swing, DailyBias)
- Structural bias: swing set H0–L1, HH-HL / LH-LL
- Key Level: Bull L0/H0, Bear H0/L0
- BOS = Continue (phá Key LV2), CHoCH = Reversal (phá Key LV1)
- Veto logic (Cách A): structural ưu tiên, CHoCH flip bias
- `IctUpdateHTFBias`: Previous Day Model (outside / inside / indecision)
- EA shell `ICT_2026.mq5`
- PDH, PDL, PDC, EQ tính từ nến shift=1
