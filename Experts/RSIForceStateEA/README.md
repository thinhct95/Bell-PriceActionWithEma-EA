# RSIForceStateEA

EA giao dịch pullback theo động lực RSI, lọc xu hướng bằng EMA200, điều phối bằng state
machine 4 trạng thái. Mỗi pullback chỉ một lệnh, vào bằng **BUY/SELL LIMIT** (không đuổi giá market).

## 1) Cấu trúc thư mục

- EA chính: `Experts/RSIForceStateEA.mq5`
- Các module:
  - `Experts/RSIForceStateEA/Config.mqh` — toàn bộ tham số đầu vào (`input`)
  - `Experts/RSIForceStateEA/State.mqh` — `enum` + `struct` (không chứa biến global)
  - `Experts/RSIForceStateEA/Indicators.mqh` — handle chỉ báo + buffer + hàm slope/cross
  - `Experts/RSIForceStateEA/Trade.mqh` — đặt lệnh, khối lượng theo rủi ro, partial + BE
  - `Experts/RSIForceStateEA/StateMachine.mqh` — luồng 4 trạng thái
  - `Experts/RSIForceStateEA/Visualizer.mqh` — dashboard, bảng thống kê, mức Entry/SL/TP
  - `Experts/RSIForceStateEA/README.md` — tài liệu này

Thứ tự `#include` trong file `.mq5`:

```
Layer 1 : Config -> State -> Indicators
Globals : g_State, g_Pending, g_OpenTrade
Layer 2 : Trade -> StateMachine
Layer 3 : Visualizer
```

## 2) Logic tổng thể

### 2.1 Các chỉ báo

- `RSI(InpRSIPeriod)` — động lực giá.
- `EMA(InpRSI_EMA9Period)` — tính **trên** chuỗi RSI.
- `WMA(InpRSI_WMA45Period)` — tính **trên** chuỗi RSI.
- `EMA(InpEMA200Period)` — trên **giá đóng** — lọc xu hướng.
- `ATR(InpATRPeriod)` — dùng cho vùng đệm trend và SL.

### 2.2 Bộ lọc xu hướng (trend)

- **Uptrend** khi `Close > EMA200 + buffer`.
- **Downtrend** khi `Close < EMA200 - buffer`.
- **Buffer**:
  - Theo `%` EMA200 mặc định (`InpTrendBufferPercent = 0.10%`), hoặc
  - Theo ATR nếu `InpUseATRTrendBuffer = true`.
- `InpSkipFlatEMA200`: bỏ qua khi EMA200 “phẳng” (chênh lệch giữa hai nến ≤ `ATR * InpFlatEMA_ATRMult`).

### 2.3 Bốn trạng thái

| Trạng thái | Ý nghĩa |
| ----------- | ------- |
| `STATE_NO_TRADE` | Chưa có setup hợp lệ |
| `STATE_WATCHING` | Đã có pullback hợp lệ, đang chờ tín hiệu vào lệnh |
| `STATE_PENDING_ORDER` | Đã đặt BUY/SELL LIMIT, chờ khớp |
| `STATE_IN_TRADE` | Đã khớp, đang quản lý vị thế (partial + BE + TP) |

### 2.4 Pullback (`NO_TRADE` → `WATCHING`)

- Pullback trong **uptrend**:
  - `RSI < EMA9 < WMA45`
  - Cả ba đường cùng **slope giảm** (kiểm tra trên `InpSlopeLookbackBars` nến).
- Pullback trong **downtrend**: đối xứng (slope tăng).

### 2.5 Kích hoạt vào lệnh (`WATCHING` → `PENDING_ORDER`)

- **Tín hiệu BUY**:
  - RSI cắt **lên** WMA45 (so sánh nến `InpSignalBarShift` với nến trước).
  - EMA9 vẫn **dưới** WMA45.
  - Trong `InpMinBarsBetweenCrosses` nến trước đó **không** có cắt RSI/WMA45 (tín hiệu “cô lập”, tránh nhiễu sát WMA45).
