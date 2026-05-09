# RSIForceStateEA

EA giao dich pullback theo dong luc RSI, loc trend bang EMA200, dieu phoi qua state
machine 4 trang thai. Chi dung 1 lenh moi pullback, vao bang BUY/SELL LIMIT.

## 1) Cau truc thu muc

- EA chinh: `Experts/RSIForceStateEA.mq5`
- Cac module:
  - `Experts/RSIForceStateEA/Config.mqh`        - toan bo input
  - `Experts/RSIForceStateEA/State.mqh`         - enum + struct (no globals)
  - `Experts/RSIForceStateEA/Indicators.mqh`    - handle + buffer + helper slope/cross
  - `Experts/RSIForceStateEA/Trade.mqh`         - dat lenh, sizing, partial + BE
  - `Experts/RSIForceStateEA/StateMachine.mqh`  - flow 4 state
  - `Experts/RSIForceStateEA/Visualizer.mqh`    - dashboard, stats panel, trade levels
  - `Experts/RSIForceStateEA/README.md`

Thu tu include trong file `.mq5`:

```
Layer 1 : Config -> State -> Indicators
Globals : g_State, g_Pending, g_OpenTrade
Layer 2 : Trade -> StateMachine
Layer 3 : Visualizer
```

## 2) Logic tong the

### 2.1 Cac chi bao

- `RSI(InpRSIPeriod)` - dong luc gia.
- `EMA(InpRSI_EMA9Period)` tinh tren RSI.
- `WMA(InpRSI_WMA45Period)` tinh tren RSI.
- `EMA(InpEMA200Period)` tren close - loc trend.
- `ATR(InpATRPeriod)` - dung cho trend buffer va SL.

### 2.2 Trend filter

- `Uptrend`   khi `Close > EMA200 + buffer`.
- `Downtrend` khi `Close < EMA200 - buffer`.
- `buffer`:
  - `% EMA200` mac dinh (`InpTrendBufferPercent = 0.10%`), hoac
  - `ATR-based` neu `InpUseATRTrendBuffer = true`.
- `InpSkipFlatEMA200`: bo qua khi EMA200 phang (delta giua 2 nen <= `ATR * InpFlatEMA_ATRMult`).

### 2.3 4 trang thai


| State                 | Y nghia                                            |
| --------------------- | -------------------------------------------------- |
| `STATE_NO_TRADE`      | khong co setup hop le                              |
| `STATE_WATCHING`      | da co pullback hop le, dang cho trigger            |
| `STATE_PENDING_ORDER` | da dat BUY/SELL LIMIT, dang cho khop               |
| `STATE_IN_TRADE`      | da khop, dang quan ly position (partial + BE + TP) |


### 2.4 Pullback (NO_TRADE -> WATCHING)

- Uptrend pullback:
  - `RSI < EMA9 < WMA45`
  - 3 buffer cung slope giam (kiem tra `InpSlopeLookbackBars` nen)
- Downtrend pullback (mirror).

### 2.5 Trigger entry (WATCHING -> PENDING_ORDER)

- BUY trigger:
  - RSI cat len WMA45 (so sanh nen `InpSignalBarShift` voi nen truoc).
  - EMA9 van con < WMA45 (xac nhan dong luc moi bat).
  - Khong co cross RSI/WMA45 trong `InpMinBarsBetweenCrosses` nen truoc do
  (tin hieu phai "isolated", tranh nhieu sat WMA45).
- SELL trigger (mirror).

### 2.6 Dat LIMIT ORDER

- `Entry = (Close(signal) + SwingExtreme) / 2`
  - BUY: SwingExtreme = swing low gan nhat trong `InpSwingLookbackBars`.
  - SELL: SwingExtreme = swing high gan nhat.
