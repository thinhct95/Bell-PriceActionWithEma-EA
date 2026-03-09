//+------------------------------------------------------------------+
//| ICT EA – FVG Edition  (MQL5)  v4.3                               |
//| Architecture : BiasTF(D1) + MiddleTF(H1) + TriggerTF(M5)       |
//| State Machine: IDLE → WAIT_TOUCH → WAIT_TRIGGER → IN_TRADE      |
//|                                                                  |
//| Flow tổng thể:                                                   |
//|   1. D1 bias (UP/DOWN) đồng thuận H1 trend                     |
//|   2. H1 FVG thuận xu hướng → chờ price retrace vào FVG          |
//|   3. Giá touch H1 FVG → chờ M5 MSS xác nhận đảo chiều          |
//|   4. M5 MSS = swing break thuận chiều H1:                       |
//|      - H1 UP  → close > tH0 (phá swing high) = bull MSS        |
//|      - H1 DOWN → close < tL0 (phá swing low)  = bear MSS       |
//|      v4.3: MSS chỉ detect khi WAIT_TRIGGER, không vẽ/detect khác |
//|   5. Entry = limit tại swing level vừa bị phá (tH0 hoặc tL0)   |
//|   6. SL = swing đối diện (tL0 cho buy, tH0 cho sell)           |
//|   7. TP = Entry ± 2R                                            |
//|                                                                  |
//| Drawing: objects KHÔNG BAO GIỜ bị xóa, chỉ update              |
//+------------------------------------------------------------------+
#property copyright "Bell's ICT EA"
#property version   "4.30"

#define MAX_FVG_POOL 30

//====================================================
// INPUTS
//====================================================
input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_D1;  // Bias TF (HTF)
input ENUM_TIMEFRAMES InpMiddleTF        = PERIOD_H1;  // FVG + trend TF (MTF)
input ENUM_TIMEFRAMES InpTriggerTF       = PERIOD_M5;  // Entry confirmation (LTF)

input double InpRiskPercent              = 1.0;        // Risk % per trade
input double InpRiskReward               = 2.0;        // TP/SL ratio
input double InpMaxDailyLossPct          = 3.0;        // Max daily loss %

input int    InpLondonStartHour          = 8;          // London open (UTC)
input int    InpLondonEndHour            = 17;         // London close (UTC)
input int    InpNYStartHour              = 13;         // NY open (UTC)
input int    InpNYEndHour                = 22;         // NY close (UTC)

input int    InpSwingRange               = 3;          // Bars each side for swing confirm
input int    InpSwingLookback            = 50;         // MiddleTF swing scan bars
input int    InpTriggerSwingLookback     = 30;         // TriggerTF swing scan bars

input int    InpFVGMaxAliveMin           = 4320;       // Max FVG lifetime (min) = 72h (cả PENDING + TOUCHED)
input int    InpFVGScanBars              = 50;         // MiddleTF bars to scan for FVGs
input double InpFVGMinBodyPct            = 60.0;       // Mid-candle min body %
input int    InpMSSMinDepthPts           = 30;         // MSS min swing depth (points): |tH0-tL0| phải >= giá trị này

input long   InpMagicNumber              = 20250308;   // EA magic number
input int    InpSlippage                 = 5;          // Max slippage (points)

input bool   InpDebugLog                 = true;       // Journal logging
input bool   InpDebugDraw                = true;       // Chart drawing

//====================================================
// ENUMS
//====================================================
enum EAState
{
  EA_IDLE,          // Tìm FVG tốt nhất
  EA_WAIT_TOUCH,    // Chờ giá retrace vào MiddleTF FVG
  EA_WAIT_TRIGGER,  // Chờ TriggerTF MSS xác nhận
  EA_IN_TRADE       // Đang có lệnh / position
};

enum HTFBias    { BIAS_NONE=0, BIAS_UP=1, BIAS_DOWN=-1, BIAS_SIDEWAY=2 };
enum MarketDir  { DIR_NONE=0,  DIR_UP=1,  DIR_DOWN=-1                  };
enum BlockReason
{
  BLOCK_NONE, BLOCK_SESSION, BLOCK_DAILY_LOSS,
  BLOCK_BIAS_MISMATCH, BLOCK_NO_BIAS
};
enum FVGStatus
{
  FVG_PENDING,   // Hình thành, chưa touch
  FVG_TOUCHED,   // Giá đã vào vùng gap
  FVG_USED       // 0=expired 1=broken 2=triggered
};

//====================================================
// STRUCTS
//====================================================
struct BiasContext
{
  HTFBias  bias;                         // Hướng bias: UP/DOWN/SIDEWAY/NONE
  double   rangeHigh, rangeLow;          // Biên range khi SIDEWAY (dùng b2 H/L)
  datetime lastBarTime;                  // Guard: chỉ recalc khi D1 bar mới mở
};

//----------------------------------------------------------------------
// TFTrendContext – Swing structure + MSS
//
// v4.3: MSS CHỈ detect cho TriggerTF, CHỈ khi WAIT_TRIGGER state.
//   Không detect MSS cho MiddleTF (không dùng cho entry).
//   MSS check chạy TRƯỚC re-scan → dùng OLD swing values:
//   - H1 UP  → close > OLD tH0 = bull MSS → entry=tH0, SL=tL0
//   - H1 DOWN → close < OLD tL0 = bear MSS → entry=tL0, SL=tH0
//----------------------------------------------------------------------
struct TFTrendContext
{
  // ── Swing structure ────────────────────────────────────────────
  MarketDir trend;                       // DIR_UP / DIR_DOWN / DIR_NONE
  double    h0, h1, l0, l1;             // 2 swing highs + 2 swing lows gần nhất
  int       idxH0, idxH1, idxL0, idxL1; // Bar indices tương ứng
  double    keyLevel;                    // L0 (uptrend) hoặc H0 (downtrend)
  datetime  lastBarTime;                 // Guard: chỉ recalc trên bar mới

  // ── MSS tracking ───────────────────────────────────────────────
  datetime  lastMssTime;                 // Open time cây nến phá keyLevel
  double    lastMssLevel;                // KeyLevel bị phá (= giá entry)
  MarketDir lastMssBreak;                // DIR_UP = bull MSS, DIR_DOWN = bear MSS
  double    mssSLSwing;                  // v4: swing SL tại thời điểm MSS
                                         //     (L0 cho bull, H0 cho bear)
};

struct FVGRecord
{
  int       id;                          // Unique FVG ID, auto-increment
  FVGStatus status;                      // PENDING → TOUCHED → USED lifecycle
  int       usedCase;                    // 0=expired 1=broken(H1 close phá) 2=triggered(MSS)
  MarketDir direction;                   // DIR_UP=bullish gap, DIR_DOWN=bearish gap
  double    high, low, mid;              // Biên trên, biên dưới, midpoint của gap
  datetime  createdTime;                 // Thời gian cây nến bên phải gap (i-1)
  datetime  touchTime;                   // Thời gian bid đầu tiên vào vùng gap
  datetime  usedTime;                    // Thời gian FVG bị consumed (broken/expired/triggered)
  MarketDir triggerTrendAtTouch;         // M5 trend tại thời điểm touch (dùng cho case2 check)

  // v4.3: MSS info lưu khi triggered (case2) → dùng cho vẽ + order
  datetime  mssTime;                     // Thời gian cây nến MSS
  double    mssEntry;                    // Entry = swing bị phá (tH0 hoặc tL0)
  double    mssSL;                       // SL = swing đối diện (tL0 hoặc tH0)
};

struct OrderPlan
{
  bool   valid;                          // true khi đã build thành công, sẵn sàng gửi
  int    direction;                      // +1 = BUY LIMIT, -1 = SELL LIMIT
  double entry, stopLoss, takeProfit, lot; // Giá entry, SL, TP, lot size
  int    parentFVGId;                    // ID FVG gốc → ghi vào comment lệnh
};

struct DailyRiskContext
{
  double   startBalance, currentBalance; // Balance đầu ngày vs hiện tại
  datetime dayStartTime;                 // Open time D1 bar hiện tại
  bool     limitHit;                     // true → dừng trade hết ngày
};

//====================================================
// GLOBALS
//====================================================
EAState          g_State       = EA_IDLE;  // State machine hiện tại
BlockReason      g_BlockReason = BLOCK_NONE; // Lý do bị block (nếu có)

BiasContext      g_Bias;                   // D1 bias context
TFTrendContext   g_MiddleTrend;            // H1 trend + swing (không MSS)
TFTrendContext   g_TriggerTrend;           // M5 swing + MSS (chỉ khi WAIT_TRIGGER)
DailyRiskContext g_DailyRisk;              // Daily drawdown tracking

FVGRecord  g_FVGPool[MAX_FVG_POOL];       // Pool chứa tối đa 30 FVG records
int        g_FVGCount      = 0;           // Số FVG hiện có trong pool
int        g_NextFVGId     = 0;           // ID tiếp theo cho FVG mới
int        g_ActiveFVGIdx  = -1;          // Index FVG đang theo dõi (-1 = không có)
int        g_TradeBarIndex = -1;          // Bar index lúc đặt lệnh (dùng cho timeout)

OrderPlan        g_OrderPlan;              // Kế hoạch lệnh hiện tại
ulong            g_PendingTicket = 0;      // Ticket pending order (0 = không có)

// Chart object prefixes
const string SW_PREFIX   = "SW_";        // MiddleTF swing arrows/labels
const string TS_PREFIX   = "TS_";        // TriggerTF swing arrows/labels
const string MSS_PREFIX  = "MSS_";       // MSS markers
const string FVGP_PREFIX = "FVGP_";      // MiddleTF FVG rectangles
const string ORD_PREFIX  = "ORD_";       // Order visualization (TradingView-style)
const string DBG_PREFIX  = "DBG_";       // Debug panel labels

