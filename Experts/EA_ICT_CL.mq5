//+------------------------------------------------------------------+
//| ICT EA – FVG Edition                                             |
//| Architecture: 3 TF | 4 State Machine                            |
//|                                                                  |
//| Flow:                                                            |
//|   D1 Bias + H1 Trend đồng thuận                                  |
//|     → Tìm FVG trên H1  (EA_IDLE)                                |
//|     → Chờ price chạm   (EA_WAIT_TOUCH)                          |
//|     → Chờ trigger M5   (EA_WAIT_TRIGGER)                        |
//|     → Vào lệnh         (EA_IN_TRADE)                            |
//+------------------------------------------------------------------+
#property strict

//====================================================
// INPUTS
//====================================================

input ENUM_TIMEFRAMES InpBiasTF         = PERIOD_D1;  // Timeframe xác định bias HTF (thường D1)
input ENUM_TIMEFRAMES InpMiddleTF       = PERIOD_H1;  // Timeframe tìm FVG + xác định trend MTF
input ENUM_TIMEFRAMES InpTriggerTF      = PERIOD_M5;  // Timeframe xác nhận entry (nến trigger)

input double InpRiskPercent             = 1.0;         // % balance chấp nhận rủi ro mỗi lệnh
input double InpRiskReward              = 2.0;         // Tỉ lệ TP/SL (TP = SL × RR)
input double InpMaxDailyLossPct         = 3.0;         // % loss tối đa trong ngày → dừng trade

input int    InpLondonStartHour         = 8;           // Giờ mở phiên London (UTC)
input int    InpLondonEndHour           = 17;          // Giờ đóng phiên London (UTC)
input int    InpNYStartHour             = 13;          // Giờ mở phiên New York (UTC)
input int    InpNYEndHour               = 22;          // Giờ đóng phiên New York (UTC)
input int    InpSessionAvoidLastMin     = 60;          // Tránh N phút cuối mỗi phiên (không vào lệnh)

input int    InpSwingRange              = 2;           // Số nến xác nhận mỗi bên của swing point
                                                       //   VD: 2 → bar[i] phải cao hơn bar[i±1] và bar[i±2]
input int    InpSwingLookback           = 50;          // Số bar MiddleTF quét ngược để tìm swing H/L

input int    InpFVGMaxAliveMin          = 4320;        // FVG sống tối đa (phút) → 4320 = 72 giờ
input int    InpFVGScanBars             = 50;          // Số bar MiddleTF quét ngược để tìm FVG candidate
input double InpFVGMinBodyPct           = 60.0;        // Nến giữa của pattern FVG: body/range >= X%
input int    InpTriggerMaxBars          = 30;          // Timeout trigger: sau N bar TriggerTF → bỏ qua

input bool   InpDebugLog                = true;        // In log chi tiết vào Journal
input bool   InpDebugDraw               = true;        // Vẽ FVG, swing points, debug panel lên chart

//====================================================
// ENUMS
//====================================================

enum EAState
{
  EA_IDLE,          // Đang chờ: bias hợp lệ + MiddleTF trend đồng thuận + tìm FVG
  EA_WAIT_TOUCH,    // Đã có FVG candidate, đang chờ giá retracement chạm vùng FVG
  EA_WAIT_TRIGGER,  // Giá đã chạm FVG, đang chờ TriggerTF xác nhận entry
  EA_IN_TRADE       // Đang có lệnh mở, theo dõi cho đến khi đóng
};

enum HTFBias
{
  BIAS_NONE    =  0,  // Chưa xác định được bias (chưa đủ bar)
  BIAS_UP      =  1,  // Bias tăng – ưu tiên tìm lệnh Buy
  BIAS_DOWN    = -1,  // Bias giảm – ưu tiên tìm lệnh Sell
  BIAS_SIDEWAY =  2   // Sideway – không trade (không có bias rõ ràng)
};

enum MarketDir
{
  DIR_NONE  =  0,  // Chưa xác định hướng
  DIR_UP    =  1,  // Hướng tăng (uptrend hoặc bullish FVG)
  DIR_DOWN  = -1   // Hướng giảm (downtrend hoặc bearish FVG)
};

enum BlockReason
{
  BLOCK_NONE,           // Không bị block, EA hoạt động bình thường
  BLOCK_SESSION,        // Ngoài giờ giao dịch được phép
  BLOCK_DAILY_LOSS,     // Đã chạm mức loss tối đa trong ngày
  BLOCK_BIAS_MISMATCH,  // Bias D1 và MiddleTF trend ngược chiều nhau
  BLOCK_NO_BIAS         // Bias là SIDEWAY hoặc NONE → không có hướng rõ
};

//====================================================
// STRUCTS
//====================================================

struct BiasContext
{
  HTFBias  bias;         // Bias hiện tại của BiasTF
  double   rangeHigh;    // Đỉnh range khi bias = SIDEWAY (dùng để hiển thị)
  double   rangeLow;     // Đáy range khi bias = SIDEWAY
  datetime lastBarTime;  // Thời điểm bar BiasTF cuối cùng được xử lý (guard chống update lặp)
};

struct MiddleTFTrend
{
  MarketDir trend;       // Trend hiện tại của MiddleTF: DIR_UP / DIR_DOWN / DIR_NONE

  // Swing structure – 2 điểm gần nhất, [0] = mới hơn
  double    h0;          // Swing High gần nhất (Higher High hoặc Lower High)
  double    h1;          // Swing High trước đó
  double    l0;          // Swing Low gần nhất  (Higher Low hoặc Lower Low)
  double    l1;          // Swing Low trước đó

  int       idxH0;       // Bar index của h0 trên MiddleTF (dùng để vẽ)
  int       idxH1;       // Bar index của h1
  int       idxL0;       // Bar index của l0
  int       idxL1;       // Bar index của l1

  double    keyLevel;    // Level quan trọng nhất cần theo dõi:
                         //   Uptrend  → keyLevel = l0  (close < l0 = MSS, trend đổi)
                         //   Downtrend→ keyLevel = h0  (close > h0 = MSS, trend đổi)

  datetime  lastBarTime; // Guard: chỉ recalculate khi có bar MiddleTF mới
};

struct FVGContext
{
  bool      active;      // true = đang tracking một FVG (state >= WAIT_TOUCH)
  bool      touched;     // true = giá đã chạm vào vùng FVG ít nhất 1 lần

  MarketDir direction;   // Hướng FVG: DIR_UP (bullish) hoặc DIR_DOWN (bearish)
  double    high;        // Cạnh trên của vùng FVG
  double    low;         // Cạnh dưới của vùng FVG
  double    mid;         // Midpoint = (high+low)/2 – dùng làm entry tham chiếu

  datetime  createdTime; // Thời điểm nến phải của pattern đóng = FVG được confirm
  datetime  touchTime;   // Thời điểm giá chạm FVG lần đầu