- **Tín hiệu SELL**: đối xứng.

### 2.6 Đặt lệnh LIMIT

- `Entry = (Close(nến tín hiệu) + SwingExtreme) / 2`
  - **BUY**: SwingExtreme = đáy gần nhất trong `InpSwingLookbackBars`.
  - **SELL**: SwingExtreme = đỉnh gần nhất.
- Lệnh: `BuyLimit` / `SellLimit` (không vào market).
- Pending tối đa `InpPendingMaxAliveBars` nến; hết hạn → hủy.
- Nếu `InpInvalidateIfCrossBack = true`: RSI cắt ngược lại WMA45 hoặc mất trend → hủy.
- `WATCHING` tối đa `InpWatchingMaxBars` nến không có trigger → về `NO_TRADE`.

### 2.7 Stop Loss

| Chế độ | Công thức |
| ------ | --------- |
| `SL_SWING` | Cực trị swing ± `InpSL_SwingBufferPoints` (point) |
| `SL_ATR` | `Entry ± ATR * InpSL_ATRMult` |
| `SL_HYBRID` | Chọn SL **rộng hơn** giữa swing và ATR (mặc định, an toàn hơn) |

### 2.8 Take Profit

- `TP = Entry ± R * InpRiskRewardRatio` (mặc định `2R`).

### 2.9 Quản lý khi `IN_TRADE`

- Rủi ro: `InpRiskPercent` (% số dư, mặc định 1%).
- Khi giá đạt `InpPartialCloseAtR` lần **R thực tế** (mặc định `1.5R`):
  - Đóng `InpPartialClosePercent` % khối lượng (mặc định 50%).
  - Dời SL về **giá khớp** (BE).
- Nếu không chia được lot (bị `volume min` chặn): vẫn dời SL về BE, bỏ qua partial.
- Không có hành động đặc biệt tại `1R`.

### 2.10 Chống spam (một pullback — một lệnh thử)

- Biến `g_HasTradedThisPullback`: sau khi **đặt thành công** pending cho pullback hiện tại → bật.
- **Reset** `g_HasTradedThisPullback` khi:
  - Pending bị hủy / hết hạn / invalid (chưa khớp → được thử pullback khác).
  - Vị thế đã đóng hoàn toàn (TP/SL/đóng tay).
  - **Đảo chiều xu hướng có hướng** UP ↔ DOWN (đi qua `TREND_NONE` ngắn **không** coi là đảo chiều).
- Khi đảo chiều UP ↔ DOWN mà còn pending ngược hướng → hủy pending.

### 2.11 Bộ lọc RSI sideway

- `InpUseRSISidewayFilter`: nếu **tất cả** `InpSidewayLookbackBars` giá trị RSI gần nhất nằm trong `[InpSidewayRSILow, InpSidewayRSIHigh]` → bỏ qua tìm setup mới.
- Bộ lọc này **chỉ** chặn nhánh `NO_TRADE → WATCHING`; **không** chặn vòng đời pending và **không** chặn quản lý vị thế.

## 3) Cách biên dịch và chạy

1. Mở MetaEditor.
2. Mở `MQL5/Experts/RSIForceStateEA.mq5` và biên dịch (F7).
3. Quay lại MT5, gắn EA vào biểu đồ cần giao dịch.
4. Bật **Algo Trading**.
5. Có thể chỉnh `Inputs` ngay trên giao diện khi gắn EA.

## 4) Các tham số quan trọng (mặc định)