//+------------------------------------------------------------------+
//|  MQL5 HELPER: iBarShift replacement                              |
//+------------------------------------------------------------------+
int MyBarShift(string symbol, ENUM_TIMEFRAMES tf, datetime time, bool exact = false)
{
  datetime arr[];                                      // Mảng chứa open time tất cả bars
  int maxCopy = MathMin(Bars(symbol, tf), 5000);       // Giới hạn 5000 bars tránh quá tải bộ nhớ
  int copied = CopyTime(symbol, tf, 0, maxCopy, arr);  // Copy toàn bộ bar times vào arr[]
  if (copied <= 0) return -1;                          // Không có data → trả -1

  for (int i = copied - 1; i >= 0; i--)               // Duyệt từ mới nhất → cũ nhất
  {
    if (arr[i] <= time)                                // Tìm bar đầu tiên có time <= target
      return copied - 1 - i;                           // Convert array index → bar shift (0=newest)
  }
  return exact ? -1 : copied - 1;                     // exact=true: ko tìm thấy→-1, false→bar cũ nhất
}

//+------------------------------------------------------------------+
//|  SECTION 1 – SWING HELPERS                                       |
//+------------------------------------------------------------------+

bool IsSwingHighAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iHigh(_Symbol, tf, i);                    // Giá high tại bar i (ứng viên swing)
  for (int k = 1; k <= InpSwingRange; k++)             // Kiểm tra InpSwingRange bars 2 bên
    if (iHigh(_Symbol, tf, i-k) >= p || iHigh(_Symbol, tf, i+k) >= p) return false; // Có bar cao hơn → không phải swing
  return true;                                         // Bar i là đỉnh cao nhất trong vùng
}

bool IsSwingLowAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iLow(_Symbol, tf, i);                     // Giá low tại bar i (ứng viên swing)
  for (int k = 1; k <= InpSwingRange; k++)             // Kiểm tra InpSwingRange bars 2 bên
    if (iLow(_Symbol, tf, i-k) <= p || iLow(_Symbol, tf, i+k) <= p) return false; // Có bar thấp hơn → không phải swing
  return true;                                         // Bar i là đáy thấp nhất trong vùng
}

bool ScanSwingStructure(
  ENUM_TIMEFRAMES tf, int lookback,
  double &h0, double &h1, int &idxH0, int &idxH1,
  double &l0, double &l1, int &idxL0, int &idxL1)
{
  int maxBar = MathMin(lookback, Bars(_Symbol, tf) - InpSwingRange - 2); // Giới hạn scan range
  double highs[2]; int hiIdx[2]; int hc = 0;          // 2 swing highs gần nhất (h0=mới, h1=cũ)
  double lows [2]; int loIdx[2]; int lc = 0;          // 2 swing lows  gần nhất (l0=mới, l1=cũ)

  for (int i = InpSwingRange + 1; i <= maxBar; i++)   // Bắt đầu từ bar đủ xa để có range 2 bên
  {
    if (hc < 2 && IsSwingHighAt(tf, i)) { highs[hc] = iHigh(_Symbol, tf, i); hiIdx[hc] = i; hc++; } // Thu thập swing high
    if (lc < 2 && IsSwingLowAt (tf, i)) { lows [lc] = iLow (_Symbol, tf, i); loIdx[lc] = i; lc++; } // Thu thập swing low
    if (hc == 2 && lc == 2) break;                    // Đủ 2 cặp → dừng scan
  }
  if (hc < 2 || lc < 2) return false;                 // Thiếu swing → không xác định được trend

  h0 = highs[0]; idxH0 = hiIdx[0];                    // Swing high gần nhất (most recent)
  h1 = highs[1]; idxH1 = hiIdx[1];                    // Swing high trước đó (để so sánh HH/LH)
  l0 = lows [0]; idxL0 = loIdx[0];                    // Swing low gần nhất
  l1 = lows [1]; idxL1 = loIdx[1];                    // Swing low trước đó (để so sánh HL/LL)
  return true;
}

void ResolveTrendFromSwings(
  ENUM_TIMEFRAMES tf,
  double h0, double h1, double l0, double l1,
  MarketDir &trend, double &keyLevel)
{
  double c1 = iClose(_Symbol, tf, 1);
  if      (h0 > h1 && l0 > l1 && c1 > l0) { trend = DIR_UP;   keyLevel = l0; }  // HH+HL → uptrend, KL=L0
  else if (h0 < h1 && l0 < l1 && c1 < h0) { trend = DIR_DOWN; keyLevel = h0; }  // LH+LL → downtrend, KL=H0
  else                                      { trend = DIR_NONE; keyLevel = 0;  }
}

//+------------------------------------------------------------------+
//|  SECTION 2 – CONTEXT UPDATERS                                    |
//+------------------------------------------------------------------+

HTFBias ResolveBias(double b1H, double b1L, double b1C, double b2H, double b2L)
{
  if (b1C > b2H)               return BIAS_UP;          // Close trên high hôm qua
  if (b1C < b2L)               return BIAS_DOWN;        // Close dưới low hôm qua
  if (b1H > b2H && b1C < b2H) return BIAS_DOWN;        // False break up → bearish
  if (b1L < b2L && b1C > b2L) return BIAS_UP;          // False break down → bullish
  return BIAS_SIDEWAY;
}

void UpdateBiasContext()
{
  datetime t0 = iTime(_Symbol, InpBiasTF, 0);         // Open time bar D1 hiện tại
  if (t0 == g_Bias.lastBarTime) return;                // Đã tính rồi → skip (chỉ tính 1 lần/ngày)
  g_Bias.lastBarTime = t0;                             // Đánh dấu đã xử lý bar này

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; } // Chưa đủ data

  double b1H = iHigh (_Symbol, InpBiasTF, 1);         // D1 bar hôm qua: high
  double b1L = iLow  (_Symbol, InpBiasTF, 1);         //                  low
  double b1C = iClose(_Symbol, InpBiasTF, 1);         //                  close
  double b2H = iHigh (_Symbol, InpBiasTF, 2);         // D1 bar hôm kia:  high (reference range)
  double b2L = iLow  (_Symbol, InpBiasTF, 2);         //                   low  (reference range)

  HTFBias prev = g_Bias.bias;                          // Lưu bias cũ để log khi thay đổi
  g_Bias.bias  = ResolveBias(b1H, b1L, b1C, b2H, b2L); // So sánh b1 close vs b2 range
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2H : 0; // SIDEWAY: lưu biên trên
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2L : 0; // SIDEWAY: lưu biên dưới

  if (InpDebugLog && g_Bias.bias != prev)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias), b1H, b1L, b1C, b2H, b2L);
}

//----------------------------------------------------------------------
// UpdateTFTrendContext
//
// v4.3: MSS check CHỈ cho TriggerTF + CHỈ khi EA_WAIT_TRIGGER.
//   MiddleTF: chỉ scan swing + resolve trend, KHÔNG check MSS.
//   TriggerTF: check MSS TRƯỚC re-scan (dùng OLD swing).
//     Gate: g_State == EA_WAIT_TRIGGER (có TOUCHED FVG đang chờ).
//----------------------------------------------------------------------
void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime t0 = iTime(_Symbol, tf, 0);
  if (t0 == ctx.lastBarTime) return;                   // Chỉ chạy 1 lần/bar
  ctx.lastBarTime = t0;

  double   bar1C = iClose(_Symbol, tf, 1);             // Bar vừa đóng: close
  datetime bar1T = iTime (_Symbol, tf, 1);             //                time

  // ══════════════════════════════════════════════════════════════════
  // MSS check – CHỈ TriggerTF + CHỈ khi WAIT_TRIGGER
  //
  // Chạy TRƯỚC re-scan → ctx.h0/l0 là OLD values (swing chưa cập nhật)
  // → Entry = OLD tH0 (buy) hoặc OLD tL0 (sell) = swing vừa bị phá
  // → SL = OLD tL0 (buy) hoặc OLD tH0 (sell) = swing đối diện
  //
  // Khi không ở WAIT_TRIGGER → skip hoàn toàn (không detect, không vẽ)
  // ══════════════════════════════════════════════════════════════════
  if (tf == InpTriggerTF                               // Chỉ TriggerTF (M5)
      && g_State == EA_WAIT_TRIGGER                    // Chỉ khi đang chờ MSS
      && ctx.h0 > 0 && ctx.l0 > 0                     // Có swing points
      && g_MiddleTrend.trend != DIR_NONE)              // H1 có hướng
  {
    bool mssHit = false;
    MarketDir breakDir = DIR_NONE;
    double entryLevel = 0, slLevel = 0;

    if (g_MiddleTrend.trend == DIR_UP                  // H1 UP → tìm bull MSS
        && bar1C > ctx.h0)                             // M5 close > OLD tH0 → phá swing high
    {
      mssHit     = true;
      breakDir   = DIR_UP;
      entryLevel = ctx.h0;                             // Entry = tH0 vừa bị phá
      slLevel    = ctx.l0;                             // SL = tL0 (đáy gần nhất)
    }
    else if (g_MiddleTrend.trend == DIR_DOWN           // H1 DOWN → tìm bear MSS
             && bar1C < ctx.l0)                        // M5 close < OLD tL0 → phá swing low
    {
      mssHit     = true;
      breakDir   = DIR_DOWN;
      entryLevel = ctx.l0;                             // Entry = tL0 vừa bị phá
      slLevel    = ctx.h0;                             // SL = tH0 (đỉnh gần nhất)
    }

    if (mssHit && bar1T != ctx.lastMssTime)            // Break detected + chưa ghi nhận bar này
    {
      // v4.3: Check minimum swing depth — |tH0 - tL0| phải đủ lớn
      //   Ngăn MSS fire trên swing quá nông (dao động bình thường)
      double swingDepth = MathAbs(ctx.h0 - ctx.l0) / _Point;  // Depth tính bằng points
      if (swingDepth < InpMSSMinDepthPts)
      {
        if (InpDebugLog)
          PrintFormat("[M5 MSS SKIP] depth=%.0f pts < %d | H0=%.5f L0=%.5f | %s",
            swingDepth, InpMSSMinDepthPts, ctx.h0, ctx.l0, TimeToString(bar1T));
      }
      else
      {
        ctx.lastMssTime  = bar1T;                        // Lưu vào context (dùng cho case2 check)
        ctx.lastMssLevel = entryLevel;
        ctx.lastMssBreak = breakDir;
        ctx.mssSLSwing   = slLevel;

        if (InpDebugLog)
          PrintFormat("[M5 MSS] %s | entry=%.5f SL=%.5f depth=%.0fpts | close=%.5f | H0=%.5f L0=%.5f | %s",
            (breakDir == DIR_UP) ? "▲ Bull" : "▼ Bear",
            entryLevel, slLevel, swingDepth, bar1C,
            ctx.h0, ctx.l0, TimeToString(bar1T));
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Re-scan swing structure
  // ══════════════════════════════════════════════════════════════════
  double h0, h1, l0, l1;
  int idxH0, idxH1, idxL0, idxL1;
  if (!ScanSwingStructure(tf, lookback, h0, h1, idxH0, idxH1, l0, l1, idxL0, idxL1))
    { ctx.trend = DIR_NONE; return; }

  ctx.h0 = h0; ctx.idxH0 = idxH0;
  ctx.h1 = h1; ctx.idxH1 = idxH1;
  ctx.l0 = l0; ctx.idxL0 = idxL0;
  ctx.l1 = l1; ctx.idxL1 = idxL1;

  MarketDir prev = ctx.trend;
  ResolveTrendFromSwings(tf, h0, h1, l0, l1, ctx.trend, ctx.keyLevel);

  if (InpDebugLog && ctx.trend != prev)
    PrintFormat("[%s TREND] %s → %s | H0=%.5f H1=%.5f L0=%.5f L1=%.5f | KL=%.5f",
      EnumToString(tf), EnumToString(prev), EnumToString(ctx.trend),
      h0, h1, l0, l1, ctx.keyLevel);
}

void UpdateDailyRiskContext()
{
  datetime today = iTime(_Symbol, PERIOD_D1, 0);      // Open time ngày hiện tại
  if (today != g_DailyRisk.dayStartTime)               // Ngày mới → reset tracking
  {
    g_DailyRisk.dayStartTime = today;                  // Đánh dấu ngày mới
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Snapshot balance đầu ngày
    g_DailyRisk.limitHit     = false;                  // Reset flag daily loss
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;                    // Đã hit limit → không cần check nữa
  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Balance hiện tại
  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance) // Tính % loss trong ngày
                    / g_DailyRisk.startBalance * 100.0;
  if (lostPct >= InpMaxDailyLossPct)                   // Vượt ngưỡng → dừng trade
  {
    g_DailyRisk.limitHit = true;                       // Set flag → EvaluateGuards() sẽ block
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lostPct, g_DailyRisk.currentBalance);
  }
}

void UpdateAllContexts()
{
  UpdateDailyRiskContext();                             // 1. Check daily drawdown trước tiên
  UpdateBiasContext();                                 // 2. D1 bias (UP/DOWN/SIDEWAY)
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);  // 3. H1 swing+trend (no MSS)
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend); // 4. M5 swing + MSS (if WAIT_TRIGGER)
}