  int       barsAlive;   // Số bar TriggerTF đã trôi qua kể từ khi touched
  int       touchBarIdx; // Bar index TriggerTF tại thời điểm touched (dùng đếm barsAlive)
};

struct TriggerContext
{
  bool      valid;       // true = đã xác định được swing structure trên TriggerTF
  MarketDir direction;   // Hướng trigger đang chờ
  double    swingHigh;   // Swing high gần nhất trên TriggerTF (sau khi touched FVG)
  double    swingLow;    // Swing low gần nhất trên TriggerTF
  int       idxHigh;     // Bar index của swingHigh
  int       idxLow;      // Bar index của swingLow
  double    breakLevel;  // Level cần bị phá vỡ để xác nhận trigger entry
};

struct OrderPlan
{
  bool   valid;          // true = plan đã được tính, có thể gửi lệnh
  int    direction;      // 1 = Buy, -1 = Sell
  double entry;          // Giá vào lệnh
  double stopLoss;       // Giá stop loss
  double takeProfit;     // Giá take profit
  double lot;            // Khối lượng lô
};

struct DailyRiskContext
{
  double   startBalance;    // Balance lúc đầu ngày (chụp khi bar D1 mới mở)
  double   currentBalance;  // Balance hiện tại (cache mỗi tick, tránh gọi API 2 lần)
  datetime dayStartTime;    // Thời điểm bar D1 hiện tại mở (ID của ngày)
  bool     limitHit;        // true = đã chạm daily loss limit → không trade thêm hôm nay
};

//====================================================
// GLOBAL STATE
//====================================================

EAState          g_State        = EA_IDLE;   // Trạng thái hiện tại của state machine
BlockReason      g_BlockReason  = BLOCK_NONE; // Lý do EA bị block (hiển thị trên debug panel)

BiasContext      g_Bias;         // Context bias HTF (D1)
MiddleTFTrend    g_MiddleTrend;  // Context trend + swing structure MTF (H1)
FVGContext       g_FVG;          // Context FVG đang được tracking
TriggerContext   g_Trigger;      // Context trigger entry (M5)
DailyRiskContext g_DailyRisk;    // Context quản lý risk theo ngày

int              g_TradeBarIndex = -1; // Bar index TriggerTF lúc gửi lệnh (guard chống double-entry)

// Tên cố định cho FVG drawing objects (chỉ 1 FVG active tại một thời điểm)
const string FVG_RECT_NAME  = "FVG_RECT";   // Rectangle vùng FVG
const string FVG_MID_NAME   = "FVG_MID";    // Đường midpoint (đứt nét)
const string FVG_LABEL_NAME = "FVG_LABEL";  // Text label "FVG ▲/▼"

// Prefix cho swing drawing objects – dùng ObjectsDeleteAll(0, SW_PREFIX) để xóa toàn bộ
const string SW_PREFIX = "SW_";

//====================================================
// SWING DETECTION HELPERS
//====================================================

// Trả về true nếu bar[i] là Swing High hợp lệ:
//   bar[i].high > bar[i-k].high  với mọi k trong [1..InpSwingRange]  (nến bên phải / newer)
//   bar[i].high > bar[i+k].high  với mọi k trong [1..InpSwingRange]  (nến bên trái / older)
// Ý nghĩa: đỉnh cục bộ được xác nhận bởi InpSwingRange nến ở mỗi phía
bool IsSwingHighAt(ENUM_TIMEFRAMES tf, int i)
{
  double price = iHigh(_Symbol, tf, i);
  for (int k = 1; k <= InpSwingRange; k++)
  {
    if (iHigh(_Symbol, tf, i - k) >= price) return false; // Nến newer (index thấp hơn) cao hơn → không phải đỉnh
    if (iHigh(_Symbol, tf, i + k) >= price) return false; // Nến older (index cao hơn) cao hơn → không phải đỉnh
  }
  return true;
}

// Tương tự IsSwingHighAt nhưng cho đáy cục bộ
bool IsSwingLowAt(ENUM_TIMEFRAMES tf, int i)
{
  double price = iLow(_Symbol, tf, i);
  for (int k = 1; k <= InpSwingRange; k++)
  {
    if (iLow(_Symbol, tf, i - k) <= price) return false; // Nến newer thấp hơn → không phải đáy
    if (iLow(_Symbol, tf, i + k) <= price) return false; // Nến older thấp hơn → không phải đáy
  }
  return true;
}

//====================================================
// CONTEXT UPDATERS
//====================================================

// Phân loại bias dựa trên 2 bar BiasTF đã đóng gần nhất:
//   b1 = bar[1] (vừa đóng), b2 = bar[2] (trước đó)
// Rule 1: b1.close > b2.high          → BIAS_UP    (breakout rõ ràng lên trên)
// Rule 2: b1.close < b2.low           → BIAS_DOWN  (breakout rõ ràng xuống dưới)
// Rule 3: b1.high > b2.high nhưng close < b2.high → BIAS_DOWN (sweep đỉnh rồi reject)
// Rule 4: b1.low  < b2.low  nhưng close > b2.low  → BIAS_UP   (sweep đáy rồi recover)
// Rule 5: không khớp rule nào         → BIAS_SIDEWAY
HTFBias ResolveBias(double b1High, double b1Low, double b1Close,
                    double b2High, double b2Low)
{
  if (b1Close > b2High)                    return BIAS_UP;    // Đóng cửa vượt đỉnh bar trước
  if (b1Close < b2Low)                     return BIAS_DOWN;  // Đóng cửa xuyên đáy bar trước
  if (b1High > b2High && b1Close < b2High) return BIAS_DOWN;  // Wick phá đỉnh nhưng close quay về → bearish
  if (b1Low  < b2Low  && b1Close > b2Low)  return BIAS_UP;    // Wick phá đáy nhưng close quay lại → bullish
  return BIAS_SIDEWAY;                                         // Không có tín hiệu rõ
}

void UpdateBiasContext()
{
  datetime currentBarTime = iTime(_Symbol, InpBiasTF, 0);
  if (currentBarTime == g_Bias.lastBarTime) return; // Guard: chỉ tính lại khi có bar BiasTF mới

  g_Bias.lastBarTime = currentBarTime;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; } // Chưa đủ bar lịch sử

  double b1High  = iHigh (_Symbol, InpBiasTF, 1); // Bar đã đóng gần nhất
  double b1Low   = iLow  (_Symbol, InpBiasTF, 1);
  double b1Close = iClose(_Symbol, InpBiasTF, 1);
  double b2High  = iHigh (_Symbol, InpBiasTF, 2); // Bar trước đó
  double b2Low   = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prevBias = g_Bias.bias;
  g_Bias.bias      = ResolveBias(b1High, b1Low, b1Close, b2High, b2Low);

  // Lưu range của b2 để hiển thị khi sideway (giúp trader thấy vùng congestion)
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2High : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2Low  : 0;

  if (InpDebugLog && g_Bias.bias != prevBias) // Log khi bias thay đổi (không log mỗi bar)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prevBias), EnumToString(g_Bias.bias),
      b1High, b1Low, b1Close, b2High, b2Low);
}