| Tham số | Mặc định | Mô tả |
| ------- | -------- | ----- |
| `InpMagicNumber` | 26050901 | Magic; đổi nếu chạy nhiều bản EA |
| `InpRiskPercent` | 1.0 | % số dư / mỗi lệnh |
| `InpRiskRewardRatio` | 2.0 | TP = R × hệ số này |
| `InpPartialCloseAtR` | 1.5 | Chốt một phần khi đạt R này (phải < RR) |
| `InpPartialClosePercent` | 50.0 | % khối lượng chốt partial |
| `InpPendingMaxAliveBars` | 5 | Hủy pending sau N nến |
| `InpWatchingMaxBars` | 10 | Thoát WATCHING nếu không có trigger |
| `InpMinBarsBetweenCrosses` | 10 | Khoảng cách tối thiểu giữa các lần cắt RSI/WMA45 |
| `InpSlopeLookbackBars` | 3 | Số nến kiểm tra slope |
| `InpSwingLookbackBars` | 20 | Cửa sổ tìm swing cho entry/SL |
| `InpStopLossMode` | SL_HYBRID | `SL_SWING` / `SL_ATR` / `SL_HYBRID` |
| `InpSL_ATRMult` | 1.2 | Hệ số ATR cho SL kiểu ATR |
| `InpSL_SwingBufferPoints` | 20 | Đệm thêm (point) ngoài cực trị swing |
| `InpUseRSISidewayFilter` | true | Bật/tắt lọc sideway RSI |
| `InpSidewayRSILow / High` | 45 / 55 | Dải sideway theo RSI |
| `InpUseATRTrendBuffer` | false | Dùng buffer trend theo ATR |

## 5) Gợi ý kiểm thử và tối ưu

- Nên backtest từng symbol ít nhất 6–12 tháng trước khi chạy thật.
- Thị trường biến động mạnh: thử `InpUseATRTrendBuffer = true`.
- Muốn **ít tín hiệu hơn nhưng chọn lọc hơn**:
  - Tăng `InpMinBarsBetweenCrosses`
  - Tăng `InpSlopeLookbackBars`
  - Giữ `SL_HYBRID`
- Muốn **nhiều tín hiệu hơn**:
  - Giảm `InpSlopeLookbackBars` xuống 2
  - Tắt `InpUseRSISidewayFilter`
- Theo dõi tab **Experts** / **Journal** để xem log `[STATE]`, `[TREND]`, `[PENDING]`, `[TRADE]`.

## 6) Hiển thị trực quan (Visualization)

EA có thể tự vẽ để quan sát và đánh giá (bật/tắt bằng `InpVisualize` và các cờ con).

### 6.1 Dashboard (góc trên-trái)

Hiển thị:

- **Trend**: UP / DOWN / NONE (màu xanh / đỏ / xám)
- **State**: `STATE_NO_TRADE` / `STATE_WATCHING` / `STATE_PENDING_ORDER` / `STATE_IN_TRADE`
- **RSI**: giá trị RSI, EMA9, WMA45 tại nến tín hiệu (`InpSignalBarShift`)
- **EMA200**: giá trị EMA200 + giá đóng hiện tại
- **ATR**: giá trị ATR
- **Context**: tùy trạng thái — ví dụ số nến WATCHING, thời gian sống pending, đã partial hay chưa

### 6.2 Bảng thống kê (góc dưới-trái)

Quét lịch sử `InpStatsLookbackDays` ngày (mặc định 60), lọc theo `InpMagicNumber` + `_Symbol`:

- **Total**: số vị thế đã đóng (gộp theo `POSITION_ID`, tránh đếm trùng partial)
- **TP hit**: số deal đóng với lý do `DEAL_REASON_TP`
- **SL hit**: số deal đóng với lý do `DEAL_REASON_SL`
- **Other**: đóng tay / partial / đóng bởi expert
- **Net PL**: tổng P/L (profit + swap + hoa hồng)

### 6.3 Mức giá Entry / SL / TP (kiểu TradingView)

Khi `STATE_PENDING_ORDER` hoặc `STATE_IN_TRADE`, vẽ 3 đường ngang:

- **ENTRY** (chấm, màu `InpColorEntry`)
- **SL** (gạch, màu `InpColorSL`)
- **TP** (gạch, màu `InpColorTP`)

Tự xóa khi về `NO_TRADE`.

### 6.4 Tự gắn chỉ báo lên chart

Khi `InpAttachIndicators = true` (mặc định):

- **EMA200** vào cửa sổ chính.
- **RSI**, **EMA trên RSI**, **WMA trên RSI** vào **cửa sổ phụ** (subwindow).

Có thể tắt từng phần:

| Tham số | Mặc định | Tác dụng |
| ------- | -------- | -------- |
| `InpVisualize` | true | Bật/tắt toàn bộ lớp hiển thị |
| `InpAttachIndicators` | true | Tự thêm EMA200 + cụm RSI lên chart |
| `InpShowDashboard` | true | Panel góc trên-trái |
| `InpShowStatsPanel` | true | Panel góc dưới-trái |
| `InpShowTradeLevels` | true | Đường Entry/SL/TP |
| `InpStatsLookbackDays` | 60 | Số ngày quét thống kê |

Mọi đối tượng đồ họa dùng tiền tố `RSIForce_` và được xóa trong `OnDeinit`.

## 7) Luồng chạy chi tiết (từng bước)

### 7.1 Toàn cảnh kiến trúc

```
+-------------------------------------------------------------+
|                  RSIForceStateEA.mq5                        |
|  (điểm vào — chỉ có OnInit / OnTick / OnTradeTransaction    |
|   / OnDeinit, không chứa logic nghiệp vụ)                   |
+-------------------------------------------------------------+
            |
            | #include theo thứ tự:
            v
+-------- Tầng 1 (dữ liệu + kiểu) ---------------------------+
|  Config.mqh       — toàn bộ input                           |
|  State.mqh        — enum EAState, struct SignalSnapshot...   |
|  Indicators.mqh   — handle iRSI/iMA + buffer g_RSI[]...      |
+------------------------------------------------------------+
            |
            | Khai báo global trong .mq5:
            |   g_State, g_Pending, g_OpenTrade
            v
+-------- Tầng 2 (logic) ------------------------------------+
|  Trade.mqh        — CalcLotsForRisk, PlaceLimitOrderFromPlan,|
|                     ManagePartialAndBreakEven...             |
|  StateMachine.mqh — DetectTrend, IsPullback*, IsBuyTrigger*, |
|                     BuildSignalPlan, RunStateMachine...      |
+------------------------------------------------------------+
            |
            v
+-------- Tầng 3 (giao diện) --------------------------------+
|  Visualizer.mqh   — DrawDashboardPanel, DrawStatsPanel,      |
|                     DrawTradeLevels, AttachIndicatorsToChart |
+------------------------------------------------------------+
```

### 7.2 Vòng đời — từ lúc gắn EA

#### Bước 0. MT5 gọi `OnInit()` (file `RSIForceStateEA.mq5`)