//+------------------------------------------------------------------+
//|  SECTION 3 – GUARDS                                              |
//+------------------------------------------------------------------+

bool IsSessionAllowed()    { return true; /* TODO: London/NY session filter dựa trên InpLondon/NYHour */ }
bool IsDailyLossOK()       { return !g_DailyRisk.limitHit; } // false nếu đã vượt InpMaxDailyLossPct
bool IsBiasValid()         { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; } // Cần direction rõ ràng
bool IsMiddleTrendAligned()                            // H1 trend phải cùng hướng D1 bias
{
  if (g_MiddleTrend.trend == DIR_NONE) return false;   // H1 chưa xác định → block
  return (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP) ||   // D1 UP + H1 UP ✓
         (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN);    // D1 DOWN + H1 DOWN ✓
}

bool EvaluateGuards()                                  // Kiểm tra tất cả điều kiện trước khi trade
{
  g_BlockReason = BLOCK_NONE;                          // Reset reason
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; } // Ngoài giờ
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; } // Vượt loss/ngày
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; } // D1 sideway/none
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; } // H1 ngược D1
  return true;                                         // Tất cả OK → cho phép trade
}

//+------------------------------------------------------------------+
//|  SECTION 4 – STATE MACHINE HELPERS                               |
//+------------------------------------------------------------------+

void TransitionTo(EAState next)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s", EnumToString(g_State), EnumToString(next));
  g_State = next;
}

void ResetToIdle(string reason = "")
{
  if (InpDebugLog && reason != "")
    PrintFormat("[RESET→IDLE] %s", reason);
  g_ActiveFVGIdx  = -1;                               // Bỏ FVG đang theo dõi
  g_TradeBarIndex = -1;                                // Reset bar index
  g_PendingTicket = 0;                                 // Không còn pending order
  ZeroMemory(g_OrderPlan);                             // Xóa order plan
  TransitionTo(EA_IDLE);                               // Quay về IDLE tìm FVG mới
}

//+------------------------------------------------------------------+
//|  SECTION 5 – FVG HELPERS                                         |
//+------------------------------------------------------------------+

bool IsCandleStrong(ENUM_TIMEFRAMES tf, int i)
{
  double h = iHigh(_Symbol, tf, i), l = iLow(_Symbol, tf, i); // Range = high - low
  double o = iOpen(_Symbol, tf, i), c = iClose(_Symbol, tf, i); // Body = |close - open|
  double range = h - l;                                // Tổng chiều dài nến
  if (range < _Point) return false;                    // Nến quá nhỏ → bỏ qua
  return (MathAbs(c - o) / range * 100.0) >= InpFVGMinBodyPct; // Body >= 60% range → strong
}

bool IsFVGInPool(datetime created)
{
  for (int j = 0; j < g_FVGCount; j++)
    if (g_FVGPool[j].createdTime == created) return true;
  return false;
}

//+------------------------------------------------------------------+
//|  SECTION 6 – FVG POOL: SCAN & REGISTER                          |
//+------------------------------------------------------------------+

void ScanAndRegisterFVGs()
{
  static datetime s_lastScan = 0;                      // Guard: chỉ scan 1 lần mỗi bar H1
  datetime t0 = iTime(_Symbol, InpMiddleTF, 0);       // Open time bar H1 hiện tại
  if (t0 == s_lastScan) return;                        // Đã scan bar này rồi → skip
  s_lastScan = t0;                                     // Đánh dấu đã scan

  MarketDir dir = g_MiddleTrend.trend;                 // Chỉ scan FVG thuận chiều H1 trend
  if (dir == DIR_NONE) return;                         // Không có trend → không scan

  int maxBar = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2); // Giới hạn scan range

  for (int i = 2; i <= maxBar; i++)
  {
    double leftH  = iHigh (_Symbol, InpMiddleTF, i + 1);  // Cây bên trái gap
    double leftL  = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightH = iHigh (_Symbol, InpMiddleTF, i - 1);  // Cây bên phải gap
    double rightL = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midO   = iOpen (_Symbol, InpMiddleTF, i);       // Cây giữa (tạo gap)
    double midC   = iClose(_Symbol, InpMiddleTF, i);
    double gH = 0, gL = 0;

    if (dir == DIR_UP)                                     // Bullish FVG
    {
      if (leftH >= rightL) continue;                       // Không có gap
      if (midC <= midO) continue;                          // Cây giữa phải bullish
      if (!IsCandleStrong(InpMiddleTF, i)) continue;      // Body đủ lớn
      gL = leftH; gH = rightL;                            // Gap = leftH → rightL
    }
    else                                                   // Bearish FVG
    {
      if (leftL <= rightH) continue;
      if (midC >= midO) continue;                          // Cây giữa phải bearish
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gH = leftL; gL = rightH;                            // Gap = rightH → leftL
    }

    datetime created = iTime(_Symbol, InpMiddleTF, i - 1); // FVG created = open time cây phải
    if (IsFVGInPool(created)) continue;                // Đã có trong pool → skip trùng

    // ── Evict oldest USED if pool full ──────────────────────────────
    if (g_FVGCount >= MAX_FVG_POOL)                    // Pool đầy 30 slot
    {
      int evict = -1; datetime oldest = TimeCurrent(); // Tìm USED cũ nhất để xóa
      for (int j = 0; j < g_FVGCount; j++)
        if (g_FVGPool[j].status == FVG_USED && g_FVGPool[j].createdTime < oldest)
          { oldest = g_FVGPool[j].createdTime; evict = j; } // Ghi nhớ slot cũ nhất
      if (evict < 0) { if (InpDebugLog) Print("[FVG POOL] Full"); break; } // Không có USED → stop
      for (int j = evict; j < g_FVGCount - 1; j++) g_FVGPool[j] = g_FVGPool[j + 1]; // Shift array
      g_FVGCount--;                                    // Giảm count
      if      (g_ActiveFVGIdx >  evict) g_ActiveFVGIdx--; // Fix active index sau shift
      else if (g_ActiveFVGIdx == evict) g_ActiveFVGIdx = -1; // Active bị evict → clear
    }

    // ── Build record ─────────────────────────────────────────────────
    FVGRecord rec;
    ZeroMemory(rec);                                   // Init tất cả field = 0
    rec.id = g_NextFVGId++; rec.direction = dir;       // Assign ID tự tăng + hướng
    rec.high = gH; rec.low = gL; rec.mid = (gH + gL) / 2.0; // Biên gap + midpoint
    rec.createdTime = created;                         // Thời gian tạo
    int rightBar = i - 1;                              // Cây bên phải gap (dùng cho scan status)

    // P1: case1 – Kiểm tra đã bị phá xuyên chưa (H1 close qua gap)
    bool c1Hit = false; datetime c1T = 0;              // Flag + thời gian bị phá
    for (int j = rightBar - 1; j >= 1; j--)             // Scan từ cây phải → hiện tại
    {
      double cl = iClose(_Symbol, InpMiddleTF, j);    // Close mỗi bar H1
      if ((rec.direction == DIR_UP   && cl < rec.low) || // Bull FVG: close dưới biên dưới = phá
          (rec.direction == DIR_DOWN && cl > rec.high))   // Bear FVG: close trên biên trên = phá
        { c1Hit = true; c1T = iTime(_Symbol, InpMiddleTF, j); break; } // Ghi nhận thời gian phá
    }
    if (c1Hit) { rec.status = FVG_USED; rec.usedCase = 1; rec.usedTime = c1T; } // Case1 = broken
    else
    {
      // P2: touch – Kiểm tra giá đã wick vào gap chưa
      bool tdHit = false; datetime tdT = 0;            // Flag + thời gian touch
      for (int j = rightBar - 1; j >= 1; j--)         // Scan từ cây phải → hiện tại
      {
        bool inGap = (rec.direction == DIR_UP   && iLow (_Symbol, InpMiddleTF, j) <= rec.high) || // Bull: low ≤ gap top
                     (rec.direction == DIR_DOWN && iHigh(_Symbol, InpMiddleTF, j) >= rec.low);     // Bear: high ≥ gap bottom
        if (inGap) { tdHit = true; tdT = iTime(_Symbol, InpMiddleTF, j); break; } // Đã touch
      }
      if (tdHit) { rec.status = FVG_TOUCHED; rec.touchTime = tdT; rec.triggerTrendAtTouch = g_TriggerTrend.trend; } // Ghi nhận M5 trend lúc touch
      else
      {
        rec.status = FVG_PENDING;                      // Chưa touch, chưa bị phá → chờ
        if ((int)(TimeCurrent() - rec.createdTime) > InpFVGMaxAliveMin * 60) // Quá 72h
          { rec.status = FVG_USED; rec.usedCase = 0; rec.usedTime = TimeCurrent(); } // Case0 = expired
      }
    }

    g_FVGPool[g_FVGCount] = rec;                       // Thêm vào pool
    g_FVGCount++;                                      // Tăng count

    if (InpDebugLog)
      PrintFormat("[FVG +] #%d %s [%.5f–%.5f] %s | %s",
        rec.id, EnumToString(rec.direction), rec.low, rec.high,
        EnumToString(rec.status), TimeToString(rec.createdTime));
  }
}