//====================================================
// UPDATE MIDDLETF TREND
//
// Mục tiêu: xác định xu hướng cấu trúc (market structure) trên MiddleTF
//
// Quét ngược từ bar[SwingRange+1] trở về, thu thập:
//   h0, h1 = 2 swing high gần nhất  (h0 mới hơn h1)
//   l0, l1 = 2 swing low  gần nhất  (l0 mới hơn l1)
//
// Điều kiện UPTREND (Higher High + Higher Low, key level chưa bị phá):
//   h0 > h1  (đỉnh sau cao hơn đỉnh trước = Higher High)
//   l0 > l1  (đáy sau cao hơn đáy trước  = Higher Low)
//   bar[1].close > l0  (giá chưa close dưới l0 → cấu trúc uptrend còn nguyên)
//   keyLevel = l0  → nếu close < l0 thì MSS (Market Structure Shift) xảy ra
//
// Điều kiện DOWNTREND (Lower High + Lower Low):
//   h0 < h1  (Lower High)
//   l0 < l1  (Lower Low)
//   bar[1].close < h0  (giá chưa close trên h0 → cấu trúc downtrend còn nguyên)
//   keyLevel = h0  → nếu close > h0 thì MSS xảy ra
//====================================================

void UpdateMiddleTfTrendContext()
{
  datetime currentBarTime = iTime(_Symbol, InpMiddleTF, 0);
  if (currentBarTime == g_MiddleTrend.lastBarTime) return; // Guard: 1 lần/bar MiddleTF

  g_MiddleTrend.lastBarTime = currentBarTime;

  // Giới hạn vùng quét: không vượt quá số bar thực tế có sẵn
  int maxBar = MathMin(InpSwingLookback, Bars(_Symbol, InpMiddleTF) - InpSwingRange - 2);

  double highs[2]; int hiIdx[2]; int hc = 0; // Mảng lưu 2 swing high, hc = đếm số đã tìm được
  double lows[2];  int loIdx[2]; int lc = 0;

  // Bắt đầu từ SwingRange+1 để đảm bảo có đủ InpSwingRange nến bên phải (newer) xác nhận swing
  for (int i = InpSwingRange + 1; i <= maxBar; i++)
  {
    if (hc < 2 && IsSwingHighAt(InpMiddleTF, i))
    {
      highs[hc] = iHigh(_Symbol, InpMiddleTF, i); // Lưu giá high của swing
      hiIdx[hc] = i;                               // Lưu bar index để vẽ sau
      hc++;
    }
    if (lc < 2 && IsSwingLowAt(InpMiddleTF, i))
    {
      lows[lc] = iLow(_Symbol, InpMiddleTF, i);
      loIdx[lc] = i;
      lc++;
    }
    if (hc == 2 && lc == 2) break; // Đã đủ 2 high + 2 low → dừng sớm, tiết kiệm CPU
  }

  if (hc < 2 || lc < 2) // Không đủ swing points trong vùng lookback
  {
    g_MiddleTrend.trend = DIR_NONE;
    return;
  }

  // highs[0]/lows[0] = gần nhất (newer), highs[1]/lows[1] = xa hơn (older)
  g_MiddleTrend.h0 = highs[0]; g_MiddleTrend.idxH0 = hiIdx[0];
  g_MiddleTrend.h1 = highs[1]; g_MiddleTrend.idxH1 = hiIdx[1];
  g_MiddleTrend.l0 = lows[0];  g_MiddleTrend.idxL0 = loIdx[0];
  g_MiddleTrend.l1 = lows[1];  g_MiddleTrend.idxL1 = loIdx[1];

  double    bar1Close = iClose(_Symbol, InpMiddleTF, 1); // Bar đã đóng → dùng close để check MSS
  MarketDir prevTrend = g_MiddleTrend.trend;             // Lưu trend cũ để detect thay đổi khi log

  if (g_MiddleTrend.h0 > g_MiddleTrend.h1 && // Higher High: đỉnh mới cao hơn đỉnh cũ
      g_MiddleTrend.l0 > g_MiddleTrend.l1 && // Higher Low: đáy mới cao hơn đáy cũ
      bar1Close > g_MiddleTrend.l0)           // Close vẫn trên l0 → cấu trúc HH-HL chưa bị phá
  {
    g_MiddleTrend.trend    = DIR_UP;
    g_MiddleTrend.keyLevel = g_MiddleTrend.l0; // l0 là key level: phá = MSS → trend có thể đổi
  }
  else if (g_MiddleTrend.h0 < g_MiddleTrend.h1 && // Lower High: đỉnh mới thấp hơn đỉnh cũ
           g_MiddleTrend.l0 < g_MiddleTrend.l1 && // Lower Low: đáy mới thấp hơn đáy cũ
           bar1Close < g_MiddleTrend.h0)            // Close vẫn dưới h0 → cấu trúc LH-LL chưa bị phá
  {
    g_MiddleTrend.trend    = DIR_DOWN;
    g_MiddleTrend.keyLevel = g_MiddleTrend.h0; // h0 là key level: phá = MSS → trend có thể đổi
  }
  else // Không rõ HH-HL hay LH-LL, hoặc key level đã bị close phá → cấu trúc không rõ ràng
  {
    g_MiddleTrend.trend    = DIR_NONE;
    g_MiddleTrend.keyLevel = 0;
  }

  if (InpDebugLog && g_MiddleTrend.trend != prevTrend)
    PrintFormat("[MIDDLE TREND] %s → %s | H0=%.5f H1=%.5f L0=%.5f L1=%.5f | KeyLvl=%.5f",
      EnumToString(prevTrend), EnumToString(g_MiddleTrend.trend),
      g_MiddleTrend.h0, g_MiddleTrend.h1,
      g_MiddleTrend.l0, g_MiddleTrend.l1,
      g_MiddleTrend.keyLevel);
}

void UpdateDailyRiskContext()
{
  datetime todayBarTime = iTime(_Symbol, PERIOD_D1, 0); // "ID" của ngày: thay đổi khi bar D1 mới mở

  if (todayBarTime != g_DailyRisk.dayStartTime) // Bar D1 mới = ngày mới → reset daily risk
  {
    g_DailyRisk.dayStartTime = todayBarTime;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Chụp balance đầu ngày
                                                                    // Dùng BALANCE (không dùng EQUITY)
                                                                    // → không bị ảnh hưởng bởi floating P&L
    g_DailyRisk.limitHit     = false; // Reset flag → cho phép trade ngày mới
    if (InpDebugLog)
      PrintFormat("[DAILY RISK] New day | startBalance=%.2f", g_DailyRisk.startBalance);
  }

  if (g_DailyRisk.limitHit) return; // Early exit: đã hit limit hôm nay → không cần tính lại mỗi tick

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Cache vào struct
                                                                    // → DrawContextDebug dùng lại,
                                                                    //    tránh gọi API 2 lần trong cùng tick

  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                    / g_DailyRisk.startBalance * 100.0; // % đã mất so với đầu ngày (giá trị dương = loss)

  if (lostPct >= InpMaxDailyLossPct) // Chạm ngưỡng → lock trading cả ngày
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | limit=%.2f%% | balance=%.2f",
      lostPct, InpMaxDailyLossPct, g_DailyRisk.currentBalance);
  }
}

