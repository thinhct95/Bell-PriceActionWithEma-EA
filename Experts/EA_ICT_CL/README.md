# EA_ICT_CL – Kiến trúc & luồng chạy

File chính: `Experts/EA_ICT_CL.mq5`  
Thư mục module: `Experts/EA_ICT_CL/` (các `.mqh`)

## 1) Mục tiêu thiết kế

- `EA_ICT_CL.mq5` nên là **file “glue”**: `OnInit/OnDeinit/OnTick/...` + gọi hàm module.
- Mỗi `.mqh` chỉ gánh **một trách nhiệm**: config/state/signals/risk/trade/filters/…
- Migrate **từng phần nhỏ** để tránh trùng định nghĩa (enum/struct/global) và dễ debug.

## 2) Luồng chạy tổng thể (theo mô tả hiện tại trong header v4.3)

### Bối cảnh timeframe

- **BiasTF (D1)**: xác định bias (UP/DOWN/SIDEWAY/NONE)
- **MiddleTF (H1)**: xác định trend + quét FVG thuận xu hướng
- **TriggerTF (M5)**: xác nhận entry bằng **MSS** (market structure shift)

### State machine

EA đang dùng state machine:

- **`EA_IDLE`**
  - Mục tiêu: tìm/đặt “FVG tốt nhất” (MiddleTF) để theo dõi.
- **`EA_WAIT_TOUCH`**
  - Mục tiêu: chờ giá retrace và **touch vào vùng FVG** (H1).
- **`EA_WAIT_TRIGGER`**
  - Mục tiêu: khi đã touch FVG, chờ **M5 MSS** xác nhận đảo chiều theo trend.
  - v4.3: MSS chỉ detect khi state này.
- **`EA_IN_TRADE`**
  - Mục tiêu: quản lý pending/position (trailing/timeout/cleanup tuỳ EA).

### Decision flow “từ trên xuống”

1) **D1 Bias**
   - Xác định `HTFBias` (UP/DOWN/SIDEWAY/NONE).
2) **H1 Trend / Swing structure**
   - Xác định `MarketDir` (UP/DOWN/NONE) và các swing gần nhất: `h0/h1/l0/l1`.
3) **Quét H1 FVG**
   - Tạo/duy trì pool FVG (`g_FVGPool`) tối đa `MAX_FVG_POOL`.
   - FVG có lifecycle: `PENDING → TOUCHED → USED`.
4) **Touch FVG**
   - Khi bid/ask đi vào vùng gap → `touchTime` được set, chuyển state sang chờ trigger.
5) **M5 MSS (chỉ khi `EA_WAIT_TRIGGER`)**
   - Nếu H1 UP: bull MSS khi close phá **OLD** `tH0` → entry = `tH0`, SL = `tL0`.
   - Nếu H1 DOWN: bear MSS khi close phá **OLD** `tL0` → entry = `tL0`, SL = `tH0`.
6) **Lập kế hoạch lệnh (OrderPlan)**
   - `direction`: +1 BUY LIMIT / -1 SELL LIMIT
   - `entry`, `stopLoss`, `takeProfit`, `lot`
7) **Risk sizing**
   - Lot theo `%risk` và khoảng SL (points).
   - Chặn trade nếu chạm max daily loss (`InpMaxDailyLossPct`).
8) **Gửi pending limit**
   - Gắn `magic` và comment có `fvg_id` để trace.

## 3) Các folder/file module (vai trò + khi nào dùng)

Thư mục: `Experts/EA_ICT_CL/`

- **`Config.mqh`**
  - Nơi đưa `input`, `enum` và hằng số cấu hình.
  - Khi migrate: chuyển dần `input ...` và các enum khỏi `.mq5` sang đây (rồi include).

- **`State.mqh`**
  - Nơi đưa `struct` contexts (bias/trend/fvg/orderplan/daily risk) + state machine.
  - Khi migrate: chuyển dần các `struct`, `g_*` globals sang đây để module nào cũng dùng chung.

- **`Utils.mqh`**
  - Helper thuần: clamp/round/newbar/time formatting…
  - Ưu tiên migrate các hàm nhỏ, không phụ thuộc EA logic (vd `MyBarShift` cũng có thể đặt vào đây hoặc `Market/Indicators`).

- **`Logging.mqh`**
  - Chuẩn hoá log bật/tắt theo `InpDebugLog`.
  - Có thể mở rộng: prefix theo symbol/tf/state, ghi file, debug panel.

- **`Market.mqh`**
  - Helper về symbol specs (digits/point/spread), trade allowed, quote access…

- **`Sessions.mqh`**
  - Helper session/time filter (London/NY theo UTC).
  - Khi migrate: đưa logic “được trade trong giờ nào?” sang đây.

- **`Filters.mqh`**
  - Các bộ lọc: spread, news (nếu có), day-of-week, max trades/day, cooldown…

- **`Indicators.mqh`**
  - Wrapper CopyBuffer/CopyTime, quản lý handles nếu bạn dùng iMA/iATR/…

- **`Signals_BOS_FVG_OB.mqh`**
  - Nơi tập trung **logic tín hiệu**: BOS/MSS/FVG/OB… và build `OrderPlan`.
  - Mục tiêu: module này “pure” nhất có thể (input/state snapshot → plan).

- **`Risk.mqh`**
  - Tính lot, normalize volume, kiểm soát daily drawdown.

- **`Orders.mqh`**
  - Chuẩn hoá normalize price, build comment, mapping direction→order type…

- **`Trade.mqh`**
  - Các hàm “side-effect”: `OrderSend`, modify, cancel, close.

- **`Trailing.mqh`**
  - Trailing/BE/partial close (nếu có).

## 4) Gợi ý thứ tự migrate (an toàn, ít rủi ro nhất)

Để tránh trùng định nghĩa và lỗi include:

1) **Move helpers**: `MyBarShift`, swing helper functions → `Utils.mqh` (hoặc tách `Swing.mqh` nếu bạn muốn).
2) **Move trade wrappers**: các đoạn `MqlTradeRequest/Result` → `Trade.mqh` + helper normalize → `Orders.mqh`.
3) **Move risk**: tính lot / daily loss → `Risk.mqh`.
4) **Move filters/session** → `Sessions.mqh`, `Filters.mqh`.
5) **Cuối cùng mới move types**: enums/struct/global sang `Config.mqh` + `State.mqh`.

> Lưu ý: Chỉ include module nào khi bạn đã chuyển phần tương ứng khỏi `.mq5` (để tránh “redefinition”).

## 5) Quy ước include trong `EA_ICT_CL.mq5` (gợi ý)

Khi bắt đầu migrate, thường include theo thứ tự:

1. `Config.mqh`
2. `State.mqh`
3. `Utils.mqh`
4. `Logging.mqh`
5. `Market.mqh`
6. `Indicators.mqh`
7. `Sessions.mqh` / `Filters.mqh`
8. `Risk.mqh`
9. `Orders.mqh`
10. `Trade.mqh`
11. `Signals_BOS_FVG_OB.mqh`
12. `Trailing.mqh`