//+------------------------------------------------------------------+
//|  SECTION 7 – FVG POOL: UPDATE STATUSES (every tick)             |
//+------------------------------------------------------------------+

void UpdateFVGStatuses()
{
  double   bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID); // Giá bid hiện tại (dùng cho touch check)
  double   midC1 = iClose(_Symbol, InpMiddleTF, 1);   // H1 bar vừa đóng: close (dùng cho case1)
  datetime midT1 = iTime (_Symbol, InpMiddleTF, 1);   // H1 bar vừa đóng: time

  for (int i = 0; i < g_FVGCount; i++)                // Duyệt toàn bộ pool
  {
    if (g_FVGPool[i].status == FVG_USED) continue;     // Đã consumed → skip

    // ── 1. Case1: H1 close phá xuyên FVG → broken ──────────────────
    bool c1 = (g_FVGPool[i].direction == DIR_UP   && midC1 < g_FVGPool[i].low) || // Bull: close < bottom
              (g_FVGPool[i].direction == DIR_DOWN && midC1 > g_FVGPool[i].high);   // Bear: close > top
    if (c1)
    {
      g_FVGPool[i].status   = FVG_USED;
      g_FVGPool[i].usedCase = 1;
      g_FVGPool[i].usedTime = midT1;
      if (InpDebugLog)
        PrintFormat("[FVG #%d] BROKEN | close=%.5f", g_FVGPool[i].id, midC1);
      continue;
    }

    if (g_FVGPool[i].status == FVG_PENDING)
    {
      // ── 2. Expire ────────────────────────────────────────────────────
      int age = (int)(TimeCurrent() - g_FVGPool[i].createdTime);
      if (age > InpFVGMaxAliveMin * 60)
      {
        g_FVGPool[i].status = FVG_USED; g_FVGPool[i].usedCase = 0;
        g_FVGPool[i].usedTime = TimeCurrent();
        continue;
      }

      // ── 3. Touch: bid vào vùng gap ───────────────────────────────────
      bool touched = (g_FVGPool[i].direction == DIR_UP   && bid <= g_FVGPool[i].high) || // Bull: bid retrace xuống ≤ gap top
                     (g_FVGPool[i].direction == DIR_DOWN && bid >= g_FVGPool[i].low);    // Bear: bid retrace lên ≥ gap bottom
      if (touched)
      {
        g_FVGPool[i].status              = FVG_TOUCHED;   // Chuyển sang TOUCHED
        g_FVGPool[i].touchTime           = TimeCurrent();  // Ghi nhận thời gian touch
        g_FVGPool[i].triggerTrendAtTouch = g_TriggerTrend.trend; // Snapshot M5 trend lúc touch
        if (InpDebugLog)
          PrintFormat("[FVG #%d] TOUCHED | bid=%.5f [%.5f–%.5f]",
            g_FVGPool[i].id, bid, g_FVGPool[i].low, g_FVGPool[i].high);
      }
    }
    else if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      // ── 4. Case2: M5 MSS đã xảy ra SAU touch → triggered ───────────
      //
      //   Check: g_TriggerTrend.lastMssTime > touchTime + cùng hướng
      //   v4.3: Lưu MSS info vào FVG record (cho vẽ + order)
      //
      bool hasMSS =
        g_TriggerTrend.lastMssTime > g_FVGPool[i].touchTime &&   // MSS sau touch
        g_TriggerTrend.lastMssBreak == g_FVGPool[i].direction;   // Cùng hướng

      if (hasMSS)
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 2;                    // Case2 = triggered
        g_FVGPool[i].usedTime = TimeCurrent();

        // v4.3: Copy MSS info vào FVG (dùng cho vẽ MSS marker + order plan)
        g_FVGPool[i].mssTime  = g_TriggerTrend.lastMssTime;
        g_FVGPool[i].mssEntry = g_TriggerTrend.lastMssLevel;
        g_FVGPool[i].mssSL    = g_TriggerTrend.mssSLSwing;

        if (InpDebugLog)
          PrintFormat("[FVG #%d] TRIGGERED | MSS %s entry=%.5f SL=%.5f @ %s",
            g_FVGPool[i].id,
            (g_TriggerTrend.lastMssBreak == DIR_UP) ? "▲" : "▼",
            g_FVGPool[i].mssEntry, g_FVGPool[i].mssSL,
            TimeToString(g_FVGPool[i].mssTime, TIME_MINUTES));
        continue;
      }

      // ── 5. TOUCHED lifetime expire ──────────────────────────────────
      //   v4.3: Dùng chung InpFVGMaxAliveMin cho cả PENDING và TOUCHED.
      //   Tính từ createdTime (không phải touchTime) → FVG sống tối đa 72h.
      //   Không dùng InpTriggerMaxBars nữa (quá ngắn, miss entry).
      //
      int ageMin = (int)((TimeCurrent() - g_FVGPool[i].createdTime) / 60);
      if (ageMin > InpFVGMaxAliveMin)                  // Quá lifetime
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 0;                    // Case0 = expired
        g_FVGPool[i].usedTime = TimeCurrent();

        if (g_ActiveFVGIdx >= 0
            && g_FVGPool[g_ActiveFVGIdx].id == g_FVGPool[i].id)
          g_ActiveFVGIdx = -1;

        if (InpDebugLog)
          PrintFormat("[FVG #%d] TOUCHED EXPIRED (age=%dmin > %d) → USED",
            g_FVGPool[i].id, ageMin, InpFVGMaxAliveMin);
      }
    }
  }
}

//+------------------------------------------------------------------+
//|  SECTION 7B – ORDER PLAN & EXECUTION                             |
//|                                                                  |
//|  v4: Entry = MSS broken keyLevel (tH0 hoặc tL0)                |
//|       SL   = swing extreme sóng hồi (capture lúc MSS)          |
//|       TP   = Entry ± InpRiskReward * |Entry - SL|              |
//+------------------------------------------------------------------+

double CalcLotFromRisk(double entry, double sl)
{
  double balance    = AccountInfoDouble(ACCOUNT_BALANCE);   // Balance hiện tại
  double riskMoney  = balance * InpRiskPercent / 100.0;     // Số tiền chấp nhận mất (VD: 1% of 10000 = 100)
  double slPips     = MathAbs(entry - sl) / _Point;         // SL tính bằng points (VD: 50 points)
  if (slPips < 1) return 0;                                 // SL quá nhỏ → invalid

  double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); // Giá trị 1 tick/lot
  double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);  // Kích thước 1 tick
  if (tickValue <= 0 || tickSize <= 0) return 0;            // Broker data invalid

  double pipValue   = tickValue * (_Point / tickSize);      // Giá trị 1 point cho 1 lot
  double rawLot     = riskMoney / (slPips * pipValue);      // Lot = riskMoney / (points × value/point)

  double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);  // VD: 0.01
  double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);  // VD: 100.0
  double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); // VD: 0.01
  if (lotStep <= 0) lotStep = 0.01;                         // Fallback

  rawLot = MathFloor(rawLot / lotStep) * lotStep;           // Làm tròn xuống theo lotStep
  rawLot = MathMax(minLot, MathMin(maxLot, rawLot));        // Clamp trong [min, max]
  return NormalizeDouble(rawLot, 2);                        // Trả về lot 2 chữ số thập phân
}