void UpdateAllContexts()
{
  UpdateDailyRiskContext();     // Gọi mỗi tick (nhanh nhờ early-exit khi limitHit)
  UpdateBiasContext();          // Gọi mỗi tick, chạy thực sự 1 lần/bar BiasTF (guard)
  UpdateMiddleTfTrendContext(); // Gọi mỗi tick, chạy thực sự 1 lần/bar MiddleTF (guard)
}

//====================================================
// GUARDS
// Mỗi guard kiểm tra 1 điều kiện độc lập.
// EvaluateGuards() gọi tuần tự → điều kiện nào fail trước thì dừng.
// Thứ tự: Session → DailyRisk → Bias → MiddleTrend
//====================================================

bool IsSessionAllowed() { return true; /* TODO: kiểm tra London/NY session theo giờ UTC */ }
bool IsDailyLossOK()    { return !g_DailyRisk.limitHit; }  // false khi đã chạm daily loss limit
bool IsBiasValid()      { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; } // Chỉ trade khi có bias rõ (không trade sideway)

// Kiểm tra Bias D1 và MiddleTF trend có cùng hướng không
// Nguyên lý: chỉ trade theo trend đa khung thời gian đồng thuận
//   Bias UP + Trend UP   → cho phép tìm Buy setup
//   Bias DOWN + Trend DOWN → cho phép tìm Sell setup
//   Ngược chiều hoặc DIR_NONE → block (BLOCK_BIAS_MISMATCH)
bool IsMiddleTrendAligned()
{
  if (g_MiddleTrend.trend == DIR_NONE)                              return false; // Trend chưa xác định
  if (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP)   return true;
  if (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN) return true;
  return false; // Bias và trend ngược chiều → không trade
}

bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;                                                           // Reset trước khi check
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; }  // Ngoài giờ giao dịch
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }  // Đã hit daily loss
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; }  // Bias = SIDEWAY/NONE
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; }  // Bias ≠ Trend
  return true; // Tất cả guards pass → EA được phép trade
}

//====================================================
// TRANSITIONS
//====================================================

// Chuyển state và log transition (không chứa business logic)
void TransitionTo(EAState next)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s", EnumToString(g_State), EnumToString(next));
  g_State = next;
}

// Reset toàn bộ FVG context và quay về IDLE
// Gọi khi: FVG expired, FVG invalidated, FVG broken, trigger timeout, trade closed, guards fail
void ResetToIdle(string reason = "")
{
  if (InpDebugLog && reason != "")
    PrintFormat("[RESET] %s", reason);

  ZeroMemory(g_FVG);     // Xóa toàn bộ FVG data
  ZeroMemory(g_Trigger); // Xóa trigger data
  g_TradeBarIndex = -1;  // Reset guard chống double-entry

  // Xóa FVG drawing objects khỏi chart
  ObjectDelete(0, FVG_RECT_NAME);
  ObjectDelete(0, FVG_MID_NAME);
  ObjectDelete(0, FVG_LABEL_NAME);

  TransitionTo(EA_IDLE);
}

//====================================================
// FVG HELPERS
//====================================================

// Kiểm tra nến tại barIndex có body "mạnh" không (body/range >= InpFVGMinBodyPct%)
// Mục đích: loại bỏ FVG do nến doji, spinning top gây ra → chỉ lấy FVG từ nến impulse
bool IsCandleStrong(ENUM_TIMEFRAMES tf, int barIndex)
{
  double high  = iHigh (_Symbol, tf, barIndex);
  double low   = iLow  (_Symbol, tf, barIndex);
  double open  = iOpen (_Symbol, tf, barIndex);
  double close = iClose(_Symbol, tf, barIndex);

  double range = high - low;
  if (range < _Point) return false; // Nến có range gần 0 → bỏ qua (tránh chia cho 0)

  return (MathAbs(close - open) / range * 100.0) >= InpFVGMinBodyPct;
}

// Kiểm tra FVG đã bị "fill" chưa = có bar nào sau FVG close vào trong vùng gap không
//   fvgRightIdx = bar index của nến phải (newest) trong pattern 3 nến
//   Scan từ fvgRightIdx-1 (bar ngay sau FVG) đến bar[1] (bar hiện tại đã đóng)
//   Bullish FVG filled: có bar close <= fvgHigh (close vào trong gap từ trên xuống)
//   Bearish FVG filled: có bar close >= fvgLow  (close vào trong gap từ dưới lên)
bool IsFVGAlreadyFilled(ENUM_TIMEFRAMES tf, int fvgRightIdx,
                        double fvgHigh, double fvgLow, MarketDir dir)
{
  for (int j = fvgRightIdx - 1; j >= 1; j--) // Scan từ ngay sau FVG đến bar gần nhất
  {
    double close = iClose(_Symbol, tf, j);
    if (dir == DIR_UP   && close <= fvgHigh) return true; // Close vào trong bullish gap
    if (dir == DIR_DOWN && close >= fvgLow)  return true; // Close vào trong bearish gap
  }
  return false; // Chưa có bar nào fill gap → FVG vẫn còn nguyên
}

// FVG expired = tồn tại quá InpFVGMaxAliveMin phút kể từ khi được confirm
// Lý do expire: FVG quá cũ thường mất relevance, rủi ro cao khi vào lệnh
bool IsFVGExpired()
{
  if (g_FVG.createdTime <= 0) return false; // FVG chưa được set → không thể expire
  return (int)(TimeCurrent() - g_FVG.createdTime) > InpFVGMaxAliveMin * 60;
}

// FVG invalidated = MiddleTF bar[1] close xuyên hoàn toàn qua vùng FVG ngược chiều
//   Bullish FVG: close < FVG.low  → giá đã xuyên xuống hoàn toàn qua gap → FVG không còn ý nghĩa
//   Bearish FVG: close > FVG.high → giá đã xuyên lên hoàn toàn qua gap
bool IsFVGInvalidated()
{
  double lastClose = iClose(_Symbol, InpMiddleTF, 1);
  if (g_FVG.direction == DIR_UP   && lastClose < g_FVG.low)  return true;
  if (g_FVG.direction == DIR_DOWN && lastClose > g_FVG.high) return true;
  return false;
}

