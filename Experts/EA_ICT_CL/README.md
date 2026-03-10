# EA_ICT_CL – Kiến trúc & cấu trúc file

**EA chính:** `Experts/EA_ICT_CL.mq5`  
**Thư mục module:** `Experts/EA_ICT_CL/` (các file `.mqh`)

---

## 1. Cấu trúc thư mục và chức năng từng file

### File chính (entry point)

| File | Vai trò |
|------|--------|
| **`EA_ICT_CL.mq5`** | File “glue”: khai báo globals, include 3 tầng module, và chỉ chứa `OnInit()`, `OnTick()`, `OnDeinit()`. Không chứa logic nghiệp vụ. |

### Layer 1 – Cấu hình & kiểu dữ liệu (include đầu tiên)

| File | Chức năng |
|------|-----------|
| **`Config.mqh`** | Toàn bộ **input** của EA: timeframe (Bias/Middle/Trigger), risk %, session giờ (London/NY), swing/FVG/MSS params, magic, slippage, debug flags. |
| **`State.mqh`** | **Enums** và **struct**: `EAState`, `HTFBias`, `MarketDir`, `BlockReason`, `FVGStatus`; struct `BiasContext`, `TFTrendContext`, `FVGRecord`, `OrderPlan`, `DailyRiskContext`. Không chứa biến global. |

### Layer 2 – Tiện ích (sau Config + State)

| File | Chức năng |
|------|-----------|
| **`Utils.mqh`** | Hàm helper thuần: `ClampDouble`, `ClampInt`, `RoundToStep`, `IsNewBar`. |
| **`Logging.mqh`** | Wrapper log bật/tắt: `LogPrint`, `LogPrintF` (gọi khi `InpDebugLog` bật). |
| **`Market.mqh`** | Helper market: `GetBid`, `GetAsk`, `GetPoint`, `GetDigits`, `GetSpreadPoints`, `IsTradeAllowedNow`. |
| **`Indicators.mqh`** | Wrapper an toàn: `CopyBufferSafe`, `CopyTimeSafe` cho dữ liệu series. |
| **`Sessions.mqh`** | Lọc theo giờ: `IsHourInRange`, `GetUTCHour` (dùng cho session London/NY). |
| **`Filters.mqh`** | Bộ lọc chung: `Filter_MaxSpreadPoints` (có thể mở rộng news, max trades/day). |
| **`Risk.mqh`** | Risk & volume: `NormalizeVolume`, `LotsFromRiskMoneyAndSLPoints`. |
| **`Orders.mqh`** | Chuẩn hoá order: `NormalizePrice`, `BuildOrderComment`. |
| **`Swing.mqh`** | **Swing structure**: `MyBarShift`, `IsSwingHighAt`, `IsSwingLowAt`, `ScanSwingStructure`, `ResolveTrendFromSwings`. |
| **`Trailing.mqh`** | Placeholder cho logic trailing / breakeven / partial close (chưa implement). |

### Layer 3 – Logic nghiệp vụ (sau khi đã khai báo globals trong `.mq5`)

| File | Chức năng |
|------|-----------|
| **`Contexts.mqh`** | Cập nhật context: `ResolveBias`, `UpdateBiasContext`, `UpdateTFTrendContext`, `UpdateDailyRiskContext`, `UpdateAllContexts`. Dùng globals `g_Bias`, `g_MiddleTrend`, `g_TriggerTrend`, `g_DailyRisk`. |
| **`Guards.mqh`** | Điều kiện trước khi trade: `IsSessionAllowed`, `IsDailyLossOK`, `IsBiasValid`, `IsMiddleTrendAligned`, `EvaluateGuards`. Set `g_BlockReason` khi block. |
| **`Signals_BOS_FVG_OB.mqh`** | **FVG**: `IsCandleStrong`, `IsFVGInPool`, `ScanAndRegisterFVGs`, `UpdateFVGStatuses`, `GetBestActiveFVGIdx`. Quản lý pool FVG và trạng thái PENDING/TOUCHED/USED. |
| **`Trade.mqh`** | **Order plan & execution**: `CalcLotFromRisk`, `BuildOrderPlan`, `ExecuteLimitOrder`. Gửi lệnh pending limit, dùng `g_OrderPlan`. |
| **`StateMachine.mqh`** | **State machine**: `TransitionTo`, `ResetToIdle`, `OnStateIdle`, `OnStateWaitTouch`, `OnStateWaitTrigger`, `OnStateInTrade`, `RunStateMachine`. Điều phối theo `g_State`. |
| **`Drawing.mqh`** | **Vẽ trên chart**: `DrawOneSwingPoint`, `DrawMiddleSwingPoints`, `DrawTriggerSwingPoints`, `DrawMSSMarker`, `DrawMSSMarkers`, `DrawOrderVisualization`, `DrawOneFVGRecord`, `DrawFVGPool`, `DrawContextDebug`, `DrawVisuals`. Dùng prefix `PREFIX_SWING_MIDDLE`, `PREFIX_ORDER_VISUAL`, v.v. |