bool BuildOrderPlan(int fvgId, MarketDir dir, double mssEntry, double mssSL)
{
  ZeroMemory(g_OrderPlan);                             // Reset plan cũ

  // v4.3: Entry + SL đã capture trong FVG record khi triggered
  double entry = NormalizeDouble(mssEntry, _Digits);   // tH0 (buy) hoặc tL0 (sell)
  double sl = mssSL;                                   // tL0 (buy) hoặc tH0 (sell)

  if (entry <= 0 || sl <= 0) return false;             // Data invalid → không đặt lệnh

  double tp;
  if (dir == DIR_UP)                                   // ── BUY LIMIT setup ──
  {
    if (sl >= entry) return false;                     // SL phải dưới entry cho buy
    sl = NormalizeDouble(sl - 2 * _Point, _Digits);    // Buffer 2 points dưới swing low
    double riskDist = entry - sl;                      // Khoảng cách risk (points)
    tp = NormalizeDouble(entry + InpRiskReward * riskDist, _Digits); // TP = entry + 2R (mặc định)
  }
  else                                                 // ── SELL LIMIT setup ──
  {
    if (sl <= entry) return false;                     // SL phải trên entry cho sell
    sl = NormalizeDouble(sl + 2 * _Point, _Digits);    // Buffer 2 points trên swing high
    double riskDist = sl - entry;                      // Khoảng cách risk (points)
    tp = NormalizeDouble(entry - InpRiskReward * riskDist, _Digits); // TP = entry - 2R
  }

  double lot = CalcLotFromRisk(entry, sl);             // Tính lot từ risk% và SL distance
  if (lot <= 0) return false;                          // Lot invalid → skip

  g_OrderPlan.valid       = true;                      // Plan sẵn sàng
  g_OrderPlan.direction   = (dir == DIR_UP) ? 1 : -1;  // +1=buy, -1=sell
  g_OrderPlan.entry       = entry;                     // Giá đặt limit order
  g_OrderPlan.stopLoss    = sl;                        // SL đã có buffer
  g_OrderPlan.takeProfit  = tp;                        // TP theo R:R ratio
  g_OrderPlan.lot         = lot;                       // Lot size theo risk management
  g_OrderPlan.parentFVGId = fvgId;                     // Link về FVG gốc

  if (InpDebugLog)
    PrintFormat("[ORDER PLAN] %s | entry=%.5f SL=%.5f TP=%.5f lot=%.2f | FVG#%d",
      (dir == DIR_UP) ? "BUY LIMIT" : "SELL LIMIT",
      entry, sl, tp, lot, fvgId);
  return true;
}

ulong ExecuteLimitOrder()
{
  if (!g_OrderPlan.valid) return 0;

  ENUM_ORDER_TYPE cmd = (g_OrderPlan.direction > 0)
                         ? ORDER_TYPE_BUY_LIMIT
                         : ORDER_TYPE_SELL_LIMIT;

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  // Validate: BUY LIMIT < Ask, SELL LIMIT > Bid
  if (cmd == ORDER_TYPE_BUY_LIMIT && g_OrderPlan.entry >= ask)
  {
    if (InpDebugLog) PrintFormat("[ORDER] BUY LIMIT entry %.5f >= ask %.5f → skip",
      g_OrderPlan.entry, ask);
    return 0;
  }
  if (cmd == ORDER_TYPE_SELL_LIMIT && g_OrderPlan.entry <= bid)
  {
    if (InpDebugLog) PrintFormat("[ORDER] SELL LIMIT entry %.5f <= bid %.5f → skip",
      g_OrderPlan.entry, bid);
    return 0;
  }

  MqlTradeRequest request;
  MqlTradeResult  result;
  ZeroMemory(request);                                 // Init tất cả field = 0
  ZeroMemory(result);

  request.action       = TRADE_ACTION_PENDING;         // Đặt lệnh chờ (không market order)
  request.symbol       = _Symbol;                      // Symbol hiện tại trên chart
  request.volume       = g_OrderPlan.lot;              // Lot size đã tính từ risk%
  request.type         = cmd;                          // BUY_LIMIT hoặc SELL_LIMIT
  request.price        = g_OrderPlan.entry;            // Giá đặt lệnh = MSS keyLevel
  request.sl           = g_OrderPlan.stopLoss;         // SL = swing hồi + buffer
  request.tp           = g_OrderPlan.takeProfit;       // TP = entry ± R:R ratio
  request.deviation    = (ulong)InpSlippage;           // Slippage tối đa (points)
  request.magic        = InpMagicNumber;               // Magic number để identify EA's orders
  request.comment      = StringFormat("ICT#%d", g_OrderPlan.parentFVGId); // Comment link FVG
  request.type_filling = ORDER_FILLING_RETURN;         // Return unfilled volume (broker-safe)
  request.type_time    = ORDER_TIME_GTC;               // Good Till Cancel (không hết hạn)

  if (!OrderSend(request, result))
  {
    PrintFormat("[ORDER] ❌ retcode=%u", result.retcode);
    return 0;
  }
  if (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
  {
    PrintFormat("[ORDER] ❌ rejected retcode=%u: %s", result.retcode, result.comment);
    return 0;
  }

  PrintFormat("[ORDER] ✅ %s #%llu | %.2f @ %.5f SL=%.5f TP=%.5f",
    (cmd == ORDER_TYPE_BUY_LIMIT) ? "BUY_LIM" : "SELL_LIM",
    result.order, g_OrderPlan.lot, g_OrderPlan.entry,
    g_OrderPlan.stopLoss, g_OrderPlan.takeProfit);
  return result.order;
}

//+------------------------------------------------------------------+
//|  SECTION 8 – BEST FVG SELECTOR                                   |
//+------------------------------------------------------------------+

int GetBestActiveFVGIdx()
{
  int bestIdx = -1; datetime bestTime = 0; bool foundTouch = false; // Track best candidate
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;    // Skip FVG đã consumed
    if (g_FVGPool[i].status == FVG_TOUCHED)            // TOUCHED được ưu tiên hơn PENDING
    {
      if (!foundTouch || g_FVGPool[i].createdTime > bestTime) // Mới nhất trong TOUCHED
        { foundTouch = true; bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
    }
    else if (!foundTouch && g_FVGPool[i].createdTime > bestTime) // PENDING: chỉ khi chưa có TOUCHED
      { bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
  }
  return bestIdx;                                      // -1 nếu không có FVG nào khả dụng
}

//+------------------------------------------------------------------+
//|  SECTION 9 – STATE HANDLERS                                      |
//+------------------------------------------------------------------+

void OnStateIdle()
{
  int idx = GetBestActiveFVGIdx();
  if (idx < 0) return;
  g_ActiveFVGIdx = idx;
  if (InpDebugLog)
    PrintFormat("[ACTIVE FVG] #%d %s [%.5f–%.5f] %s",
      g_FVGPool[idx].id, EnumToString(g_FVGPool[idx].direction),
      g_FVGPool[idx].low, g_FVGPool[idx].high, EnumToString(g_FVGPool[idx].status));
  TransitionTo(g_FVGPool[idx].status == FVG_TOUCHED ? EA_WAIT_TRIGGER : EA_WAIT_TOUCH);
}

void OnStateWaitTouch()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int ai = g_ActiveFVGIdx;

  if (g_FVGPool[ai].status == FVG_USED)
    { ResetToIdle(StringFormat("FVG #%d broken/expired", g_FVGPool[ai].id)); return; }
  if (g_FVGPool[ai].status == FVG_TOUCHED)
    { TransitionTo(EA_WAIT_TRIGGER); return; }

  // Kiểm tra FVG mới tốt hơn
  int better = GetBestActiveFVGIdx();
  if (better >= 0 && better != ai)
  {
    bool bTouch = (g_FVGPool[better].status == FVG_TOUCHED);
    bool bNewer = (g_FVGPool[better].createdTime > g_FVGPool[ai].createdTime);
    if (bTouch || bNewer)
    {
      if (InpDebugLog)
        PrintFormat("[SWITCH] FVG #%d → #%d", g_FVGPool[ai].id, g_FVGPool[better].id);
      g_ActiveFVGIdx = better;
      if (bTouch) TransitionTo(EA_WAIT_TRIGGER);
    }
  }
}

void OnStateWaitTrigger()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int ai = g_ActiveFVGIdx;

  if (g_FVGPool[ai].status == FVG_USED)
  {
    if (g_FVGPool[ai].usedCase == 2)                   // Case2 = MSS triggered
    {
      if (InpDebugLog)
        PrintFormat("[ENTRY SIGNAL] FVG #%d %s [%.5f–%.5f] | MSS entry=%.5f SL=%.5f",
          g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
          g_FVGPool[ai].low, g_FVGPool[ai].high,
          g_FVGPool[ai].mssEntry, g_FVGPool[ai].mssSL);

      // v4.3: Build order plan dùng FVG's MSS data (đã capture lúc triggered)
      if (BuildOrderPlan(g_FVGPool[ai].id, g_FVGPool[ai].direction,
                         g_FVGPool[ai].mssEntry, g_FVGPool[ai].mssSL))
      {
        ulong ticket = ExecuteLimitOrder();
        if (ticket > 0)
        {
          g_PendingTicket = ticket;
          g_TradeBarIndex = Bars(_Symbol, InpTriggerTF);
          TransitionTo(EA_IN_TRADE);
        }
        else
          ResetToIdle(StringFormat("FVG #%d order failed", g_FVGPool[ai].id));
      }
      else
        ResetToIdle(StringFormat("FVG #%d invalid plan", g_FVGPool[ai].id));
    }
    else
      ResetToIdle(StringFormat("FVG #%d case%d", g_FVGPool[ai].id, g_FVGPool[ai].usedCase));
    return;
  }
  if (g_FVGPool[ai].status == FVG_PENDING) { TransitionTo(EA_WAIT_TOUCH); return; }
}

void OnStateInTrade()
{
  // ── 1. Pending order còn active? ───────────────────────────────
  if (g_PendingTicket > 0)
  {
    bool foundPending = false;
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
      if (OrderGetTicket(i) == g_PendingTicket) { foundPending = true; break; }
    }

    if (!foundPending)
    {
      // Kiểm tra đã fill → position
      bool posFound = false;
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        ulong pt = PositionGetTicket(i);
        if (pt > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
            && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
          posFound = true;
          g_PendingTicket = 0;                         // Filled
          if (InpDebugLog) PrintFormat("[TRADE] Filled → position #%llu", pt);
          break;
        }
      }

      if (!posFound)
      {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());

        // Cancelled?
        bool cancelled = false;
        for (int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
          ulong ht = HistoryOrderGetTicket(i);
          if (ht == g_PendingTicket)
          {
            long st = HistoryOrderGetInteger(ht, ORDER_STATE);
            if (st == ORDER_STATE_CANCELED || st == ORDER_STATE_EXPIRED || st == ORDER_STATE_REJECTED)
              cancelled = true;
            break;
          }
        }
        if (cancelled) { ResetToIdle("order cancelled"); return; }

        // Position closed?
        bool closed = false;
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
          ulong dt = HistoryDealGetTicket(i);
          if (HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber
              && HistoryDealGetString(dt, DEAL_SYMBOL) == _Symbol
              && HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
          {
            double profit = HistoryDealGetDouble(dt, DEAL_PROFIT);
            if (InpDebugLog) PrintFormat("[TRADE] Closed | profit=%.2f", profit);
            closed = true; break;
          }
        }
        ResetToIdle(closed ? "trade closed" : "order lost");
        return;
      }
    }
    return;                                            // Pending alive → wait
  }

  // ── 2. Track position ──────────────────────────────────────────
  bool hasPos = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong pt = PositionGetTicket(i);
    if (pt > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
        && PositionGetString(POSITION_SYMBOL) == _Symbol)
    { hasPos = true; break; }
  }
  if (!hasPos) ResetToIdle("position closed");
}