//====================================================
// FVG DETECTION
//
// Pattern 3 nến tại bar index i (i = nến giữa / impulse candle):
//   bar[i+1] = nến trái  (older)   → đáy/đỉnh tạo một cạnh của gap
//   bar[i]   = nến giữa  (impulse) → nến mạnh tạo ra gap
//   bar[i-1] = nến phải  (newer)   → đáy/đỉnh tạo cạnh còn lại của gap
//
// Bullish FVG (gap tăng – giá nhảy lên):
//   Điều kiện: bar[i+1].high < bar[i-1].low  (đỉnh nến trái < đáy nến phải = có khoảng trống)
//   gapLow  = bar[i+1].high  (đỉnh nến trái = cạnh dưới của gap)
//   gapHigh = bar[i-1].low   (đáy nến phải  = cạnh trên của gap)
//   → Khi retracement, giá về vùng [gapLow, gapHigh] để tìm buy
//
// Bearish FVG (gap giảm – giá nhảy xuống):
//   Điều kiện: bar[i+1].low > bar[i-1].high
//   gapHigh = bar[i+1].low   (đáy nến trái  = cạnh trên của gap)
//   gapLow  = bar[i-1].high  (đỉnh nến phải = cạnh dưới của gap)
//   → Khi retracement, giá về vùng [gapLow, gapHigh] để tìm sell
//
// Hàm scan từ i=2 → InpFVGScanBars, trả về FVG HỢP LỆ gần nhất (chưa fill, còn trong thời gian sống)
//====================================================

bool FindFVGCandidate(FVGContext &fvg)
{
  MarketDir targetDir = g_MiddleTrend.trend; // Direction từ MiddleTF trend (đã pass guard đồng thuận với bias)
  int maxBar = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2); // Không scan quá số bar thực tế

  for (int i = 2; i <= maxBar; i++) // i=2: nến phải là i-1=1 (bar đã đóng), an toàn để dùng
  {
    double leftHigh  = iHigh (_Symbol, InpMiddleTF, i + 1); // Nến trái (older)
    double leftLow   = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightHigh = iHigh (_Symbol, InpMiddleTF, i - 1); // Nến phải (newer)
    double rightLow  = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midOpen   = iOpen (_Symbol, InpMiddleTF, i);     // Nến giữa (impulse)
    double midClose  = iClose(_Symbol, InpMiddleTF, i);

    double gapHigh, gapLow;

    if (targetDir == DIR_UP) // Tìm Bullish FVG
    {
      if (leftHigh >= rightLow)            continue; // Không có gap: đỉnh trái chạm/vượt đáy phải
      if (midClose <= midOpen)             continue; // Nến giữa phải bullish (close > open)
      if (!IsCandleStrong(InpMiddleTF, i)) continue; // Nến giữa phải đủ mạnh (body >= X%)
      gapLow  = leftHigh; // Cạnh dưới gap = đỉnh nến trái
      gapHigh = rightLow; // Cạnh trên gap = đáy nến phải
    }
    else // Tìm Bearish FVG
    {
      if (leftLow <= rightHigh)            continue; // Không có gap
      if (midClose >= midOpen)             continue; // Nến giữa phải bearish (close < open)
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gapHigh = leftLow;  // Cạnh trên gap = đáy nến trái
      gapLow  = rightHigh; // Cạnh dưới gap = đỉnh nến phải
    }

    // Kiểm tra FVG chưa bị fill: scan từ nến phải (i-1) đến bar hiện tại
    if (IsFVGAlreadyFilled(InpMiddleTF, i - 1, gapHigh, gapLow, targetDir))
      continue; // Đã bị fill → bỏ qua, tìm FVG khác

    // ── FVG hợp lệ → điền vào struct và trả về ──────────────────
    fvg.active      = true;
    fvg.touched     = false;
    fvg.direction   = targetDir;
    fvg.high        = gapHigh;
    fvg.low         = gapLow;
    fvg.mid         = (gapHigh + gapLow) / 2.0;           // Midpoint dùng làm entry tham chiếu
    fvg.createdTime = iTime(_Symbol, InpMiddleTF, i - 1); // Nến phải đóng = thời điểm FVG được confirm
    fvg.touchTime   = 0;
    fvg.barsAlive   = 0;
    fvg.touchBarIdx = -1;

    return true; // Trả về FVG gần nhất (i nhỏ nhất = gần bar hiện tại nhất)
  }

  return false; // Không tìm được FVG nào thỏa mãn
}

//====================================================
// STATE HANDLERS
//====================================================

// EA_IDLE: Quét tìm FVG candidate mỗi tick (nhanh nhờ guard đã lọc trước)
// Khi tìm được → lưu vào g_FVG → chuyển sang WAIT_TOUCH
void OnStateIdle()
{
  FVGContext candidate;
  ZeroMemory(candidate); // Đảm bảo struct sạch trước khi truyền vào FindFVGCandidate
  if (!FindFVGCandidate(candidate)) return; // Không có FVG nào thỏa mãn → chờ tick tiếp

  g_FVG = candidate; // Commit FVG candidate vào global state

  if (InpDebugLog)
    PrintFormat("[FVG FOUND] dir=%s | high=%.5f | low=%.5f | mid=%.5f | created=%s",
      EnumToString(g_FVG.direction), g_FVG.high, g_FVG.low, g_FVG.mid,
      TimeToString(g_FVG.createdTime));

  TransitionTo(EA_WAIT_TOUCH);
}

// EA_WAIT_TOUCH: Theo dõi FVG đang active, chờ giá retracement vào vùng FVG
// Exit sớm (reset) nếu: FVG hết hạn sống | FVG bị invalidate (giá xuyên qua)
// Touch condition:
//   Bullish FVG: giá bid <= FVG.high → giá đã retraced xuống chạm cạnh trên gap
//   Bearish FVG: giá bid >= FVG.low  → giá đã retraced lên chạm cạnh dưới gap
void OnStateWaitTouch()
{
  if (IsFVGExpired())     { ResetToIdle("FVG expired");     return; } // Quá tuổi thọ → bỏ
  if (IsFVGInvalidated()) { ResetToIdle("FVG invalidated"); return; } // Giá xuyên gap ngược chiều → bỏ

  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID); // Dùng bid (không dùng ask) để check touch

  bool touched = false;
  if (g_FVG.direction == DIR_UP   && bid <= g_FVG.high) touched = true; // Giá pullback xuống chạm cạnh trên gap
  if (g_FVG.direction == DIR_DOWN && bid >= g_FVG.low)  touched = true; // Giá pullback lên chạm cạnh dưới gap

  if (!touched) return; // Chưa chạm → chờ tick tiếp

  g_FVG.touched     = true;
  g_FVG.touchTime   = TimeCurrent();
  g_FVG.touchBarIdx = iBarShift(_Symbol, InpTriggerTF, TimeCurrent()); // Bar index TriggerTF lúc touched (dùng đếm timeout)
  g_FVG.barsAlive   = 0; // Reset counter

  if (InpDebugLog)
    PrintFormat("[FVG TOUCHED] dir=%s | price=%.5f | FVG[%.5f – %.5f]",
      EnumToString(g_FVG.direction), bid, g_FVG.low, g_FVG.high);

  TransitionTo(EA_WAIT_TRIGGER);
}