---

## 2. Thứ tự include trong `EA_ICT_CL.mq5`

```
Layer 1:  Config.mqh  →  State.mqh
Layer 2:  Utils, Logging, Market, Indicators, Sessions, Filters, Risk, Orders, Swing, Trailing
Globals:  g_State, g_Bias, g_MiddleTrend, g_TriggerTrend, g_DailyRisk, g_FVGPool, g_OrderPlan, PREFIX_*
Layer 3:  Contexts.mqh  →  Guards.mqh  →  Signals_BOS_FVG_OB.mqh  →  Trade.mqh  →  StateMachine.mqh  →  Drawing.mqh
```

Layer 3 phải include **sau** khi globals và prefix đã được khai báo trong `.mq5`.

---

## 3. Luồng chạy tổng thể (v4.3)

### Timeframe

- **BiasTF (D1):** xác định bias (UP/DOWN/SIDEWAY/NONE).
- **MiddleTF (H1):** trend + quét FVG thuận xu hướng.
- **TriggerTF (M5):** xác nhận entry bằng MSS (market structure shift).

### State machine

| State | Mục đích |
|-------|----------|
| **EA_IDLE** | Chọn FVG “tốt nhất” (ưu tiên TOUCHED, rồi PENDING mới nhất). |
| **EA_WAIT_TOUCH** | Chờ giá retrace vào vùng FVG (H1). |
| **EA_WAIT_TRIGGER** | Đã touch FVG → chờ M5 MSS (chỉ detect MSS trong state này). |
| **EA_IN_TRADE** | Theo dõi pending/position; reset khi fill, cancel hoặc đóng lệnh. |

### Luồng quyết định (mỗi tick)

1. **UpdateAllContexts()** – Cập nhật D1 bias, H1/M5 swing (và MSS nếu đang WAIT_TRIGGER).
2. **EvaluateGuards()** – Kiểm tra session, daily loss, bias, alignment H1/D1.
3. Nếu pass → **RunStateMachine()**: `UpdateFVGStatuses()` + `ScanAndRegisterFVGs()` + xử lý theo state (Idle → chọn FVG; WaitTouch → chờ touch/switch FVG; WaitTrigger → khi FVG triggered thì BuildOrderPlan + ExecuteLimitOrder; InTrade → theo dõi order/position).
4. Nếu **InpDebugDraw** bật → **DrawVisuals()** (swing, MSS, FVG pool, order, debug panel).

### Entry / SL / TP

- **Entry:** giá swing bị phá (tH0 cho buy, tL0 cho sell).
- **SL:** swing đối diện (tL0 cho buy, tH0 cho sell) + buffer 2 point.
- **TP:** Entry ± `InpRiskReward` × |Entry − SL|.

---

## 4. Đặt tên object trên chart (prefix)

Các hằng trong `EA_ICT_CL.mq5` dùng cho Drawing:

- `PREFIX_SWING_MIDDLE` – H1 swing (MiddleH0/L0…).
- `PREFIX_SWING_TRIGGER` – M5 swing (TriggerH0/L0…).
- `PREFIX_MSS_MARKER` – Điểm đánh dấu MSS.
- `PREFIX_FVG_POOL` – Các hình chữ nhật FVG.
- `PREFIX_ORDER_VISUAL` – Vùng/label Entry/SL/TP.
- `PREFIX_DEBUG_PANEL` – Bảng thông tin góc trái (Bias, H1/M5, Risk, State, Pool, Order).

---

## 5. Mở rộng / chỉnh sửa gợi ý

- **Thêm input:** chỉnh trong `Config.mqh`.
- **Thêm enum/struct:** chỉnh trong `State.mqh`.
- **Logic FVG / chọn FVG:** chỉnh trong `Signals_BOS_FVG_OB.mqh`.
- **Tính lot / gửi lệnh:** chỉnh trong `Trade.mqh`.
- **Chuyển state / xử lý từng state:** chỉnh trong `StateMachine.mqh`.
- **Trailing / breakeven:** bổ sung trong `Trailing.mqh` và gọi từ state IN_TRADE (trong `StateMachine.mqh` hoặc từ `OnTick`).
- **Vẽ thêm object:** chỉnh trong `Drawing.mqh`, dùng đúng prefix để `OnDeinit` có thể dọn theo prefix nếu cần.