//+------------------------------------------------------------------+
//|  SECTION 10 – STATE MACHINE RUNNER                               |
//+------------------------------------------------------------------+

void RunStateMachine()
{
  UpdateFVGStatuses();                                 // Cập nhật trạng thái FVG pool (mỗi tick)
  ScanAndRegisterFVGs();                               // Scan H1 bars cho FVG mới (mỗi bar H1)
  switch (g_State)                                     // Dispatch theo state hiện tại
  {
    case EA_IDLE:         OnStateIdle();        break;  // Tìm FVG tốt nhất → WAIT_TOUCH/TRIGGER
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;  // Chờ giá retrace vào FVG
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;  // Chờ M5 MSS → đặt limit order
    case EA_IN_TRADE:     OnStateInTrade();     break;  // Track pending/position → close
  }
}

//+------------------------------------------------------------------+
//|  SECTION 11 – DRAWING                                            |
//+------------------------------------------------------------------+

void DrawOneSwingPoint(
  string prefix, ENUM_TIMEFRAMES tf,
  string tag, bool isHigh, int barIdx, double price,
  color clr, bool isKL, int arrowSz = 2, int fontSize = 8)
{
  string arrN = prefix + "ARR_" + tag;
  string txtN = prefix + "TXT_" + tag;
  string klN  = prefix + "KL_"  + tag;
  datetime t  = iTime(_Symbol, tf, barIdx);

  if (ObjectFind(0, arrN) < 0) ObjectCreate(0, arrN, OBJ_ARROW, 0, t, price);
  ObjectSetInteger(0, arrN, OBJPROP_ARROWCODE, isHigh ? 234 : 233);
  ObjectSetInteger(0, arrN, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrN, OBJPROP_WIDTH,     arrowSz);
  ObjectSetInteger(0, arrN, OBJPROP_ANCHOR,    isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
  ObjectMove(0, arrN, 0, t, price);

  double rng  = iHigh(_Symbol, tf, barIdx) - iLow(_Symbol, tf, barIdx);
  double txtY = isHigh ? price + rng * 0.3 : price - rng * 0.3;
  if (ObjectFind(0, txtN) < 0) ObjectCreate(0, txtN, OBJ_TEXT, 0, t, txtY);
  ObjectMove(0, txtN, 0, t, txtY);
  ObjectSetString (0, txtN, OBJPROP_TEXT,    tag);
  ObjectSetInteger(0, txtN, OBJPROP_COLOR,   clr);
  ObjectSetInteger(0, txtN, OBJPROP_FONTSIZE, fontSize);
  ObjectSetInteger(0, txtN, OBJPROP_ANCHOR,  isHigh ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

  if (isKL)
  {
    datetime tEnd = iTime(_Symbol, tf, 0);
    if (ObjectFind(0, klN) < 0) ObjectCreate(0, klN, OBJ_TREND, 0, t, price, tEnd, price);
    ObjectSetInteger(0, klN, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, klN, OBJPROP_STYLE,     STYLE_DASH);
    ObjectSetInteger(0, klN, OBJPROP_WIDTH,     1);
    ObjectSetInteger(0, klN, OBJPROP_RAY_RIGHT, false);
    ObjectMove(0, klN, 0, t, price);
    ObjectMove(0, klN, 1, tEnd, price);
  }
  else ObjectDelete(0, klN);
}

void DrawMiddleSwingPoints()
{
  if (!InpDebugDraw) return;
  if (g_MiddleTrend.idxH0 <= 0 || g_MiddleTrend.idxH1 <= 0 ||
      g_MiddleTrend.idxL0 <= 0 || g_MiddleTrend.idxL1 <= 0)
    { ObjectsDeleteAll(0, SW_PREFIX); return; }

  bool isUp   = (g_MiddleTrend.trend == DIR_UP);
  bool isDown = (g_MiddleTrend.trend == DIR_DOWN);
  DrawOneSwingPoint(SW_PREFIX, InpMiddleTF, "H0", true,  g_MiddleTrend.idxH0, g_MiddleTrend.h0, clrAqua,       isDown, 2, 8);
  DrawOneSwingPoint(SW_PREFIX, InpMiddleTF, "H1", true,  g_MiddleTrend.idxH1, g_MiddleTrend.h1, C'0,140,160',  false,  2, 8);
  DrawOneSwingPoint(SW_PREFIX, InpMiddleTF, "L0", false, g_MiddleTrend.idxL0, g_MiddleTrend.l0, clrYellow,     isUp,   2, 8);
  DrawOneSwingPoint(SW_PREFIX, InpMiddleTF, "L1", false, g_MiddleTrend.idxL1, g_MiddleTrend.l1, C'160,140,0',  false,  2, 8);
}

void DrawTriggerSwingPoints()
{
  if (!InpDebugDraw) return;
  if (g_TriggerTrend.idxH0 <= 0 || g_TriggerTrend.idxH1 <= 0 ||
      g_TriggerTrend.idxL0 <= 0 || g_TriggerTrend.idxL1 <= 0)
    { ObjectsDeleteAll(0, TS_PREFIX); return; }

  bool isUp   = (g_TriggerTrend.trend == DIR_UP);
  bool isDown = (g_TriggerTrend.trend == DIR_DOWN);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "tH0", true,  g_TriggerTrend.idxH0, g_TriggerTrend.h0, C'180,100,255', isDown, 1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "tH1", true,  g_TriggerTrend.idxH1, g_TriggerTrend.h1, C'100,60,160',  false,  1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "tL0", false, g_TriggerTrend.idxL0, g_TriggerTrend.l0, C'255,160,40',  isUp,   1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "tL1", false, g_TriggerTrend.idxL1, g_TriggerTrend.l1, C'160,100,20',  false,  1, 7);
}

//----------------------------------------------------------------------
// DrawMSSMarker – MSS arrow + label + keyLevel line
//----------------------------------------------------------------------
void DrawMSSMarker(
  string mssId, ENUM_TIMEFRAMES tf,
  datetime mssTime, double mssLevel, MarketDir mssBreak)
{
  if (!InpDebugDraw || mssTime == 0) return;

  string arrN = MSS_PREFIX + mssId + "_ARR";
  string lblN = MSS_PREFIX + mssId + "_LBL";
  string klN  = MSS_PREFIX + mssId + "_KL";

  bool   isBull = (mssBreak == DIR_UP);
  color  clr    = isBull ? clrLime : clrTomato;

  int shift = MyBarShift(_Symbol, tf, mssTime);
  if (shift < 0) return;
  double closeAtMss = iClose(_Symbol, tf, shift);

  // Arrow tại close cây nến MSS
  if (ObjectFind(0, arrN) < 0)
    ObjectCreate(0, arrN, OBJ_ARROW, 0, mssTime, closeAtMss);
  ObjectSetInteger(0, arrN, OBJPROP_ARROWCODE, isBull ? 233 : 234);
  ObjectSetInteger(0, arrN, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrN, OBJPROP_WIDTH,     2);
  ObjectSetInteger(0, arrN, OBJPROP_ANCHOR,    isBull ? ANCHOR_TOP : ANCHOR_BOTTOM);
  ObjectMove(0, arrN, 0, mssTime, closeAtMss);

  // Label "▲MSS" / "▼MSS"
  double rng  = iHigh(_Symbol, tf, shift) - iLow(_Symbol, tf, shift);
  double lblY = isBull ? closeAtMss - rng * 0.4 : closeAtMss + rng * 0.4;
  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(0, lblN, OBJ_TEXT, 0, mssTime, lblY);
  ObjectMove(0, lblN, 0, mssTime, lblY);
  ObjectSetString (0, lblN, OBJPROP_TEXT,    isBull ? "▲MSS" : "▼MSS");
  ObjectSetInteger(0, lblN, OBJPROP_COLOR,   clr);
  ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR,  isBull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

  // Dotted line tại broken keyLevel
  datetime tEnd = iTime(_Symbol, tf, 0);
  if (ObjectFind(0, klN) < 0)
    ObjectCreate(0, klN, OBJ_TREND, 0, mssTime, mssLevel, tEnd, mssLevel);
  ObjectSetInteger(0, klN, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, klN, OBJPROP_STYLE,     STYLE_DOT);
  ObjectSetInteger(0, klN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, klN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, klN, 0, mssTime, mssLevel);
  ObjectMove(0, klN, 1, tEnd,    mssLevel);
}

void DrawMSSMarkers()
{
  if (!InpDebugDraw) return;

  // v4.3: CHỈ vẽ MSS cho FVG đã triggered (case2)
  // Không vẽ MSS riêng lẻ từ global context nữa
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status != FVG_USED || g_FVGPool[i].usedCase != 2) continue; // Chỉ case2
    if (g_FVGPool[i].mssTime == 0) continue;           // Không có MSS data

    string tid = "T_" + IntegerToString(g_FVGPool[i].id); // Dùng FVG ID làm MSS object ID
    DrawMSSMarker(tid, InpTriggerTF,
      g_FVGPool[i].mssTime,                            // Thời gian cây nến MSS
      g_FVGPool[i].mssEntry,                           // Swing bị phá (entry level)
      g_FVGPool[i].direction == DIR_UP ? DIR_UP : DIR_DOWN); // Hướng MSS = hướng FVG
  }
}