// EA_WAIT_TRIGGER: Giá đã chạm FVG, đang chờ TriggerTF xác nhận entry
void OnStateWaitTrigger()
{
  // TODO: Nếu FVG bị giá phá xuyên (close hoàn toàn ra ngoài) → ResetToIdle("FVG broken")
  // TODO: Nếu barsAlive > InpTriggerMaxBars → ResetToIdle("trigger timeout")  (chờ quá lâu, momentum mất)
  // TODO: Mỗi bar TriggerTF mới → cập nhật TriggerContext (swing structure + breakLevel)
  // TODO: Khi breakLevel bị phá vỡ → BuildOrderPlan() → ExecuteOrder() → TransitionTo(EA_IN_TRADE)
}

// EA_IN_TRADE: Đang có lệnh mở, theo dõi cho đến khi lệnh đóng
void OnStateInTrade()
{
  if (Bars(_Symbol, InpTriggerTF) <= g_TradeBarIndex) return; // Vẫn trong cùng bar lúc vừa gửi lệnh → skip
  // TODO: Kiểm tra còn position/pending nào không → nếu không còn → ResetToIdle("trade closed")
}

//====================================================
// STATE MACHINE
//====================================================

void RunStateMachine()
{
  switch (g_State)
  {
    case EA_IDLE:         OnStateIdle();        break;
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;
    case EA_IN_TRADE:     OnStateInTrade();     break;
  }
}

//====================================================
// SWING DRAWING
//
// Mỗi swing point gồm tối đa 3 objects (đều dùng prefix SW_):
//   SW_ARR_<tag>  – Mũi tên OBJ_ARROW chỉ vào đỉnh/đáy
//   SW_TXT_<tag>  – Text label "H0"/"H1"/"L0"/"L1"
//   SW_KL_<tag>   – Đường ngang nét đứt OBJ_TREND (chỉ vẽ cho key level)
//
// Màu sắc (sáng = gần nhất, tối = cũ hơn):
//   H0 = clrAqua       | H1 = C'0,140,160'
//   L0 = clrYellow     | L1 = C'160,140,0'
//
// Key level logic:
//   Uptrend   → L0 là key level (vẽ đường ngang vàng → MSS nếu close < L0)
//   Downtrend → H0 là key level (vẽ đường ngang cyan → MSS nếu close > H0)
//====================================================

void DrawOneSwing(
  string tag,        // "H0" | "H1" | "L0" | "L1"
  bool   isHigh,     // true = swing high (mũi tên ▼), false = swing low (mũi tên ▲)
  int    barIdx,     // Bar index trên MiddleTF
  double price,      // Giá high (nếu isHigh) hoặc low (nếu !isHigh) của swing
  color  clr,        // Màu hiển thị
  bool   isKeyLevel) // true → vẽ thêm đường ngang nét đứt (key level / MSS line)
{
  string arrName  = SW_PREFIX + "ARR_" + tag;
  string txtName  = SW_PREFIX + "TXT_" + tag;
  string lineName = SW_PREFIX + "KL_"  + tag;

  datetime t = iTime(_Symbol, InpMiddleTF, barIdx); // Thời điểm bar swing (dùng làm tọa độ X)

  // ── Arrow: chỉ vào đỉnh/đáy ─────────────────────────────────────
  if (ObjectFind(0, arrName) < 0)
    ObjectCreate(0, arrName, OBJ_ARROW, 0, t, price);

  ObjectSetInteger(0, arrName, OBJPROP_ARROWCODE, isHigh ? 234 : 233); // 234 = ▼ (đỉnh), 233 = ▲ (đáy)
  ObjectSetInteger(0, arrName, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrName, OBJPROP_WIDTH,     2);
  ObjectSetInteger(0, arrName, OBJPROP_ANCHOR,    isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
  ObjectMove(0, arrName, 0, t, price); // Cập nhật vị trí mỗi lần vẽ (phòng khi barIdx thay đổi)

  // ── Text label: hiển thị tên tag cạnh mũi tên ───────────────────
  // Offset theo chiều dọc để text không đè lên mũi tên
  double offset = (iHigh(_Symbol, InpMiddleTF, barIdx) - iLow(_Symbol, InpMiddleTF, barIdx)) * 0.3;
  double txtY   = isHigh ? price + offset : price - offset; // Đặt text trên đỉnh hoặc dưới đáy

  if (ObjectFind(0, txtName) < 0)
    ObjectCreate(0, txtName, OBJ_TEXT, 0, t, txtY);

  ObjectMove(0, txtName, 0, t, txtY);
  ObjectSetString (0, txtName, OBJPROP_TEXT,     tag);
  ObjectSetInteger(0, txtName, OBJPROP_COLOR,    clr);
  ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, txtName, OBJPROP_ANCHOR,   isHigh ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

  // ── Key Level line: đường ngang nét đứt từ swing đến bar hiện tại ─
  if (isKeyLevel)
  {
    datetime tEnd = iTime(_Symbol, InpMiddleTF, 0); // Kéo đến bar hiện tại (sẽ cập nhật mỗi tick)

    if (ObjectFind(0, lineName) < 0)
      ObjectCreate(0, lineName, OBJ_TREND, 0, t, price, tEnd, price);

    ObjectSetInteger(0, lineName, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, lineName, OBJPROP_STYLE,     STYLE_DASH);
    ObjectSetInteger(0, lineName, OBJPROP_WIDTH,     1);
    ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false); // Không kéo dài vô tận sang phải
    ObjectMove(0, lineName, 0, t,    price);
    ObjectMove(0, lineName, 1, tEnd, price); // Cập nhật điểm phải mỗi tick
  }
  else
  {
    ObjectDelete(0, lineName); // Swing này không còn là key level → xóa đường ngang nếu có
  }
}

void DrawSwingPoints()
{
  if (!InpDebugDraw) return;

  // Chưa đủ swing points (idxH0 = 0 sau ZeroMemory) → xóa tất cả swing objects
  if (g_MiddleTrend.idxH0 <= 0 || g_MiddleTrend.idxH1 <= 0 ||
      g_MiddleTrend.idxL0 <= 0 || g_MiddleTrend.idxL1 <= 0)
  {
    ObjectsDeleteAll(0, SW_PREFIX);
    return;
  }

  bool uptrend   = (g_MiddleTrend.trend == DIR_UP);
  bool downtrend = (g_MiddleTrend.trend == DIR_DOWN);

  DrawOneSwing("H0", true,  g_MiddleTrend.idxH0, g_MiddleTrend.h0, clrAqua,        downtrend); // H0 = key level khi downtrend
  DrawOneSwing("H1", true,  g_MiddleTrend.idxH1, g_MiddleTrend.h1, C'0,140,160',   false);
  DrawOneSwing("L0", false, g_MiddleTrend.idxL0, g_MiddleTrend.l0, clrYellow,      uptrend);   // L0 = key level khi uptrend
  DrawOneSwing("L1", false, g_MiddleTrend.idxL1, g_MiddleTrend.l1, C'160,140,0',   false);
}