- Lenh dat la `BuyLimit` / `SellLimit` (khong co market chase).
- Pending song toi da `InpPendingMaxAliveBars`. Het han -> huy.
- Neu `InpInvalidateIfCrossBack = true`, khi RSI cross nguoc lai WMA45
hoac trend mat -> huy ngay.
- WATCHING song toi da `InpWatchingMaxBars`. Het han -> tro ve NO_TRADE.

### 2.7 Stop Loss


| Mode        | Cong thuc                                                      |
| ----------- | -------------------------------------------------------------- |
| `SL_SWING`  | swing extreme +/- `InpSL_SwingBufferPoints`                    |
| `SL_ATR`    | `Entry +/- ATR * InpSL_ATRMult`                                |
| `SL_HYBRID` | chon SL **rong hon** giua swing va ATR (an toan hon, mac dinh) |


### 2.8 Take Profit

- `TP = Entry +/- R * InpRiskRewardRatio` (mac dinh `2R`).

### 2.9 Quan ly trong IN_TRADE

- Risk = `InpRiskPercent` (% balance, mac dinh 1%).
- Khi gia chay duoc `InpPartialCloseAtR` (mac dinh `1.5R`):
  - Dong `InpPartialClosePercent`% volume (mac dinh 50%).
  - Doi SL ve `Entry` (BE).
- Neu volume khong the chia (volMin chan), van dich SL ve BE va bo qua partial.
- Khong lam gi them o `1R`.

### 2.10 Anti-spam

- Mot `pullback` chi sinh ra 1 lenh (`g_HasTradedThisPullback`).
- Reset bookkeeping khi trend regime doi (TREND_UP <-> TREND_DOWN/NONE).
- Khi trend doi va dang co pending nguoc huong -> huy luon.

### 2.11 Sideway filter

- `InpUseRSISidewayFilter`: khi tat ca `InpSidewayLookbackBars` gia tri RSI gan nhat
nam trong `[InpSidewayRSILow, InpSidewayRSIHigh]` -> bo qua tim setup moi.
- Filter nay chi chan `NO_TRADE -> WATCHING`, khong chan vong doi pending va
khong chan quan ly position.

## 3) Cach build va chay

1. Mo MetaEditor.
2. Mo `MQL5/Experts/RSIForceStateEA.mq5` va Compile (F7).
3. Quay lai MT5, attach EA vao chart muon trade.
4. Bat `Algo Trading`.
5. Inputs co the dieu chinh ngay tu UI khi attach.

## 4) Cac input quan trong (mac dinh)


| Input                      | Mac dinh  | Mo ta                                   |
| -------------------------- | --------- | --------------------------------------- |
| `InpMagicNumber`           | 26050901  | Magic, doi neu chay nhieu instance      |
| `InpRiskPercent`           | 1.0       | % balance/lenh                          |
| `InpRiskRewardRatio`       | 2.0       | TP = R * day                            |
| `InpPartialCloseAtR`       | 1.5       | dong 1 phan tai R nay                   |
| `InpPartialClosePercent`   | 50.0      | % volume dong tai partial               |
| `InpPendingMaxAliveBars`   | 5         | huy pending sau N nen                   |
| `InpWatchingMaxBars`       | 10        | huy WATCHING neu khong trigger          |
| `InpMinBarsBetweenCrosses` | 10        | dam bao tin hieu cross "isolated"       |
| `InpSlopeLookbackBars`     | 3         | so nen kiem tra slope                   |
| `InpSwingLookbackBars`     | 20        | tim swing extreme cho entry/SL          |
| `InpStopLossMode`          | SL_HYBRID | SL_SWING / SL_ATR / SL_HYBRID           |
| `InpSL_ATRMult`            | 1.2       | ATR multiplier khi SL theo ATR          |
| `InpSL_SwingBufferPoints`  | 20        | them buffer (point) ngoai swing extreme |
| `InpUseRSISidewayFilter`   | true      | bat/tat sideway filter                  |
| `InpSidewayRSILow / High`  | 45 / 55   | dai sideway theo RSI                    |
| `InpUseATRTrendBuffer`     | false     | doi trend buffer sang dang ATR          |