//----------------------------------------------------------------------
// DrawOrderVisualization – TradingView-style Entry/SL/TP
//----------------------------------------------------------------------
void DrawOrderVisualization()
{
  if (!InpDebugDraw) return;

  string tpZoneN  = ORD_PREFIX + "TP_ZONE";
  string slZoneN  = ORD_PREFIX + "SL_ZONE";
  string entLineN = ORD_PREFIX + "ENTRY_LINE";
  string slLineN  = ORD_PREFIX + "SL_LINE";
  string tpLineN  = ORD_PREFIX + "TP_LINE";
  string entLblN  = ORD_PREFIX + "ENTRY_LBL";
  string slLblN   = ORD_PREFIX + "SL_LBL";
  string tpLblN   = ORD_PREFIX + "TP_LBL";
  string infoLblN = ORD_PREFIX + "INFO_LBL";

  if (!g_OrderPlan.valid || g_State == EA_IDLE)
  {
    ObjectDelete(0, tpZoneN);  ObjectDelete(0, slZoneN);
    ObjectDelete(0, entLineN); ObjectDelete(0, slLineN);  ObjectDelete(0, tpLineN);
    ObjectDelete(0, entLblN);  ObjectDelete(0, slLblN);   ObjectDelete(0, tpLblN);
    ObjectDelete(0, infoLblN);
    return;
  }

  bool   isBuy = (g_OrderPlan.direction > 0);
  double entry = g_OrderPlan.entry;
  double sl    = g_OrderPlan.stopLoss;
  double tp    = g_OrderPlan.takeProfit;

  datetime tStart = (g_TriggerTrend.lastMssTime > 0) ? g_TriggerTrend.lastMssTime : iTime(_Symbol, InpTriggerTF, 20);
  datetime tEnd   = iTime(_Symbol, InpTriggerTF, 0) + PeriodSeconds(InpTriggerTF) * 25;

  double slPips = MathAbs(entry - sl) / _Point;
  double tpPips = MathAbs(tp - entry) / _Point;
  double rr     = (slPips > 0) ? tpPips / slPips : 0;

  color entryClr = isBuy ? C'33,150,243' : C'255,152,0';
  color tpFill   = C'15,65,35';
  color slFill   = C'85,15,15';
  color tpClr    = C'38,166,91';
  color slClr    = C'229,57,53';

  // TP zone
  double tpTop = isBuy ? tp : entry, tpBot = isBuy ? entry : tp;
  if (ObjectFind(0, tpZoneN) < 0) ObjectCreate(0, tpZoneN, OBJ_RECTANGLE, 0, tStart, tpTop, tEnd, tpBot);
  ObjectSetInteger(0, tpZoneN, OBJPROP_COLOR, tpFill); ObjectSetInteger(0, tpZoneN, OBJPROP_FILL, true);
  ObjectSetInteger(0, tpZoneN, OBJPROP_BACK, true);
  ObjectMove(0, tpZoneN, 0, tStart, tpTop); ObjectMove(0, tpZoneN, 1, tEnd, tpBot);

  // SL zone
  double slTop = isBuy ? entry : sl, slBot = isBuy ? sl : entry;
  if (ObjectFind(0, slZoneN) < 0) ObjectCreate(0, slZoneN, OBJ_RECTANGLE, 0, tStart, slTop, tEnd, slBot);
  ObjectSetInteger(0, slZoneN, OBJPROP_COLOR, slFill); ObjectSetInteger(0, slZoneN, OBJPROP_FILL, true);
  ObjectSetInteger(0, slZoneN, OBJPROP_BACK, true);
  ObjectMove(0, slZoneN, 0, tStart, slTop); ObjectMove(0, slZoneN, 1, tEnd, slBot);

  // Entry line
  if (ObjectFind(0, entLineN) < 0) ObjectCreate(0, entLineN, OBJ_TREND, 0, tStart, entry, tEnd, entry);
  ObjectSetInteger(0, entLineN, OBJPROP_COLOR, entryClr); ObjectSetInteger(0, entLineN, OBJPROP_STYLE, STYLE_SOLID);
  ObjectSetInteger(0, entLineN, OBJPROP_WIDTH, 2); ObjectSetInteger(0, entLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, entLineN, 0, tStart, entry); ObjectMove(0, entLineN, 1, tEnd, entry);

  // TP line
  if (ObjectFind(0, tpLineN) < 0) ObjectCreate(0, tpLineN, OBJ_TREND, 0, tStart, tp, tEnd, tp);
  ObjectSetInteger(0, tpLineN, OBJPROP_COLOR, tpClr); ObjectSetInteger(0, tpLineN, OBJPROP_STYLE, STYLE_DASH);
  ObjectSetInteger(0, tpLineN, OBJPROP_WIDTH, 1); ObjectSetInteger(0, tpLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, tpLineN, 0, tStart, tp); ObjectMove(0, tpLineN, 1, tEnd, tp);

  // SL line
  if (ObjectFind(0, slLineN) < 0) ObjectCreate(0, slLineN, OBJ_TREND, 0, tStart, sl, tEnd, sl);
  ObjectSetInteger(0, slLineN, OBJPROP_COLOR, slClr); ObjectSetInteger(0, slLineN, OBJPROP_STYLE, STYLE_DASH);
  ObjectSetInteger(0, slLineN, OBJPROP_WIDTH, 1); ObjectSetInteger(0, slLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, slLineN, 0, tStart, sl); ObjectMove(0, slLineN, 1, tEnd, sl);

  // Labels
  datetime lblT = tEnd;

  string eTxt = StringFormat("%s %s | %.2f lot", isBuy?"▶ BUY LIM":"▶ SELL LIM", DoubleToString(entry,_Digits), g_OrderPlan.lot);
  if (ObjectFind(0, entLblN) < 0) ObjectCreate(0, entLblN, OBJ_TEXT, 0, lblT, entry);
  ObjectMove(0, entLblN, 0, lblT, entry); ObjectSetString(0, entLblN, OBJPROP_TEXT, eTxt);
  ObjectSetInteger(0, entLblN, OBJPROP_COLOR, entryClr); ObjectSetInteger(0, entLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, entLblN, OBJPROP_ANCHOR, ANCHOR_LEFT);

  string tTxt = StringFormat("◎ TP %s +%.0fp (%.1fR)", DoubleToString(tp,_Digits), tpPips, rr);
  if (ObjectFind(0, tpLblN) < 0) ObjectCreate(0, tpLblN, OBJ_TEXT, 0, lblT, tp);
  ObjectMove(0, tpLblN, 0, lblT, tp); ObjectSetString(0, tpLblN, OBJPROP_TEXT, tTxt);
  ObjectSetInteger(0, tpLblN, OBJPROP_COLOR, tpClr); ObjectSetInteger(0, tpLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, tpLblN, OBJPROP_ANCHOR, isBuy?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);

  string sTxt = StringFormat("✕ SL %s -%.0fp", DoubleToString(sl,_Digits), slPips);
  if (ObjectFind(0, slLblN) < 0) ObjectCreate(0, slLblN, OBJ_TEXT, 0, lblT, sl);
  ObjectMove(0, slLblN, 0, lblT, sl); ObjectSetString(0, slLblN, OBJPROP_TEXT, sTxt);
  ObjectSetInteger(0, slLblN, OBJPROP_COLOR, slClr); ObjectSetInteger(0, slLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, slLblN, OBJPROP_ANCHOR, isBuy?ANCHOR_LEFT_UPPER:ANCHOR_LEFT_LOWER);

  string iTxt = StringFormat("Risk %.1f%% | %.0f:%.0f pips | %.1fR", InpRiskPercent, slPips, tpPips, rr);
  if (ObjectFind(0, infoLblN) < 0) ObjectCreate(0, infoLblN, OBJ_TEXT, 0, lblT, (entry+sl)/2.0);
  ObjectMove(0, infoLblN, 0, lblT, (entry+sl)/2.0); ObjectSetString(0, infoLblN, OBJPROP_TEXT, iTxt);
  ObjectSetInteger(0, infoLblN, OBJPROP_COLOR, C'160,160,160'); ObjectSetInteger(0, infoLblN, OBJPROP_FONTSIZE, 7);
  ObjectSetInteger(0, infoLblN, OBJPROP_ANCHOR, ANCHOR_LEFT);
}