//====================================================
// FVG DRAWING
//
// Vẽ rectangle vùng FVG + midpoint line + text label
//
// Cạnh trái rectangle  = createdTime  (cố định = thời điểm FVG confirmed)
// Cạnh phải rectangle  = live khi WAIT_TOUCH (kéo đến bar hiện tại mỗi tick)
//                      = cố định khi WAIT_TRIGGER+ (touchTime + 1 bar MiddleTF)
// Màu: đậm khi candidate, sáng khi touched
//   Bullish: xanh dương     Bearish: cam
//====================================================

void DrawFVGRectangle()
{
  if (!InpDebugDraw) return;

  if (!g_FVG.active) // Không có FVG active → xóa objects cũ nếu còn
  {
    ObjectDelete(0, FVG_RECT_NAME);
    ObjectDelete(0, FVG_MID_NAME);
    ObjectDelete(0, FVG_LABEL_NAME);
    return;
  }

  // ── Xác định cạnh phải (điểm kết thúc) của rectangle ───────────
  datetime rectEnd;
  if (!g_FVG.touched)
    rectEnd = iTime(_Symbol, InpMiddleTF, 0); // Chưa touched → live: kéo tới bar hiện tại mỗi tick
  else
  {
    int touchShift = iBarShift(_Symbol, InpMiddleTF, g_FVG.touchTime);  // Bar MiddleTF tại thời điểm touch
    rectEnd = iTime(_Symbol, InpMiddleTF, MathMax(touchShift - 1, 0));  // Bar tiếp theo sau touch (cố định)
  }

  color rectColor = !g_FVG.touched
    ? (g_FVG.direction == DIR_UP ? C'0,80,160'  : C'140,40,0')  // Màu đậm: FVG candidate chưa touched
    : (g_FVG.direction == DIR_UP ? C'0,160,255' : C'255,100,0'); // Màu sáng: FVG đã được touched

  // ── Rectangle ───────────────────────────────────────────────────
  if (ObjectFind(0, FVG_RECT_NAME) < 0)
    ObjectCreate(0, FVG_RECT_NAME, OBJ_RECTANGLE, 0,
      g_FVG.createdTime, g_FVG.high, rectEnd, g_FVG.low);

  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_COLOR, rectColor);
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_FILL,  true);  // Fill màu bên trong
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_BACK,  true);  // Vẽ dưới nến (không che chart)
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_WIDTH, 1);
  ObjectMove(0, FVG_RECT_NAME, 0, g_FVG.createdTime, g_FVG.high); // Point 0 = góc trên trái (cố định)
  ObjectMove(0, FVG_RECT_NAME, 1, rectEnd,            g_FVG.low);  // Point 1 = góc dưới phải (cập nhật)

  // ── Midpoint line (đứt nét) ─────────────────────────────────────
  if (ObjectFind(0, FVG_MID_NAME) < 0)
    ObjectCreate(0, FVG_MID_NAME, OBJ_TREND, 0,
      g_FVG.createdTime, g_FVG.mid, rectEnd, g_FVG.mid);

  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_COLOR,     clrSilver);
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_STYLE,     STYLE_DOT); // Đường chấm chấm
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_RAY_RIGHT, false); // Không kéo vô tận
  ObjectMove(0, FVG_MID_NAME, 0, g_FVG.createdTime, g_FVG.mid);
  ObjectMove(0, FVG_MID_NAME, 1, rectEnd,            g_FVG.mid);

  // ── Text label ──────────────────────────────────────────────────
  string labelText = StringFormat("FVG %s%s",
    (g_FVG.direction == DIR_UP ? "▲" : "▼"),
    (g_FVG.touched ? " [TOUCHED]" : "")); // Hiển thị trạng thái touched

  if (ObjectFind(0, FVG_LABEL_NAME) < 0)
    ObjectCreate(0, FVG_LABEL_NAME, OBJ_TEXT, 0, g_FVG.createdTime, g_FVG.high);

  ObjectMove(0, FVG_LABEL_NAME, 0, g_FVG.createdTime, g_FVG.high);
  ObjectSetString (0, FVG_LABEL_NAME, OBJPROP_TEXT,    labelText);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_COLOR,   rectColor);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_ANCHOR,  ANCHOR_LEFT_LOWER); // Text nằm ngay dưới cạnh trên
}

//====================================================
// DEBUG PANEL (góc trên bên TRÁI)
//
// Hiển thị toàn bộ context quan trọng để debug trực tiếp trên chart:
//   Bias D1 | MiddleTF Trend + Key Level | Swing H/L values
//   Daily Risk | Balance | EA State | FVG info | Block Reason
//
// Tất cả objects đều có prefix "DBG_" → xóa 1 lần trong OnDeinit
// CORNER_LEFT_UPPER + XDISTANCE=10 + YDISTANCE tăng dần = stack từ trên xuống
//====================================================