```
RSIForceStateEA.mq5 :: OnInit()
  |
  +-- ValidateInputs()              (file .mq5 — kiểm tra cấu hình)
  |   nếu sai  -> INIT_PARAMETERS_INCORRECT (EA không khởi động)
  |
  +-- ZeroMemory(g_Pending), ZeroMemory(g_OpenTrade)
  |   đưa global về trạng thái sạch
  |
  +-- InitIndicators()              (Indicators.mqh)
  |   |
  |   +-- iRSI(...)        -> g_hRSI
  |   +-- iMA(g_hRSI, EMA) -> g_hEMA9   (EMA trên RSI)
  |   +-- iMA(g_hRSI, WMA) -> g_hWMA45  (WMA trên RSI)
  |   +-- iMA(close, EMA)  -> g_hEMA200 (EMA trên giá đóng)
  |   +-- iATR(...)        -> g_hATR
  |   +-- ArraySetAsSeries(...) cho mọi buffer
  |
  +-- RefreshIndicatorData()        (Indicators.mqh)
  |   |
  |   +-- CopyRates()    -> g_Bars[]
  |   +-- CopyBuffer() -> g_RSI[], g_EMA9[], g_WMA45[], g_EMA200[], g_ATR[]
  |   nếu chart chưa đủ lịch sử (< 200 nến) -> INIT_FAILED
  |
  +-- InitTradeOps()                (Trade.mqh)
  |   |
  |   +-- g_TradeOps.SetExpertMagicNumber(InpMagicNumber)
  |   +-- g_TradeOps.SetDeviationInPoints(10)
  |   +-- g_TradeOps.SetTypeFillingBySymbol(_Symbol)
  |
  +-- g_LastTrend = DetectTrend(InpSignalBarShift)
  |   khởi tạo trend ngay từ đầu để tick đầu không báo “đảo chiều” giả
  |
  +-- AttachIndicatorsToChart()     (Visualizer.mqh)
  |   |
  |   +-- IsIndicatorAlreadyAttached(...) — tránh trùng khi reload EA
  |   +-- ChartIndicatorAdd(0, 0, g_hEMA200)        -> cửa sổ chính
  |   +-- ChartIndicatorAdd(0, sub, g_hRSI)        -> subwindow
  |   +-- ChartIndicatorAdd(0, sub, g_hEMA9)
  |   +-- ChartIndicatorAdd(0, sub, g_hWMA45)
  |
  +-- DrawAllVisuals(g_LastTrend)   (Visualizer.mqh)
      vẽ dashboard + stats lần đầu
```

#### Bước 1. Mỗi tick — `OnTick()` (`RSIForceStateEA.mq5`)

```
RSIForceStateEA.mq5 :: OnTick()
  |
  +-- RefreshIndicatorData()        (Indicators.mqh)
  |   cập nhật g_Bars / g_RSI / g_EMA9 / g_WMA45 / g_EMA200 / g_ATR
  |   nếu copy lỗi (ví dụ thị trường vừa mở) -> return, chờ tick sau
  |
  +-- SyncStateWithBroker()         (StateMachine.mqh)
  |   |
  |   nếu state = PENDING_ORDER:
  |     +- HasOurOpenPosition() = true ? (Trade.mqh)
  |     |    -> chuyển IN_TRADE, copy kế hoạch từ g_Pending sang g_OpenTrade
  |     +- HasOurPendingOrder() = false (hủy/hết hạn/từ chối) ?
  |          -> reset g_HasTradedThisPullback, về NO_TRADE
  |
  |   nếu state = IN_TRADE:
  |     +- HasOurOpenPosition() = false (TP/SL/đóng tay) ?
  |          -> reset g_HasTradedThisPullback, về NO_TRADE
  |
  +-- if (state == IN_TRADE):
  |     ManagePartialAndBreakEven(g_OpenTrade)   (Trade.mqh)
  |     |
  |     +- PositionSelectByTicket(positionTicket)
  |     +- profitDist = giá hiện tại so với giá mở (BUY/SELL)
  |     +- initRisk = |openPrice - SL|  (lấy từ broker, không dùng plan)
  |     +- nếu profitDist >= InpPartialCloseAtR * initRisk:
  |          - PositionClosePartial(ticket, % volume) nếu chia lot được
  |          - PositionModify(ticket, openPrice, tp) — SL về BE
  |          - g_OpenTrade.partialClosedDone = true (chỉ một lần)
  |
  +-- newBar = IsNewBar()           (StateMachine.mqh)
  |   so sánh g_Bars[0].time với lastBarTime — true khi nến mới mở
  |
  +-- if (newBar): RunStateMachine()   <-- xem Bước 2
  |
  +-- if (newBar HOẶC đã qua 2 giây kể từ lần vẽ trước):
        DrawAllVisuals(DetectTrend(InpSignalBarShift))   (Visualizer.mqh)
        |
        +- DrawDashboardPanel(trend)
        +- DrawStatsPanel()
        +- DrawTradeLevels()
```