## 5) Goi y test va toi uu

- Backtest tung symbol toi thieu 6-12 thang truoc khi chay live.
- Voi index/forex bien dong cao -> bat `InpUseATRTrendBuffer = true`.
- Muon **it tin hieu hon nhung chat hon**:
  - tang `InpMinBarsBetweenCrosses`
  - tang `InpSlopeLookbackBars`
  - giu `SL_HYBRID`
- Muon **nhieu tin hieu**:
  - giam `InpSlopeLookbackBars` ve 2
  - tat `InpUseRSISidewayFilter`
- Theo doi tab `Experts` / `Journal` de xem log `[STATE]`, `[TREND]`, `[PENDING]`,
`[TRADE]`.

## 6) Visualization

EA tu hien thi dau day du de quan sat va danh gia:

### 6.1 Dashboard (goc tren-trai)

Hien thi cac dong:

- **Trend** : UP / DOWN / NONE (mau xanh / do / xam)
- **State** : `STATE_NO_TRADE` / `STATE_WATCHING` / `STATE_PENDING_ORDER` / `STATE_IN_TRADE`
- **RSI**   : gia tri RSI, EMA9, WMA45 cua nen tin hieu (`InpSignalBarShift`)
- **EMA200**: gia tri EMA200 + close hien tai
- **ATR**   : gia tri ATR
- **Context**: tuy state se in:
  - `Watching: x/N bars`
  - `Pending : dir entry alive=x/N`
  - `Trade   : dir entry partial=DONE/PEND`

### 6.2 Stats panel (goc duoi-trai)

Quet history `InpStatsLookbackDays` ngay (mac dinh 60), filter theo
`InpMagicNumber` + `_Symbol`, hien thi:

- `Total`  : so position da dong (theo POSITION_ID, dedupe partial)
- `TP hit` : so deal dong voi reason `DEAL_REASON_TP`
- `SL hit` : so deal dong voi reason `DEAL_REASON_SL`
- `Other`  : dong thu cong / partial close / expert close
- `Net PL` : tong P/L (profit + swap + commission)

### 6.3 Trade levels (TradingView style)

Khi state = `PENDING_ORDER` hoac `IN_TRADE`, ve 3 line ngang:

- `ENTRY` (dotted, `InpColorEntry`)
- `SL`    (dashed, `InpColorSL`)
- `TP`    (dashed, `InpColorTP`)

Tu dong xoa khi quay ve `NO_TRADE`.

### 6.4 Auto-attach indicators

Khi `InpAttachIndicators = true` (mac dinh):

- `EMA200` duoc them vao **main chart**.
- `RSI(14)`, `RSI_EMA9`, `RSI_WMA45` duoc them vao **subwindow moi**.

Co the tat tung phan rieng:


| Input                  | Mac dinh | Tac dung                              |
| ---------------------- | -------- | ------------------------------------- |
| `InpVisualize`         | true     | bat tat toan bo overlay               |
| `InpAttachIndicators`  | true     | tu add EMA200 / RSI cluster vao chart |
| `InpShowDashboard`     | true     | panel goc tren-trai                   |
| `InpShowStatsPanel`    | true     | panel goc duoi-trai                   |
| `InpShowTradeLevels`   | true     | line Entry/SL/TP                      |
| `InpStatsLookbackDays` | 60       | so ngay quet stats                    |


Tat ca object visual dung prefix `RSIForce`_ va duoc xoa o `OnDeinit`.

## 7) Ghi chu kien truc

- Toan bo state machine xoay quanh **closed bar** (`IsNewBar()`), tranh fire
nhieu lan trong cung 1 nen.
- Quan ly position (partial + BE) chay **moi tick** de phan ung nhanh khi
gia di chuyen.
- `SyncStateWithBroker()` chay moi tick + sau moi `OnTradeTransaction` -
dam bao state nha minh luon khop voi broker (truong hop user dong tay,
pending bi reject, v.v.).