void DrawContextDebug()
{
  if (!InpDebugDraw) return;

  // Macro tạo hoặc cập nhật 1 OBJ_LABEL tại góc trên trái
  // Tham số: tên object, text hiển thị, khoảng cách từ trên xuống (px), màu
  #define SET_LABEL(name, text, ypos, clr)                            \
    if (ObjectFind(0, name) < 0)                                      \
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);                     \
    ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);  \
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);                 \
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, ypos);               \
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);                  \
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);                \
    ObjectSetString (0, name, OBJPROP_TEXT,      text);

  SET_LABEL("DBG_HEADER", "── ICT EA Debug ──", 10, clrSilver)

  // ── BIAS D1 ──────────────────────────────── y=30
  // Màu phản ánh hướng: xanh = up, đỏ = down, cam = sideway, xám = none
  color biasColor = (g_Bias.bias == BIAS_UP)     ? clrLime   :
                    (g_Bias.bias == BIAS_DOWN)    ? clrTomato :
                    (g_Bias.bias == BIAS_SIDEWAY) ? clrOrange : clrGray;
  SET_LABEL("DBG_BIAS", StringFormat("Bias  : %s", EnumToString(g_Bias.bias)), 30, biasColor)

  // ── MIDDLE TF TREND + KEY LEVEL ─────────── y=48
  // KL = Key Level cần theo dõi để phát hiện MSS
  color trendColor = (g_MiddleTrend.trend == DIR_UP)   ? clrLime   :
                     (g_MiddleTrend.trend == DIR_DOWN)  ? clrTomato : clrGray;
  SET_LABEL("DBG_TREND",
    StringFormat("Trend : %s | KL=%.5f",
      EnumToString(g_MiddleTrend.trend), g_MiddleTrend.keyLevel),
    48, trendColor)

  // ── SWING HIGH VALUES ───────────────────── y=66
  // H1 (cũ) → H0 (mới): thấy rõ Higher High hay Lower High
  SET_LABEL("DBG_SWING_H",
    StringFormat("H1=%.5f  H0=%.5f", g_MiddleTrend.h1, g_MiddleTrend.h0),
    66, clrAqua)

  // ── SWING LOW VALUES ────────────────────── y=84
  // L1 (cũ) → L0 (mới): thấy rõ Higher Low hay Lower Low
  SET_LABEL("DBG_SWING_L",
    StringFormat("L1=%.5f  L0=%.5f", g_MiddleTrend.l1, g_MiddleTrend.l0),
    84, clrYellow)

  // ── SIDEWAY RANGE (chỉ hiển thị khi bias = SIDEWAY) ─── y=102
  if (g_Bias.bias == BIAS_SIDEWAY) {
    SET_LABEL("DBG_BIAS_RANGE",
      StringFormat("  Range : %.5f – %.5f", g_Bias.rangeLow, g_Bias.rangeHigh),
      102, clrOrange)
  }
  else
    ObjectDelete(0, "DBG_BIAS_RANGE"); // Ẩn khi không sideway

  // ── DAILY RISK ──────────────────────────── y=102 (hoặc 120 nếu sideway hiện)
  double lostPct = g_DailyRisk.startBalance > 0
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
       / g_DailyRisk.startBalance * 100.0 // % đã mất so với đầu ngày
    : 0.0; // Chưa có startBalance (ngày đầu tiên) → hiển thị 0%

  // Màu cảnh báo: đỏ khi hit, cam khi gần hit (>70% ngưỡng), xanh khi bình thường
  color riskColor = g_DailyRisk.limitHit              ? clrRed    :
                    lostPct > InpMaxDailyLossPct * 0.7 ? clrOrange : clrLime;

  SET_LABEL("DBG_RISK",  StringFormat("Risk  : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct), 102, riskColor)
  SET_LABEL("DBG_BAL",   StringFormat("Bal   : %.2f  (start %.2f)", g_DailyRisk.currentBalance, g_DailyRisk.startBalance), 120, clrSilver)
  SET_LABEL("DBG_LIMIT", g_DailyRisk.limitHit ? "⛔ DAILY LOSS HIT" : "✅ Loss OK", 138, g_DailyRisk.limitHit ? clrRed : clrLime)

  // ── EA STATE ────────────────────────────── y=156
  // Màu theo mức độ "hoạt động": xám = idle, cam = chờ, vàng = sắp vào, xanh = trong lệnh
  color stateColor = (g_State == EA_IDLE)         ? clrSilver :
                     (g_State == EA_WAIT_TOUCH)   ? clrOrange :
                     (g_State == EA_WAIT_TRIGGER) ? clrYellow :
                     (g_State == EA_IN_TRADE)     ? clrLime   : clrGray;
  SET_LABEL("DBG_STATE", StringFormat("State : %s", EnumToString(g_State)), 156, stateColor)

  // ── FVG ACTIVE INFO ─────────────────────── y=174 (chỉ khi có FVG)
  if (g_FVG.active)
  {
    color fvgColor = g_FVG.touched ? clrDeepSkyBlue : clrDodgerBlue; // Sáng hơn khi touched
    SET_LABEL("DBG_FVG",
      StringFormat("FVG   : %s [%.5f – %.5f]",
        EnumToString(g_FVG.direction), g_FVG.low, g_FVG.high),
      174, fvgColor)
  }
  else
    ObjectDelete(0, "DBG_FVG"); // Không có FVG → ẩn dòng này

  // ── BLOCK REASON ────────────────────────── y=192 (chỉ khi bị block)
  if (g_BlockReason != BLOCK_NONE) {
    SET_LABEL("DBG_BLOCK",
      StringFormat("Block : %s", EnumToString(g_BlockReason)),
      192, clrTomato)
  }
  else
    ObjectDelete(0, "DBG_BLOCK"); // Không bị block → ẩn dòng này

  #undef SET_LABEL

  ChartRedraw(0); // Force redraw để panel hiển thị ngay lập tức
}

void DrawVisuals()
{
  DrawSwingPoints();   // Vẽ H0/H1/L0/L1 và key level line trên chart
  DrawFVGRectangle();  // Vẽ FVG zone, midpoint, label
  DrawContextDebug();  // Cập nhật debug panel góc trên trái
}

//====================================================
// EA LIFECYCLE
//====================================================

int OnInit()
{
  // Khởi tạo tất cả context về trạng thái mặc định (tất cả số = 0, bool = false)
  ZeroMemory(g_Bias);
  ZeroMemory(g_MiddleTrend);
  ZeroMemory(g_FVG);
  ZeroMemory(g_Trigger);
  ZeroMemory(g_DailyRisk);

  g_State         = EA_IDLE;   // Bắt đầu ở trạng thái chờ
  g_BlockReason   = BLOCK_NONE;
  g_TradeBarIndex = -1;        // -1 = chưa có lệnh nào

  UpdateAllContexts(); // Tính bias + trend ngay khi load (không đợi tick đầu tiên)
  DrawVisuals();       // Vẽ ngay khi load (không đợi tick đầu tiên → không thấy "trống")

  PrintFormat("✅ EA initialized | Bias=%s | MiddleTrend=%s | State=%s",
    EnumToString(g_Bias.bias),
    EnumToString(g_MiddleTrend.trend),
    EnumToString(g_State));

  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts(); // Cập nhật bias + trend + daily risk mỗi tick

  if (EvaluateGuards())        // Tất cả điều kiện pass → chạy state machine
    RunStateMachine();
  else if (g_State != EA_IDLE) // Đang ở state khác IDLE mà bị block → reset về IDLE
    ResetToIdle(EnumToString(g_BlockReason)); // Chỉ reset 1 lần (lần tiếp theo g_State = IDLE → không reset lại)

  if (InpDebugDraw)
    DrawVisuals(); // Cập nhật visuals mỗi tick (FVG rect cạnh phải live, debug panel)
}

void OnDeinit(const int reason)
{
  // Xóa tất cả objects đã tạo khi EA bị gỡ khỏi chart
  ObjectDelete(0, FVG_RECT_NAME);
  ObjectDelete(0, FVG_MID_NAME);
  ObjectDelete(0, FVG_LABEL_NAME);
  ObjectsDeleteAll(0, SW_PREFIX);  // Xóa toàn bộ SW_ARR_*, SW_TXT_*, SW_KL_*
  ObjectsDeleteAll(0, "DBG_");     // Xóa toàn bộ debug panel labels
  ChartRedraw(0);
  PrintFormat("EA deinitialized | reason=%d", reason);
}