#### Bước 2. Có nến mới — `RunStateMachine()` (`StateMachine.mqh`)

```
StateMachine.mqh :: RunStateMachine()
  |
  +-- signalShift = InpSignalBarShift          (mặc định = 1, nến vừa đóng)
  +-- trendNow    = DetectTrend(signalShift)   (Up / Down / None)
  |
  +-- Phát hiện đảo chiều **có hướng** thật (UP <-> DOWN):
  |   |
  |   nếu trendNow != NONE:
  |     +- so với g_LastDirTrend (xu hướng có hướng trước đó)
  |     +- nếu g_LastDirTrend khác hướng và cả hai đều không NONE
  |          -> dirFlipped = true
  |     +- cập nhật g_LastDirTrend = trendNow
  |
  +-- if (dirFlipped):              <-- chỉ reset khi UP <-> DOWN
  |     +- ResetPullbackCycle()
  |     +- nếu PENDING_ORDER -> CancelPendingOrder, về NO_TRADE
  |     +- nếu WATCHING      -> về NO_TRADE
  |
  +-- g_LastTrend = trendNow
  |
  +-- switch (g_State):
        |
        case STATE_NO_TRADE:
        |   HandleStateNoTrade(...)
        |
        case STATE_WATCHING:
        |   HandleStateWatching(...)
        |     (timeout, BuildSignalPlan, PlaceLimitOrderFromPlan...)
        |
        case STATE_PENDING_ORDER:
        |   TickPendingOrderLifecycle(...)
        |     (đếm nến, hết hạn/invalid -> hủy, reset anti-spam)
        |
        case STATE_IN_TRADE:
            (không làm gì ở đây — partial/BE chạy trong OnTick)
```

#### Bước 3. Biến động lệnh — `OnTradeTransaction()`

```
RSIForceStateEA.mq5 :: OnTradeTransaction(...)
  |
  +-- SyncStateWithBroker()
      đồng bộ ngay khi broker báo sự kiện (không chỉ dựa vào tick)
```

#### Bước 4. Gỡ EA — `OnDeinit()`

```
RSIForceStateEA.mq5 :: OnDeinit(reason)
  |
  +-- RemoveAllVisuals()            (Visualizer.mqh)
  |   ObjectsDeleteAll(0, "RSIForce_")
  |
  +-- ReleaseIndicators()           (Indicators.mqh)
      IndicatorRelease cho mọi handle
```

### 7.3 Bảng phân công: file nào làm việc gì

| Trách nhiệm | File | Hàm chính |
| ----------- | ---- | --------- |
| Toàn bộ input | `Config.mqh` | (chỉ khai báo) |
| Enum / struct | `State.mqh` | `EAState`, `TrendDirection`, `SignalSnapshot`, `PendingContext`, `TradeContext` |
| Tạo & cập nhật chỉ báo | `Indicators.mqh` | `InitIndicators`, `RefreshIndicatorData`, `IsBufferSlopingDown/Up`, `HasCrossInLastNBars` |
| Lot, đặt/hủy/quản lý lệnh | `Trade.mqh` | `CalcLotsForRisk`, `PlaceLimitOrderFromPlan`, `CancelPendingOrder`, `ManagePartialAndBreakEven` |
| Trend, pullback, trigger | `StateMachine.mqh` | `DetectTrend`, `IsPullbackInUptrend/Downtrend`, `IsBuyTriggerSignal`, `IsSellTriggerSignal` |
| Điều phối state machine | `StateMachine.mqh` | `RunStateMachine`, `HandleStateNoTrade`, `HandleStateWatching`, `TickPendingOrderLifecycle` |
| Đồng bộ broker | `StateMachine.mqh` | `SyncStateWithBroker` (+ `HasOurOpenPosition` / `HasOurPendingOrder` trong `Trade.mqh`) |
| UI & mức giá | `Visualizer.mqh` | `DrawDashboardPanel`, `DrawStatsPanel`, `DrawTradeLevels`, `AttachIndicatorsToChart` |
| Vòng đời & validate | `RSIForceStateEA.mq5` | `OnInit`, `OnTick`, `OnTradeTransaction`, `OnDeinit`, `ValidateInputs` |