//----------------------------------------------------------------------
// DrawOneFVGRecord – MiddleTF FVG rectangle + midline + label
//----------------------------------------------------------------------
void DrawOneFVGRecord(int idx)
{
  if (!InpDebugDraw || idx < 0 || idx >= g_FVGCount) return;

  string sid   = IntegerToString(g_FVGPool[idx].id);
  string rectN = FVGP_PREFIX + "RECT_" + sid;
  string midN  = FVGP_PREFIX + "MID_"  + sid;
  string lblN  = FVGP_PREFIX + "LBL_"  + sid;

  datetime rectEnd;
  if (g_FVGPool[idx].status == FVG_PENDING)
    rectEnd = iTime(_Symbol, InpMiddleTF, 0);
  else if (g_FVGPool[idx].touchTime > 0)
  {
    int shift = MyBarShift(_Symbol, InpTriggerTF, g_FVGPool[idx].touchTime);
    rectEnd   = (shift >= 0) ? iTime(_Symbol, InpTriggerTF, shift) : iTime(_Symbol, InpMiddleTF, 0);
  }
  else
  {
    int shift = MyBarShift(_Symbol, InpMiddleTF, g_FVGPool[idx].usedTime);
    rectEnd   = (shift >= 0) ? iTime(_Symbol, InpMiddleTF, shift) : iTime(_Symbol, InpMiddleTF, 0);
  }
  if (rectEnd <= g_FVGPool[idx].createdTime) rectEnd = iTime(_Symbol, InpMiddleTF, 0);

  color fillColor;
  if      (g_FVGPool[idx].status == FVG_PENDING) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,50,110'  : C'90,25,0';
  else if (g_FVGPool[idx].status == FVG_TOUCHED) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,120,220' : C'220,75,0';
  else if (g_FVGPool[idx].usedCase == 2)          fillColor = C'0,100,0';
  else if (g_FVGPool[idx].usedCase == 1)          fillColor = C'70,0,0';
  else                                             fillColor = C'50,50,50';

  if (ObjectFind(0, rectN) < 0)
    ObjectCreate(0, rectN, OBJ_RECTANGLE, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high, rectEnd, g_FVGPool[idx].low);
  ObjectSetInteger(0, rectN, OBJPROP_COLOR, fillColor); ObjectSetInteger(0, rectN, OBJPROP_FILL, true);
  ObjectSetInteger(0, rectN, OBJPROP_BACK, true);
  ObjectMove(0, rectN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectMove(0, rectN, 1, rectEnd, g_FVGPool[idx].low);

  color midColor = (g_FVGPool[idx].status == FVG_USED) ? C'60,60,60' : clrSilver;
  if (ObjectFind(0, midN) < 0)
    ObjectCreate(0, midN, OBJ_TREND, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].mid, rectEnd, g_FVGPool[idx].mid);
  ObjectSetInteger(0, midN, OBJPROP_COLOR, midColor); ObjectSetInteger(0, midN, OBJPROP_STYLE, STYLE_DOT);
  ObjectSetInteger(0, midN, OBJPROP_WIDTH, 1); ObjectSetInteger(0, midN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, midN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].mid);
  ObjectMove(0, midN, 1, rectEnd, g_FVGPool[idx].mid);

  string sym = (g_FVGPool[idx].direction == DIR_UP) ? "▲" : "▼";
  string stTxt = "";
  if      (g_FVGPool[idx].status == FVG_TOUCHED)  stTxt = " [T]";
  else if (g_FVGPool[idx].usedCase == 2)           stTxt = " [TRIG]";
  else if (g_FVGPool[idx].usedCase == 1)           stTxt = " [BRK]";
  else if (g_FVGPool[idx].status == FVG_USED)      stTxt = " [EXP]";

  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(0, lblN, OBJ_TEXT, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectMove(0, lblN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectSetString(0, lblN, OBJPROP_TEXT, StringFormat("FVG#%d %s%s", g_FVGPool[idx].id, sym, stTxt));
  ObjectSetInteger(0, lblN, OBJPROP_COLOR, fillColor); ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
}

void DrawFVGPool()
{
  if (!InpDebugDraw) return;
  for (int i = 0; i < g_FVGCount; i++) DrawOneFVGRecord(i);
}

//----------------------------------------------------------------------
// DrawContextDebug – top-left info panel
//----------------------------------------------------------------------
void DrawContextDebug()
{
  if (!InpDebugDraw) return;

  #define LBL(name,txt,y,clr)                                           \
    if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);     \
    ObjectSetInteger(0,name,OBJPROP_CORNER,    CORNER_LEFT_UPPER);      \
    ObjectSetInteger(0,name,OBJPROP_XDISTANCE, 10);                     \
    ObjectSetInteger(0,name,OBJPROP_YDISTANCE, y);                      \
    ObjectSetInteger(0,name,OBJPROP_FONTSIZE,  9);                      \
    ObjectSetInteger(0,name,OBJPROP_COLOR,     clr);                    \
    ObjectSetString (0,name,OBJPROP_TEXT,      txt);

  LBL("DBG_HDR",  "── ICT EA v4.3 ──", 10, clrSilver)

  color cB = (g_Bias.bias==BIAS_UP)?clrLime:(g_Bias.bias==BIAS_DOWN)?clrTomato:(g_Bias.bias==BIAS_SIDEWAY)?clrOrange:clrGray;
  LBL("DBG_BIAS", StringFormat("Bias : %s", EnumToString(g_Bias.bias)), 34, cB)

  color cMT = (g_MiddleTrend.trend==DIR_UP)?clrLime:(g_MiddleTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_MT", StringFormat("H1   : %s  KL=%.5f", EnumToString(g_MiddleTrend.trend), g_MiddleTrend.keyLevel), 58, cMT)

  color cTT = (g_TriggerTrend.trend==DIR_UP)?clrLime:(g_TriggerTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_TT", StringFormat("M5   : %s  KL=%.5f", EnumToString(g_TriggerTrend.trend), g_TriggerTrend.keyLevel), 82, cTT)

  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount   // Có active FVG
      && g_FVGPool[g_ActiveFVGIdx].usedCase == 2            // Đã triggered
      && g_FVGPool[g_ActiveFVGIdx].mssTime > 0)             // Có MSS data
  {
    int ai = g_ActiveFVGIdx;
    color cM = (g_FVGPool[ai].direction==DIR_UP)?clrLime:clrTomato;
    LBL("DBG_MSS", StringFormat("MSS  : %s entry=%.5f SL=%.5f @ %s (FVG#%d)",
      (g_FVGPool[ai].direction==DIR_UP)?"▲":"▼",
      g_FVGPool[ai].mssEntry, g_FVGPool[ai].mssSL,
      TimeToString(g_FVGPool[ai].mssTime, TIME_MINUTES),
      g_FVGPool[ai].id), 106, cM)
  }
  else ObjectDelete(0,"DBG_MSS");

  double lostPct = g_DailyRisk.startBalance > 0
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance) / g_DailyRisk.startBalance * 100.0 : 0.0;
  color cR = g_DailyRisk.limitHit?clrRed:(lostPct>InpMaxDailyLossPct*0.7?clrOrange:clrLime);
  LBL("DBG_RISK", StringFormat("Risk : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct), 130, cR)

  color cS = (g_State==EA_IDLE)?clrSilver:(g_State==EA_WAIT_TOUCH)?clrOrange:(g_State==EA_WAIT_TRIGGER)?clrYellow:clrLime;
  LBL("DBG_ST", StringFormat("State: %s", EnumToString(g_State)), 154, cS)

  if (g_BlockReason != BLOCK_NONE)
    { LBL("DBG_BLK", StringFormat("Block: %s", EnumToString(g_BlockReason)), 178, clrTomato) }
  else ObjectDelete(0,"DBG_BLK");

  int nP=0,nT=0,nU=0;
  for(int i=0;i<g_FVGCount;i++)
    { if(g_FVGPool[i].status==FVG_PENDING) nP++; else if(g_FVGPool[i].status==FVG_TOUCHED) nT++; else nU++; }
  LBL("DBG_POOL", StringFormat("Pool : P=%d T=%d U=%d (%d/%d)", nP,nT,nU,g_FVGCount,MAX_FVG_POOL), 202, clrDodgerBlue)

  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount)
  {
    int ai = g_ActiveFVGIdx;
    LBL("DBG_ACT", StringFormat("Act  : #%d %s [%.5f–%.5f] %s",
      g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
      g_FVGPool[ai].low, g_FVGPool[ai].high, EnumToString(g_FVGPool[ai].status)), 226, clrDeepSkyBlue)
  }
  else ObjectDelete(0,"DBG_ACT");

  if (g_PendingTicket > 0 && g_OrderPlan.valid)
  {
    LBL("DBG_ORD", StringFormat("Order: %s #%llu @ %.5f SL=%.5f TP=%.5f",
      (g_OrderPlan.direction>0)?"BUY":"SELL", g_PendingTicket,
      g_OrderPlan.entry, g_OrderPlan.stopLoss, g_OrderPlan.takeProfit), 250, clrGold)
  }
  else ObjectDelete(0,"DBG_ORD");

  #undef LBL
  ChartRedraw(0);
}

//----------------------------------------------------------------------
// DrawVisuals – master draw function
//----------------------------------------------------------------------
void DrawVisuals()
{
  DrawMiddleSwingPoints();     // H1 swing H0/H1/L0/L1 + keyLevel dashed line
  DrawTriggerSwingPoints();    // M5 swing tH0/tH1/tL0/tL1 + keyLevel dashed line
  DrawMSSMarkers();            // MSS markers (chỉ cho triggered FVGs)
  DrawFVGPool();               // MiddleTF FVG rectangles (PENDING=dark, TOUCHED=bright, USED=status color)
  DrawOrderVisualization();    // TradingView-style: TP zone (green) + SL zone (red) + entry/SL/TP lines
  DrawContextDebug();          // Top-left info panel: bias, trend, MSS, risk, state, pool, order
}

//+------------------------------------------------------------------+
//|  SECTION 12 – EA LIFECYCLE                                       |
//+------------------------------------------------------------------+

int OnInit()
{
  ZeroMemory(g_Bias); ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);
  ZeroMemory(g_DailyRisk); ZeroMemory(g_OrderPlan);
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);
  g_FVGCount = 0; g_NextFVGId = 0;
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1; g_PendingTicket = 0;
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;

  UpdateAllContexts();
  ScanAndRegisterFVGs();
  DrawVisuals();

  PrintFormat("✅ ICT EA v4.3 | Bias=%s | H1=%s | M5=%s | Pool=%d",
    EnumToString(g_Bias.bias), EnumToString(g_MiddleTrend.trend),
    EnumToString(g_TriggerTrend.trend), g_FVGCount);
  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts();                                 // 1. Cập nhật D1 bias, H1/M5 swing (MSS nếu WAIT_TRIGGER)
  if (EvaluateGuards())                                // 2. Check guards (session, risk, alignment)
    RunStateMachine();                                 //    Pass → chạy state machine
  else if (g_State != EA_IDLE)                         //    Fail + đang active → reset
    ResetToIdle(EnumToString(g_BlockReason));           //    Log lý do block rồi về IDLE
  if (InpDebugDraw) DrawVisuals();                     // 3. Vẽ chart objects (nếu enabled)
}

void OnDeinit(const int reason)
{
  ObjectsDeleteAll(0, SW_PREFIX);                      // Xóa H1 swing objects (tạm thời)
  ObjectsDeleteAll(0, TS_PREFIX);                      // Xóa M5 swing objects (tạm thời)
  ObjectsDeleteAll(0, DBG_PREFIX);                     // Xóa debug panel (giữ lại: FVGP_, MSS_, ORD_)
  ChartRedraw(0);                                      // Force redraw chart
  PrintFormat("ICT EA v4.3 deinit | reason=%d | pool=%d", reason, g_FVGCount);
}