### 7.4 Global của EA và ai được sửa

| Global | Kiểu | Vai trò | Thường sửa tại |
| ------ | ---- | ------- | -------------- |
| `g_State` | `EAState` | Trạng thái SM | `TransitionTo` (StateMachine.mqh) |
| `g_Pending` | `PendingContext` | Lệnh chờ | `PlaceLimitOrderFromPlan`, `CancelPendingOrder` |
| `g_OpenTrade` | `TradeContext` | Vị thế mở | `SyncStateWithBroker`, `ManagePartialAndBreakEven` |
| `g_HasTradedThisPullback` | `bool` | Chống spam | Khi đặt lệnh; reset khi hủy/đóng/đảo chiều |
| `g_BarsInWatching` | `int` | Timeout WATCHING | `HandleStateWatching` và khi chuyển trạng thái |
| `g_LastTrend` | `TrendDirection` | Trend mới nhất | Cuối `RunStateMachine` |
| `g_LastDirTrend` | `TrendDirection` | Trend có hướng gần nhất | `RunStateMachine` khi `trendNow != NONE` |

### 7.5 Sự kiện broker → cách code phản ứng

| Sự kiện thực tế | Cách phát hiện | Phản ứng trong code |
| --------------- | -------------- | ------------------- |
| Limit khớp | `OnTradeTransaction` + `SyncStateWithBroker` | `PENDING` → `IN_TRADE`, copy plan |
| Pending hết hạn / bị hủy | `Sync` (không còn order) | `PENDING` → `NO_TRADE`, reset anti-spam |
| Pending bị từ chối | `PlaceLimit...` false hoặc `Sync` | Ở `NO_TRADE`, có log retcode |
| Chạm TP | `Sync` (không còn position) | `IN_TRADE` → `NO_TRADE`, reset anti-spam |
| Chạm SL | như trên | như trên |
| Đóng tay | như trên | như trên |
| Đạt mức partial R | `OnTick` → `ManagePartialAndBreakEven` | Partial (nếu được) + SL về BE |
| Đảo chiều UP ↔ DOWN | `RunStateMachine` — `dirFlipped` | Hủy pending ngược hướng, reset chu kỳ |
| Đi qua NONE rồi về cùng hướng | `RunStateMachine` | **Không** coi là flip; `g_LastDirTrend` giữ ngữ cảnh |
| Nến mới | `OnTick` → `IsNewBar` | Gọi `RunStateMachine` một lần |

## 8) Ghi chú kiến trúc

- State machine chạy theo **nến mới** (`IsNewBar()`), tránh bắn tín hiệu nhiều lần trong cùng một nến.
- Quản lý vị thế (partial + BE) chạy **mỗi tick** để phản ứng nhanh theo giá.
- `SyncStateWithBroker()` chạy mỗi tick và sau `OnTradeTransaction` để trạng thái nội bộ luôn khớp broker (đóng tay, từ chối lệnh, v.v.).
- Phân tầng `#include`:
  - **Tầng 1** chỉ khai báo dữ liệu và hàm thuần.
  - **Tầng 2** dùng các global khai báo giữa hai tầng.
  - **Tầng 3** chỉ đọc/hiển thị, không sửa logic nghiệp vụ cốt lõi.

---

*Tệp README dùng mã hóa UTF-8. Tiếng Việt có dấu an toàn với Git, GitHub và trình soạn thảo hiện đại; không ảnh hưởng tới biên dịch EA (MetaEditor không compile file `.md`).*
