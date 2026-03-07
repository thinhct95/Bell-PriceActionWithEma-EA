//+------------------------------------------------------------------+
//| ICT EA – FVG Edition  (MQL5)  v3.0                               |
//| Architecture : BiasTF(D1) + MiddleTF(H1) + TriggerTF(M5)       |
//| State Machine: IDLE → WAIT_TOUCH → WAIT_TRIGGER → IN_TRADE      |
//|                                                                  |
//| FVG lifecycle:                                                   |
//|   PENDING  → hình thành, chưa touch                             |
//|   TOUCHED  → giá chạm vào gap (bid inside)                      |
//|   USED     → case0=expired / case1=broken / case2=triggered      |
//|                                                                  |
//| MSS (Market Structure Shift) – v3 definition:                    |
//|   MSS hợp lệ = Liquidity Sweep + Structure Break                |
//|                                                                  |
//|   Bullish MSS (MiddleTF UP):                                    |
//|     1. Sweep: wick < L0, close > L0 (quét sell-side liq)        |
//|     2. Break: close > H0 (phá vỡ swing high → đảo chiều lên)   |
//|                                                                  |
//|   Bearish MSS (MiddleTF DOWN):                                  |
//|     1. Sweep: wick > H0, close < H0 (quét buy-side liq)        |
//|     2. Break: close < L0 (phá vỡ swing low → đảo chiều xuống)  |
//|                                                                  |
//|   Không có sweep → MSS không hợp lệ, bỏ qua                   |
//|                                                                  |
//| TriggerTF MSS chỉ nhận thuận chiều MiddleTF trend              |
//|                                                                  |
//| Drawing: objects KHÔNG BAO GIỜ bị xóa, chỉ update              |
//+------------------------------------------------------------------+
#property copyright "Bell's ICT EA"
#property version   "3.00"

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

input int    InpSwingRange               = 2;          // Bars each side for swing confirm
input int    InpSwingLookback            = 50;         // MiddleTF swing scan bars
input int    InpTriggerSwingLookback     = 30;         // TriggerTF swing scan bars

input int    InpFVGMaxAliveMin           = 4320;       // Max PENDING lifetime (min) = 72h
input int    InpFVGScanBars              = 50;         // MiddleTF bars to scan for FVGs
input double InpFVGMinBodyPct            = 60.0;       // Mid-candle min body %
input int    InpTriggerMaxBars           = 30;         // Trigger timeout (TriggerTF bars)

input long   InpMagicNumber              = 20250308;   // EA magic number
input int    InpSlippage                 = 5;          // Max slippage (points)

input bool   InpDebugLog                 = true;       // Journal logging
input bool   InpDebugDraw                = true;       // Chart drawing

//====================================================
// ENUMS
//====================================================
enum EAState
{
  EA_IDLE,          // Looking for best FVG
  EA_WAIT_TOUCH,    // Active FVG = PENDING, waiting price entry
  EA_WAIT_TRIGGER,  // Active FVG = TOUCHED, waiting TriggerTF MSS
  EA_IN_TRADE       // Position open
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
  FVG_PENDING,  // Formed, not yet touched
  FVG_TOUCHED,  // Price entered gap zone
  FVG_USED      // Consumed: 0=expired 1=broken 2=triggered
};

//====================================================
// STRUCTS
//====================================================
struct BiasContext
{
  HTFBias  bias;
  double   rangeHigh, rangeLow;
  datetime lastBarTime;
};

//----------------------------------------------------------------------
// TFTrendContext – Swing structure + MSS + associated sweep
//
// v3: MSS hợp lệ yêu cầu có Liquidity Sweep trước đó.
//     Khi MSS được ghi nhận, sweep info cũng được lưu kèm
//     để vẽ cả 2 thành 1 pattern hoàn chỉnh.
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
  datetime  lastMssTime;                 // Open time cây nến break structure
  double    lastMssLevel;                // Key level bị phá (giá break qua)
  MarketDir lastMssBreak;                // DIR_UP = bull MSS, DIR_DOWN = bear MSS

  // ── v3: Sweep đi kèm MSS (chỉ có giá trị khi lastMssTime > 0) ─
  datetime  mssSweepTime;                // Thời gian cây nến sweep
  double    mssSweepLevel;               // Swing level bị quét (L0 hoặc H0)
  double    mssSweepWick;                // Wick extreme (low cho bull, high cho bear)
};

struct FVGRecord
{
  int       id;
  FVGStatus status;
  int       usedCase;                    // 0=expired 1=broken 2=triggered
  MarketDir direction;
  double    high, low, mid;
  datetime  createdTime;
  datetime  touchTime;
  datetime  usedTime;
  MarketDir triggerTrendAtTouch;         // M5 trend tại thời điểm touch
};

struct TriggerFVGRecord
{
  bool      valid;
  MarketDir direction;
  double    high, low, mid;
  datetime  createdTime;
};

struct TriggerContext
{
  bool      valid;
  MarketDir direction;
  double    swingHigh, swingLow;
  int       idxHigh, idxLow;
  double    breakLevel;
};

struct OrderPlan
{
  bool   valid;
  int    direction;                      // +1 buy, -1 sell
  double entry, stopLoss, takeProfit, lot;
  int    parentFVGId;
};

struct DailyRiskContext
{
  double   startBalance, currentBalance;
  datetime dayStartTime;
  bool     limitHit;
};

//----------------------------------------------------------------------
// v3: Liquidity Sweep event (internal tracking, KHÔNG vẽ riêng)
//
// Sweep = wick quét qua swing rồi close lại phía trong:
//   Bullish: low < L0 && close > L0  → quét sell-side liquidity
//   Bearish: high > H0 && close < H0 → quét buy-side liquidity
//
// Sweep chỉ dùng làm prerequisite cho valid MSS.
// Khi MSS xảy ra, sweep info được copy vào TFTrendContext.
//----------------------------------------------------------------------
struct LiqSweepEvent
{
  bool      valid;
  MarketDir direction;                   // DIR_UP = bull sweep, DIR_DOWN = bear
  double    sweptLevel;                  // Swing level bị quét
  double    extremeWick;                 // Wick thực tế (low cho bull, high cho bear)
  datetime  time;                        // Open time cây nến sweep
};

//====================================================
// GLOBALS
//====================================================
EAState          g_State       = EA_IDLE;
BlockReason      g_BlockReason = BLOCK_NONE;

BiasContext      g_Bias;
TFTrendContext   g_MiddleTrend;
TFTrendContext   g_TriggerTrend;
TriggerContext   g_Trigger;
DailyRiskContext g_DailyRisk;

FVGRecord  g_FVGPool[MAX_FVG_POOL];
int        g_FVGCount      = 0;
int        g_NextFVGId     = 0;
int        g_ActiveFVGIdx  = -1;
int        g_TradeBarIndex = -1;

TriggerFVGRecord g_TrigFVG;
OrderPlan        g_OrderPlan;
ulong            g_PendingTicket = 0;

// v3: Sweep tracking (internal, prerequisite cho MSS)
LiqSweepEvent g_LastLiqSweep;

// Chart object name prefixes
const string SW_PREFIX   = "SW_";        // MiddleTF swing arrows/labels
const string TS_PREFIX   = "TS_";        // TriggerTF swing arrows/labels
const string MSS_PREFIX  = "MSS_";       // MSS markers (cả sweep + break)
const string FVGP_PREFIX = "FVGP_";      // MiddleTF FVG rectangles
const string TFVG_PREFIX = "TFVG_";      // TriggerTF FVG rectangles
const string ORD_PREFIX  = "ORD_";       // v3: Order visualization
const string DBG_PREFIX  = "DBG_";       // Debug panel labels

//+------------------------------------------------------------------+
//|  MQL5 HELPER: iBarShift replacement                              |
//+------------------------------------------------------------------+
int MyBarShift(string symbol, ENUM_TIMEFRAMES tf, datetime time, bool exact = false)
{
  datetime arr[];
  int maxCopy = MathMin(Bars(symbol, tf), 5000);       // Giới hạn 5000 bars tránh quá tải
  int copied = CopyTime(symbol, tf, 0, maxCopy, arr);
  if (copied <= 0) return -1;

  for (int i = copied - 1; i >= 0; i--)               // Duyệt từ mới → cũ
  {
    if (arr[i] <= time)
      return copied - 1 - i;                           // Chuyển array index → bar shift
  }
  return exact ? -1 : copied - 1;
}

//+------------------------------------------------------------------+
//|  SECTION 1 – SWING HELPERS                                       |
//+------------------------------------------------------------------+

bool IsSwingHighAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iHigh(_Symbol, tf, i);
  for (int k = 1; k <= InpSwingRange; k++)
    if (iHigh(_Symbol, tf, i-k) >= p || iHigh(_Symbol, tf, i+k) >= p) return false;
  return true;
}

bool IsSwingLowAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iLow(_Symbol, tf, i);
  for (int k = 1; k <= InpSwingRange; k++)
    if (iLow(_Symbol, tf, i-k) <= p || iLow(_Symbol, tf, i+k) <= p) return false;
  return true;
}

bool ScanSwingStructure(
  ENUM_TIMEFRAMES tf, int lookback,
  double &h0, double &h1, int &idxH0, int &idxH1,
  double &l0, double &l1, int &idxL0, int &idxL1)
{
  int maxBar = MathMin(lookback, Bars(_Symbol, tf) - InpSwingRange - 2);
  double highs[2]; int hiIdx[2]; int hc = 0;
  double lows [2]; int loIdx[2]; int lc = 0;

  for (int i = InpSwingRange + 1; i <= maxBar; i++)
  {
    if (hc < 2 && IsSwingHighAt(tf, i)) { highs[hc] = iHigh(_Symbol, tf, i); hiIdx[hc] = i; hc++; }
    if (lc < 2 && IsSwingLowAt (tf, i)) { lows [lc] = iLow (_Symbol, tf, i); loIdx[lc] = i; lc++; }
    if (hc == 2 && lc == 2) break;
  }
  if (hc < 2 || lc < 2) return false;

  h0 = highs[0]; idxH0 = hiIdx[0];
  h1 = highs[1]; idxH1 = hiIdx[1];
  l0 = lows [0]; idxL0 = loIdx[0];
  l1 = lows [1]; idxL1 = loIdx[1];
  return true;
}

void ResolveTrendFromSwings(
  ENUM_TIMEFRAMES tf,
  double h0, double h1, double l0, double l1,
  MarketDir &trend, double &keyLevel)
{
  double c1 = iClose(_Symbol, tf, 1);
  if      (h0 > h1 && l0 > l1 && c1 > l0) { trend = DIR_UP;   keyLevel = l0; }
  else if (h0 < h1 && l0 < l1 && c1 < h0) { trend = DIR_DOWN; keyLevel = h0; }
  else                                      { trend = DIR_NONE; keyLevel = 0;  }
}

//+------------------------------------------------------------------+
//|  SECTION 2 – CONTEXT UPDATERS                                    |
//+------------------------------------------------------------------+

HTFBias ResolveBias(double b1H, double b1L, double b1C, double b2H, double b2L)
{
  if (b1C > b2H)               return BIAS_UP;
  if (b1C < b2L)               return BIAS_DOWN;
  if (b1H > b2H && b1C < b2H) return BIAS_DOWN;
  if (b1L < b2L && b1C > b2L) return BIAS_UP;
  return BIAS_SIDEWAY;
}

void UpdateBiasContext()
{
  datetime t0 = iTime(_Symbol, InpBiasTF, 0);
  if (t0 == g_Bias.lastBarTime) return;
  g_Bias.lastBarTime = t0;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }

  double b1H = iHigh (_Symbol, InpBiasTF, 1);
  double b1L = iLow  (_Symbol, InpBiasTF, 1);
  double b1C = iClose(_Symbol, InpBiasTF, 1);
  double b2H = iHigh (_Symbol, InpBiasTF, 2);
  double b2L = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prev = g_Bias.bias;
  g_Bias.bias  = ResolveBias(b1H, b1L, b1C, b2H, b2L);
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2H : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2L : 0;

  if (InpDebugLog && g_Bias.bias != prev)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias), b1H, b1L, b1C, b2H, b2L);
}

//----------------------------------------------------------------------
// UpdateTFTrendContext
//
// Gọi mỗi bar mới trên tf. Thực hiện 3 việc TRƯỚC khi re-scan swing:
//
//   1a. TriggerTF: Detect Liquidity Sweep (wick quét swing)
//   1b. MSS check: close phá keyLevel
//       - MiddleTF: ghi nhận mọi MSS
//       - TriggerTF v3: CHỈ ghi nhận nếu:
//           (a) thuận chiều MiddleTF trend
//           (b) có Sweep trước đó (g_LastLiqSweep hợp lệ)
//   2.  Re-scan swing structure → update trend/keyLevel
//
// Tất cả detection dùng OLD swing levels (trước re-scan).
//----------------------------------------------------------------------
void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime t0 = iTime(_Symbol, tf, 0);
  if (t0 == ctx.lastBarTime) return;                   // Chỉ chạy 1 lần/bar
  ctx.lastBarTime = t0;

  double   bar1C = iClose(_Symbol, tf, 1);             // Bar vừa đóng: close
  double   bar1H = iHigh (_Symbol, tf, 1);             //                high
  double   bar1L = iLow  (_Symbol, tf, 1);             //                low
  double   bar1O = iOpen (_Symbol, tf, 1);             //                open
  datetime bar1T = iTime (_Symbol, tf, 1);             //                time

  // ══════════════════════════════════════════════════════════════════
  // 1a. TriggerTF: Liquidity Sweep detection (TRƯỚC MSS check)
  //
  //   Bullish sweep (H1 UP): wick < L0 && close > L0
  //     → Giá quét dưới swing low, hút stop-loss bên sell
  //     → Rồi đóng lại phía trên → reversal signal
  //
  //   Bearish sweep (H1 DOWN): wick > H0 && close < H0
  //     → Giá quét trên swing high, hút stop-loss bên buy
  //     → Rồi đóng lại phía dưới → reversal signal
  //
  //   Sweep KHÔNG được vẽ riêng. Chỉ dùng làm prerequisite cho MSS.
  // ══════════════════════════════════════════════════════════════════
  if (tf == InpTriggerTF && g_MiddleTrend.trend != DIR_NONE)
  {
    if (g_MiddleTrend.trend == DIR_UP && ctx.l0 > 0)   // Bullish setup
    {
      if (bar1L < ctx.l0                                // Wick quét dưới L0
          && bar1C > ctx.l0                             // Close đóng lại trên L0
          && bar1T != g_LastLiqSweep.time)              // Chưa ghi nhận cây này
      {
        g_LastLiqSweep.valid       = true;
        g_LastLiqSweep.direction   = DIR_UP;            // Bull sweep = quét sell-side
        g_LastLiqSweep.sweptLevel  = ctx.l0;            // Mức swing bị quét
        g_LastLiqSweep.extremeWick = bar1L;             // Wick thấp nhất
        g_LastLiqSweep.time        = bar1T;

        if (InpDebugLog)
          PrintFormat("[SWEEP ▲] below L0=%.5f | wick=%.5f close=%.5f | %s",
            ctx.l0, bar1L, bar1C, TimeToString(bar1T));
      }
    }
    else if (g_MiddleTrend.trend == DIR_DOWN && ctx.h0 > 0)  // Bearish setup
    {
      if (bar1H > ctx.h0                                // Wick quét trên H0
          && bar1C < ctx.h0                             // Close đóng lại dưới H0
          && bar1T != g_LastLiqSweep.time)
      {
        g_LastLiqSweep.valid       = true;
        g_LastLiqSweep.direction   = DIR_DOWN;          // Bear sweep = quét buy-side
        g_LastLiqSweep.sweptLevel  = ctx.h0;
        g_LastLiqSweep.extremeWick = bar1H;             // Wick cao nhất
        g_LastLiqSweep.time        = bar1T;

        if (InpDebugLog)
          PrintFormat("[SWEEP ▼] above H0=%.5f | wick=%.5f close=%.5f | %s",
            ctx.h0, bar1H, bar1C, TimeToString(bar1T));
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // 1b. MSS check (dùng OLD keyLevel, trước re-scan)
  //
  //   Uptrend:   keyLevel = L0 → MSS khi close < L0 (bearish break)
  //   Downtrend: keyLevel = H0 → MSS khi close > H0 (bullish break)
  //
  //   v3 TriggerTF: MSS chỉ hợp lệ khi:
  //     (a) breakDir thuận chiều MiddleTF (VD: H1 UP → chỉ nhận bull MSS)
  //     (b) Có Liquidity Sweep trước đó cùng hướng
  //         (bull MSS cần bull sweep, bear MSS cần bear sweep)
  //     (c) Sweep xảy ra TRƯỚC cây MSS (sweep.time < bar1T)
  //
  //   MiddleTF: ghi nhận mọi MSS (không cần sweep filter)
  // ══════════════════════════════════════════════════════════════════
  if (ctx.trend != DIR_NONE && ctx.keyLevel > 0)
  {
    bool mssHit =
      (ctx.trend == DIR_UP   && bar1C < ctx.keyLevel) ||  // Bull→Bear: close < L0
      (ctx.trend == DIR_DOWN && bar1C > ctx.keyLevel);     // Bear→Bull: close > H0

    if (mssHit && bar1T != ctx.lastMssTime)
    {
      MarketDir breakDir = (ctx.trend == DIR_UP) ? DIR_DOWN : DIR_UP;

      // ── Determine if this MSS should be recorded ───────────────
      bool recordMss = true;
      string rejectReason = "";

      if (tf == InpTriggerTF)
      {
        // Filter (a): thuận chiều MiddleTF
        if (g_MiddleTrend.trend != DIR_NONE && breakDir != (MarketDir)g_MiddleTrend.trend)
        {
          recordMss = false;
          rejectReason = "ngược chiều H1";
        }

        // Filter (b): phải có sweep trước đó, cùng hướng
        if (recordMss)
        {
          bool hasSweep =
            g_LastLiqSweep.valid &&                     // Sweep tồn tại
            g_LastLiqSweep.direction == breakDir &&     // Cùng hướng với MSS
            g_LastLiqSweep.time < bar1T;                // Sweep xảy ra TRƯỚC MSS

          if (!hasSweep)
          {
            recordMss = false;
            rejectReason = "chưa có sweep";
          }
        }
      }

      // ── Record hoặc skip MSS ──────────────────────────────────
      if (recordMss)
      {
        ctx.lastMssTime  = bar1T;                       // Thời gian cây nến MSS
        ctx.lastMssLevel = ctx.keyLevel;                // Key level bị phá
        ctx.lastMssBreak = breakDir;                    // Hướng break

        // v3: Lưu sweep info kèm MSS (cho TriggerTF)
        if (tf == InpTriggerTF && g_LastLiqSweep.valid)
        {
          ctx.mssSweepTime  = g_LastLiqSweep.time;      // Copy sweep → MSS context
          ctx.mssSweepLevel = g_LastLiqSweep.sweptLevel;
          ctx.mssSweepWick  = g_LastLiqSweep.extremeWick;
        }

        if (InpDebugLog)
          PrintFormat("[%s MSS ✓] %s | KL=%.5f | close=%.5f | sweep@%s | bar=%s",
            EnumToString(tf),
            (breakDir == DIR_UP) ? "Bear→Bull ▲" : "Bull→Bear ▼",
            ctx.lastMssLevel, bar1C,
            (tf == InpTriggerTF) ? TimeToString(g_LastLiqSweep.time, TIME_MINUTES) : "n/a",
            TimeToString(bar1T));
      }
      else if (InpDebugLog)
      {
        PrintFormat("[%s MSS ✗] %s bị skip: %s | KL=%.5f | close=%.5f",
          EnumToString(tf),
          (breakDir == DIR_UP) ? "▲" : "▼",
          rejectReason, ctx.keyLevel, bar1C);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // 2. Re-scan swing structure
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
  datetime today = iTime(_Symbol, PERIOD_D1, 0);
  if (today != g_DailyRisk.dayStartTime)
  {
    g_DailyRisk.dayStartTime = today;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyRisk.limitHit     = false;
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;
  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                    / g_DailyRisk.startBalance * 100.0;
  if (lostPct >= InpMaxDailyLossPct)
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lostPct, g_DailyRisk.currentBalance);
  }
}

void UpdateAllContexts()
{
  UpdateDailyRiskContext();
  UpdateBiasContext();
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend);
}

//+------------------------------------------------------------------+
//|  SECTION 3 – GUARDS                                              |
//+------------------------------------------------------------------+

bool IsSessionAllowed()    { return true; /* TODO: London/NY filter */ }
bool IsDailyLossOK()       { return !g_DailyRisk.limitHit; }
bool IsBiasValid()         { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; }
bool IsMiddleTrendAligned()
{
  if (g_MiddleTrend.trend == DIR_NONE) return false;
  return (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP) ||
         (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN);
}

bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; }
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; }
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; }
  return true;
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
  g_ActiveFVGIdx  = -1;
  g_TradeBarIndex = -1;
  g_PendingTicket = 0;
  ZeroMemory(g_Trigger);
  ZeroMemory(g_TrigFVG);
  ZeroMemory(g_OrderPlan);
  ZeroMemory(g_LastLiqSweep);                          // v3: reset sweep khi cycle mới
  TransitionTo(EA_IDLE);
}

//+------------------------------------------------------------------+
//|  SECTION 5 – FVG HELPERS                                         |
//+------------------------------------------------------------------+

bool IsCandleStrong(ENUM_TIMEFRAMES tf, int i)
{
  double h = iHigh(_Symbol, tf, i), l = iLow(_Symbol, tf, i);
  double o = iOpen(_Symbol, tf, i), c = iClose(_Symbol, tf, i);
  double range = h - l;
  if (range < _Point) return false;
  return (MathAbs(c - o) / range * 100.0) >= InpFVGMinBodyPct;
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
  static datetime s_lastScan = 0;
  datetime t0 = iTime(_Symbol, InpMiddleTF, 0);
  if (t0 == s_lastScan) return;
  s_lastScan = t0;

  MarketDir dir = g_MiddleTrend.trend;
  if (dir == DIR_NONE) return;

  int maxBar = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2);

  for (int i = 2; i <= maxBar; i++)
  {
    double leftH  = iHigh (_Symbol, InpMiddleTF, i + 1);
    double leftL  = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightH = iHigh (_Symbol, InpMiddleTF, i - 1);
    double rightL = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midO   = iOpen (_Symbol, InpMiddleTF, i);
    double midC   = iClose(_Symbol, InpMiddleTF, i);
    double gH = 0, gL = 0;

    if (dir == DIR_UP)
    {
      if (leftH >= rightL || midC <= midO || !IsCandleStrong(InpMiddleTF, i)) continue;
      gL = leftH; gH = rightL;
    }
    else
    {
      if (leftL <= rightH || midC >= midO || !IsCandleStrong(InpMiddleTF, i)) continue;
      gH = leftL; gL = rightH;
    }

    datetime created = iTime(_Symbol, InpMiddleTF, i - 1);
    if (IsFVGInPool(created)) continue;

    // ── Evict oldest USED if pool full ──────────────────────────────
    if (g_FVGCount >= MAX_FVG_POOL)
    {
      int evict = -1; datetime oldest = TimeCurrent();
      for (int j = 0; j < g_FVGCount; j++)
        if (g_FVGPool[j].status == FVG_USED && g_FVGPool[j].createdTime < oldest)
          { oldest = g_FVGPool[j].createdTime; evict = j; }
      if (evict < 0) { if (InpDebugLog) Print("[FVG POOL] Full – no USED slot"); break; }
      for (int j = evict; j < g_FVGCount - 1; j++) g_FVGPool[j] = g_FVGPool[j + 1];
      g_FVGCount--;
      if      (g_ActiveFVGIdx >  evict) g_ActiveFVGIdx--;
      else if (g_ActiveFVGIdx == evict) g_ActiveFVGIdx = -1;
    }

    // ── Build record ─────────────────────────────────────────────────
    FVGRecord rec;
    ZeroMemory(rec);
    rec.id          = g_NextFVGId++;
    rec.direction   = dir;
    rec.high        = gH; rec.low = gL; rec.mid = (gH + gL) / 2.0;
    rec.createdTime = created;
    int rightBar    = i - 1;

    // P1: case1 – close punched through gap
    bool c1Hit = false; datetime c1T = 0;
    for (int j = rightBar - 1; j >= 1; j--)
    {
      double cl = iClose(_Symbol, InpMiddleTF, j);
      if ((rec.direction == DIR_UP   && cl < rec.low) ||
          (rec.direction == DIR_DOWN && cl > rec.high))
        { c1Hit = true; c1T = iTime(_Symbol, InpMiddleTF, j); break; }
    }
    if (c1Hit) { rec.status = FVG_USED; rec.usedCase = 1; rec.usedTime = c1T; }
    else
    {
      // P2: touch – wick entered gap
      bool tdHit = false; datetime tdT = 0;
      for (int j = rightBar - 1; j >= 1; j--)
      {
        bool inGap = (rec.direction == DIR_UP   && iLow (_Symbol, InpMiddleTF, j) <= rec.high) ||
                     (rec.direction == DIR_DOWN && iHigh(_Symbol, InpMiddleTF, j) >= rec.low);
        if (inGap) { tdHit = true; tdT = iTime(_Symbol, InpMiddleTF, j); break; }
      }
      if (tdHit) { rec.status = FVG_TOUCHED; rec.touchTime = tdT; rec.triggerTrendAtTouch = g_TriggerTrend.trend; }
      else
      {
        rec.status = FVG_PENDING;
        if ((int)(TimeCurrent() - rec.createdTime) > InpFVGMaxAliveMin * 60)
          { rec.status = FVG_USED; rec.usedCase = 0; rec.usedTime = TimeCurrent(); }
      }
    }

    g_FVGPool[g_FVGCount] = rec;
    g_FVGCount++;

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
  double   bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double   midC1 = iClose(_Symbol, InpMiddleTF, 1);
  datetime midT1 = iTime (_Symbol, InpMiddleTF, 1);

  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;

    // ── 1. Case1: H1 close phá xuyên qua FVG → broken ──────────────
    bool c1 = (g_FVGPool[i].direction == DIR_UP   && midC1 < g_FVGPool[i].low) ||
              (g_FVGPool[i].direction == DIR_DOWN && midC1 > g_FVGPool[i].high);
    if (c1)
    {
      g_FVGPool[i].status   = FVG_USED;
      g_FVGPool[i].usedCase = 1;
      g_FVGPool[i].usedTime = midT1;
      if (InpDebugLog)
        PrintFormat("[FVG #%d] USED(case1=broken) | close=%.5f vs [%.5f–%.5f]",
          g_FVGPool[i].id, midC1, g_FVGPool[i].low, g_FVGPool[i].high);
      continue;
    }

    if (g_FVGPool[i].status == FVG_PENDING)
    {
      // ── 2. Expire: quá thời hạn ─────────────────────────────────────
      int age = (int)(TimeCurrent() - g_FVGPool[i].createdTime);
      if (age > InpFVGMaxAliveMin * 60)
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 0;
        g_FVGPool[i].usedTime = TimeCurrent();
        if (InpDebugLog)
          PrintFormat("[FVG #%d] USED(expired) | age=%dmin", g_FVGPool[i].id, age / 60);
        continue;
      }
      // ── 3. Touch: bid vào vùng gap ───────────────────────────────────
      bool touched = (g_FVGPool[i].direction == DIR_UP   && bid <= g_FVGPool[i].high) ||
                     (g_FVGPool[i].direction == DIR_DOWN && bid >= g_FVGPool[i].low);
      if (touched)
      {
        g_FVGPool[i].status              = FVG_TOUCHED;
        g_FVGPool[i].touchTime           = TimeCurrent();
        g_FVGPool[i].triggerTrendAtTouch = g_TriggerTrend.trend;
        if (InpDebugLog)
          PrintFormat("[FVG #%d] TOUCHED | bid=%.5f [%.5f–%.5f] TrigTrend=%s",
            g_FVGPool[i].id, bid, g_FVGPool[i].low, g_FVGPool[i].high,
            EnumToString(g_FVGPool[i].triggerTrendAtTouch));
      }
    }
    else if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      // ── 4. Case2: TriggerTF MSS confirmed → entry signal ────────────
      bool wasOpposing, nowAligned;
      if (g_FVGPool[i].direction == DIR_UP)
        { wasOpposing = (g_FVGPool[i].triggerTrendAtTouch != DIR_UP);  nowAligned = (g_TriggerTrend.trend == DIR_UP);   }
      else
        { wasOpposing = (g_FVGPool[i].triggerTrendAtTouch != DIR_DOWN); nowAligned = (g_TriggerTrend.trend == DIR_DOWN); }

      if (wasOpposing && nowAligned)
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 2;
        g_FVGPool[i].usedTime = TimeCurrent();
        if (InpDebugLog)
          PrintFormat("[FVG #%d] USED(case2=triggered) | TrigTrend %s→%s [%.5f–%.5f] %s",
            g_FVGPool[i].id,
            EnumToString(g_FVGPool[i].triggerTrendAtTouch),
            EnumToString(g_TriggerTrend.trend),
            g_FVGPool[i].low, g_FVGPool[i].high,
            EnumToString(g_FVGPool[i].direction));
        continue;
      }
      // ── 5. Trigger timeout ────────────────────────────────────────────
      int bars = (int)((TimeCurrent() - g_FVGPool[i].touchTime) / PeriodSeconds(InpTriggerTF));
      if (bars > InpTriggerMaxBars
          && g_ActiveFVGIdx >= 0
          && g_FVGPool[g_ActiveFVGIdx].id == g_FVGPool[i].id)
      {
        if (InpDebugLog)
          PrintFormat("[FVG #%d] Trigger timeout (%d bars) – release active", g_FVGPool[i].id, bars);
        g_ActiveFVGIdx = -1;
      }
    }
  }
}

//+------------------------------------------------------------------+
//|  SECTION 7B – TRIGGER TF FVG SCANNER                             |
//+------------------------------------------------------------------+

bool ScanTriggerTFFVG(datetime touchTime, datetime mssTime, MarketDir dir)
{
  ZeroMemory(g_TrigFVG);

  int barTouch = MyBarShift(_Symbol, InpTriggerTF, touchTime);
  int barMss   = MyBarShift(_Symbol, InpTriggerTF, mssTime);

  if (barTouch < 0 || barMss < 0) return false;
  if (barTouch <= barMss + 2) return false;            // Cần ít nhất 3 bars giữa 2 mốc

  if (InpDebugLog)
    PrintFormat("[TFVG SCAN] touchBar=%d mssBar=%d dir=%s | scanning %d bars on %s",
      barTouch, barMss, EnumToString(dir), barTouch - barMss, EnumToString(InpTriggerTF));

  for (int i = barMss + 2; i < barTouch; i++)          // Scan từ gần MSS về phía touch
  {
    double leftH  = iHigh (_Symbol, InpTriggerTF, i + 1);
    double leftL  = iLow  (_Symbol, InpTriggerTF, i + 1);
    double rightH = iHigh (_Symbol, InpTriggerTF, i - 1);
    double rightL = iLow  (_Symbol, InpTriggerTF, i - 1);
    double midO   = iOpen (_Symbol, InpTriggerTF, i);
    double midC   = iClose(_Symbol, InpTriggerTF, i);
    double gH = 0, gL = 0;

    if (dir == DIR_UP)
    {
      if (leftH >= rightL) continue;                   // Không có gap
      if (midC <= midO)    continue;                   // Mid candle phải bullish
      gL = leftH; gH = rightL;
    }
    else
    {
      if (leftL <= rightH) continue;
      if (midC >= midO)    continue;                   // Mid candle phải bearish
      gH = leftL; gL = rightH;
    }

    if (gH - gL < _Point) continue;                   // Gap quá nhỏ

    g_TrigFVG.valid       = true;
    g_TrigFVG.direction   = dir;
    g_TrigFVG.high        = gH;
    g_TrigFVG.low         = gL;
    g_TrigFVG.mid         = (gH + gL) / 2.0;
    g_TrigFVG.createdTime = iTime(_Symbol, InpTriggerTF, i - 1);

    if (InpDebugLog)
      PrintFormat("[TFVG FOUND] %s [%.5f–%.5f] mid=%.5f | bar=%d %s",
        EnumToString(dir), gL, gH, g_TrigFVG.mid, i,
        TimeToString(g_TrigFVG.createdTime));
    return true;
  }

  if (InpDebugLog)
    Print("[TFVG SCAN] No TriggerTF FVG found between touch and MSS");
  return false;
}

//+------------------------------------------------------------------+
//|  SECTION 7C – ORDER PLAN & EXECUTION  (MQL5 native)              |
//+------------------------------------------------------------------+

double CalcLotFromRisk(double entry, double sl)
{
  double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney  = balance * InpRiskPercent / 100.0;
  double slPips     = MathAbs(entry - sl) / _Point;
  if (slPips < 1) return 0;

  double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if (tickValue <= 0 || tickSize <= 0) return 0;

  double pipValue   = tickValue * (_Point / tickSize);
  double rawLot     = riskMoney / (slPips * pipValue);

  double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (lotStep <= 0) lotStep = 0.01;

  rawLot = MathFloor(rawLot / lotStep) * lotStep;
  rawLot = MathMax(minLot, MathMin(maxLot, rawLot));

  return NormalizeDouble(rawLot, 2);
}

bool BuildOrderPlan(int fvgId, MarketDir dir)
{
  ZeroMemory(g_OrderPlan);

  if (!g_TrigFVG.valid) return false;

  double entry = NormalizeDouble(g_TrigFVG.mid, _Digits);   // Entry = mid TriggerTF FVG
  double sl, tp;

  if (dir == DIR_UP)
  {
    sl = g_TriggerTrend.l0;                            // SL dưới TriggerTF swing low
    if (sl <= 0 || sl >= entry) return false;
    sl = NormalizeDouble(sl - 2 * _Point, _Digits);    // Buffer 2 points
    double riskDist = entry - sl;
    tp = NormalizeDouble(entry + InpRiskReward * riskDist, _Digits);  // TP = entry + 2R
  }
  else
  {
    sl = g_TriggerTrend.h0;                            // SL trên TriggerTF swing high
    if (sl <= 0 || sl <= entry) return false;
    sl = NormalizeDouble(sl + 2 * _Point, _Digits);
    double riskDist = sl - entry;
    tp = NormalizeDouble(entry - InpRiskReward * riskDist, _Digits);
  }

  double lot = CalcLotFromRisk(entry, sl);
  if (lot <= 0) return false;

  g_OrderPlan.valid      = true;
  g_OrderPlan.direction  = (dir == DIR_UP) ? 1 : -1;
  g_OrderPlan.entry      = entry;
  g_OrderPlan.stopLoss   = sl;
  g_OrderPlan.takeProfit = tp;
  g_OrderPlan.lot        = lot;
  g_OrderPlan.parentFVGId = fvgId;

  if (InpDebugLog)
    PrintFormat("[ORDER PLAN] %s | entry=%.5f SL=%.5f TP=%.5f lot=%.2f | R=%.1f%% RR=%.1f | FVG#%d",
      (dir == DIR_UP) ? "BUY LIMIT" : "SELL LIMIT",
      entry, sl, tp, lot, InpRiskPercent, InpRiskReward, fvgId);
  return true;
}

ulong ExecuteLimitOrder()
{
  if (!g_OrderPlan.valid) return 0;

  ENUM_ORDER_TYPE cmd = (g_OrderPlan.direction > 0)
                         ? ORDER_TYPE_BUY_LIMIT
                         : ORDER_TYPE_SELL_LIMIT;

  string comment = StringFormat("ICT_FVG#%d", g_OrderPlan.parentFVGId);

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (cmd == ORDER_TYPE_BUY_LIMIT && g_OrderPlan.entry >= ask)
  {
    if (InpDebugLog)
      PrintFormat("[ORDER] BUY LIMIT rejected: entry %.5f >= ask %.5f → skip",
        g_OrderPlan.entry, ask);
    return 0;
  }
  if (cmd == ORDER_TYPE_SELL_LIMIT && g_OrderPlan.entry <= bid)
  {
    if (InpDebugLog)
      PrintFormat("[ORDER] SELL LIMIT rejected: entry %.5f <= bid %.5f → skip",
        g_OrderPlan.entry, bid);
    return 0;
  }

  MqlTradeRequest request;
  MqlTradeResult  result;
  ZeroMemory(request);
  ZeroMemory(result);

  request.action       = TRADE_ACTION_PENDING;
  request.symbol       = _Symbol;
  request.volume       = g_OrderPlan.lot;
  request.type         = cmd;
  request.price        = g_OrderPlan.entry;
  request.sl           = g_OrderPlan.stopLoss;
  request.tp           = g_OrderPlan.takeProfit;
  request.deviation    = (ulong)InpSlippage;
  request.magic        = InpMagicNumber;
  request.comment      = comment;
  request.type_filling = ORDER_FILLING_RETURN;
  request.type_time    = ORDER_TIME_GTC;

  if (!OrderSend(request, result))
  {
    PrintFormat("[ORDER] ❌ OrderSend failed | retcode=%u | %s %.2f @ %.5f SL=%.5f TP=%.5f",
      result.retcode,
      (cmd == ORDER_TYPE_BUY_LIMIT) ? "BUY_LIMIT" : "SELL_LIMIT",
      g_OrderPlan.lot, g_OrderPlan.entry,
      g_OrderPlan.stopLoss, g_OrderPlan.takeProfit);
    return 0;
  }

  if (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
  {
    PrintFormat("[ORDER] ❌ Server rejected | retcode=%u comment=%s",
      result.retcode, result.comment);
    return 0;
  }

  PrintFormat("[ORDER] ✅ %s ticket=%llu | %.2f @ %.5f SL=%.5f TP=%.5f | %s",
    (cmd == ORDER_TYPE_BUY_LIMIT) ? "BUY_LIMIT" : "SELL_LIMIT",
    result.order, g_OrderPlan.lot, g_OrderPlan.entry,
    g_OrderPlan.stopLoss, g_OrderPlan.takeProfit, comment);

  return result.order;
}

//+------------------------------------------------------------------+
//|  SECTION 8 – BEST FVG SELECTOR                                   |
//|  Priority: TOUCHED newest > PENDING newest                       |
//+------------------------------------------------------------------+

int GetBestActiveFVGIdx()
{
  int bestIdx = -1; datetime bestTime = 0; bool foundTouch = false;
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;
    if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      if (!foundTouch || g_FVGPool[i].createdTime > bestTime)
        { foundTouch = true; bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
    }
    else if (!foundTouch && g_FVGPool[i].createdTime > bestTime)
      { bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
  }
  return bestIdx;
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
    { ResetToIdle(StringFormat("FVG #%d used(case%d) before touch", g_FVGPool[ai].id, g_FVGPool[ai].usedCase)); return; }
  if (g_FVGPool[ai].status == FVG_TOUCHED)
    { TransitionTo(EA_WAIT_TRIGGER); return; }

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
  if (g_ActiveFVGIdx < 0) { ResetToIdle("trigger timeout / active lost"); return; }
  int ai = g_ActiveFVGIdx;

  if (g_FVGPool[ai].status == FVG_USED)
  {
    if (g_FVGPool[ai].usedCase == 2)
    {
      if (InpDebugLog)
        PrintFormat("[ENTRY SIGNAL] FVG #%d %s [%.5f–%.5f]",
          g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
          g_FVGPool[ai].low, g_FVGPool[ai].high);

      bool hasTFVG = ScanTriggerTFFVG(
        g_FVGPool[ai].touchTime,
        g_TriggerTrend.lastMssTime,
        g_FVGPool[ai].direction);

      if (hasTFVG && BuildOrderPlan(g_FVGPool[ai].id, g_FVGPool[ai].direction))
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
        ResetToIdle(StringFormat("FVG #%d no valid TriggerTF FVG or order plan", g_FVGPool[ai].id));
    }
    else
      ResetToIdle(StringFormat("FVG #%d used(case%d) during trigger", g_FVGPool[ai].id, g_FVGPool[ai].usedCase));
    return;
  }
  if (g_FVGPool[ai].status == FVG_PENDING) { TransitionTo(EA_WAIT_TOUCH); return; }
}

void OnStateInTrade()
{
  // ── 1. Kiểm tra pending order còn active không ─────────────────
  if (g_PendingTicket > 0)
  {
    bool foundPending = false;
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
      ulong ticket = OrderGetTicket(i);
      if (ticket == g_PendingTicket)
      {
        foundPending = true;
        break;
      }
    }

    if (!foundPending)
    {
      // Tìm position tương ứng (limit đã fill)
      bool posFound = false;
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        ulong posTicket = PositionGetTicket(i);
        if (posTicket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
          posFound = true;
          g_PendingTicket = 0;                         // Filled → track position
          if (InpDebugLog)
            PrintFormat("[TRADE] Limit filled → position ticket=%llu", posTicket);
          break;
        }
      }

      if (!posFound)
      {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());

        // Check: lệnh bị hủy?
        bool wasCancelled = false;
        for (int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
          ulong hTicket = HistoryOrderGetTicket(i);
          if (hTicket == g_PendingTicket)
          {
            long state = HistoryOrderGetInteger(hTicket, ORDER_STATE);
            if (state == ORDER_STATE_CANCELED || state == ORDER_STATE_EXPIRED ||
                state == ORDER_STATE_REJECTED)
              wasCancelled = true;
            break;
          }
        }
        if (wasCancelled) { ResetToIdle("pending order cancelled/expired"); return; }

        // Check: position đã đóng?
        bool dealFound = false;
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
          ulong dTicket = HistoryDealGetTicket(i);
          if (HistoryDealGetInteger(dTicket, DEAL_MAGIC) == InpMagicNumber &&
              HistoryDealGetString(dTicket, DEAL_SYMBOL) == _Symbol &&
              HistoryDealGetInteger(dTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
          {
            double profit = HistoryDealGetDouble(dTicket, DEAL_PROFIT);
            if (InpDebugLog)
              PrintFormat("[TRADE] Position closed | deal=%llu profit=%.2f", dTicket, profit);
            dealFound = true;
            break;
          }
        }

        if (dealFound) ResetToIdle("trade closed");
        else           ResetToIdle("pending order lost");
        return;
      }
    }
    return;                                            // Pending still alive → wait
  }

  // ── 2. Track open position (pending đã fill) ────────────────────
  bool hasPosition = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong posTicket = PositionGetTicket(i);
    if (posTicket == 0) continue;
    if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
        PositionGetString(POSITION_SYMBOL) == _Symbol)
    {
      hasPosition = true;
      break;
    }
  }

  if (!hasPosition)
    ResetToIdle("trade closed – no position");
}

//+------------------------------------------------------------------+
//|  SECTION 10 – STATE MACHINE RUNNER                               |
//+------------------------------------------------------------------+

void RunStateMachine()
{
  UpdateFVGStatuses();
  ScanAndRegisterFVGs();
  switch (g_State)
  {
    case EA_IDLE:         OnStateIdle();        break;
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;
    case EA_IN_TRADE:     OnStateInTrade();     break;
  }
}

//+------------------------------------------------------------------+
//|  SECTION 11 – DRAWING                                            |
//+------------------------------------------------------------------+

//----------------------------------------------------------------------
// DrawOneSwingPoint – generic swing-point drawer
//----------------------------------------------------------------------
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
// DrawMSSMarker – v3: Vẽ MSS kèm sweep marker
//
// Khi MSS hợp lệ trên TriggerTF, vẽ CẢ HAI:
//   1. Sweep: ◆ diamond tại wick extreme + đường ngang tại swept level
//   2. Break: ▲/▼ arrow tại close MSS + đường ngang tại broken key level
//
// Cả 2 tạo thành 1 pattern hoàn chỉnh trên chart.
//----------------------------------------------------------------------
void DrawMSSMarker(
  string mssId, ENUM_TIMEFRAMES tf,
  datetime mssTime, double mssLevel, MarketDir mssBreak,
  datetime sweepTime, double sweepLevel, double sweepWick)
{
  if (!InpDebugDraw || mssTime == 0) return;

  // ── MSS break: arrow + label + key level line ─────────────────
  string arrN = MSS_PREFIX + mssId + "_ARR";
  string lblN = MSS_PREFIX + mssId + "_LBL";
  string klN  = MSS_PREFIX + mssId + "_KL";

  bool   isBull = (mssBreak == DIR_UP);
  color  clr    = isBull ? clrLime : clrTomato;

  int    shift     = MyBarShift(_Symbol, tf, mssTime);
  if (shift < 0) return;
  double closeAtMss = iClose(_Symbol, tf, shift);

  // Arrow tại close price cây nến MSS
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

  // Dotted line tại broken key level
  datetime tEnd = iTime(_Symbol, tf, 0);
  if (ObjectFind(0, klN) < 0)
    ObjectCreate(0, klN, OBJ_TREND, 0, mssTime, mssLevel, tEnd, mssLevel);
  ObjectSetInteger(0, klN, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, klN, OBJPROP_STYLE,     STYLE_DOT);
  ObjectSetInteger(0, klN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, klN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, klN, 0, mssTime, mssLevel);
  ObjectMove(0, klN, 1, tEnd,    mssLevel);

  // ── v3: Sweep marker (chỉ vẽ nếu sweep data hợp lệ) ──────────
  if (sweepTime > 0 && sweepLevel > 0)
  {
    string swpArrN = MSS_PREFIX + mssId + "_SWP_ARR";   // ◆ diamond tại wick
    string swpLblN = MSS_PREFIX + mssId + "_SWP_LBL";   // Label "SWEEP"
    string swpLvlN = MSS_PREFIX + mssId + "_SWP_LVL";   // Đường ngang tại swept level
    string swpWkN  = MSS_PREFIX + mssId + "_SWP_WK";    // Vertical wick line

    color swpClr = isBull ? C'0,210,230' : C'230,80,210';  // Cyan / Magenta

    // ◆ Diamond tại wick extreme
    if (ObjectFind(0, swpArrN) < 0)
      ObjectCreate(0, swpArrN, OBJ_ARROW, 0, sweepTime, sweepWick);
    ObjectSetInteger(0, swpArrN, OBJPROP_ARROWCODE, 4);    // 4 = diamond
    ObjectSetInteger(0, swpArrN, OBJPROP_COLOR,     swpClr);
    ObjectSetInteger(0, swpArrN, OBJPROP_WIDTH,     2);
    ObjectMove(0, swpArrN, 0, sweepTime, sweepWick);

    // Label "SWEEP"
    int swShift = MyBarShift(_Symbol, tf, sweepTime);
    double swRng = (swShift >= 0) ? iHigh(_Symbol, tf, swShift) - iLow(_Symbol, tf, swShift) : 10 * _Point;
    double swLblY = isBull ? sweepWick - swRng * 0.7 : sweepWick + swRng * 0.7;
    if (ObjectFind(0, swpLblN) < 0)
      ObjectCreate(0, swpLblN, OBJ_TEXT, 0, sweepTime, swLblY);
    ObjectMove(0, swpLblN, 0, sweepTime, swLblY);
    ObjectSetString (0, swpLblN, OBJPROP_TEXT,    "SWEEP");
    ObjectSetInteger(0, swpLblN, OBJPROP_COLOR,   swpClr);
    ObjectSetInteger(0, swpLblN, OBJPROP_FONTSIZE, 7);
    ObjectSetInteger(0, swpLblN, OBJPROP_ANCHOR,  isBull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

    // Đường ngang đứt tại swept swing level (từ sweep đến MSS)
    if (ObjectFind(0, swpLvlN) < 0)
      ObjectCreate(0, swpLvlN, OBJ_TREND, 0, sweepTime, sweepLevel, mssTime, sweepLevel);
    ObjectSetInteger(0, swpLvlN, OBJPROP_COLOR,     swpClr);
    ObjectSetInteger(0, swpLvlN, OBJPROP_STYLE,     STYLE_DASHDOTDOT);
    ObjectSetInteger(0, swpLvlN, OBJPROP_WIDTH,     1);
    ObjectSetInteger(0, swpLvlN, OBJPROP_RAY_RIGHT, false);
    ObjectMove(0, swpLvlN, 0, sweepTime, sweepLevel);
    ObjectMove(0, swpLvlN, 1, mssTime, sweepLevel);

    // Vertical wick line: swept level → wick extreme
    if (ObjectFind(0, swpWkN) < 0)
      ObjectCreate(0, swpWkN, OBJ_TREND, 0, sweepTime, sweepLevel, sweepTime, sweepWick);
    ObjectSetInteger(0, swpWkN, OBJPROP_COLOR, swpClr);
    ObjectSetInteger(0, swpWkN, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, swpWkN, OBJPROP_WIDTH, 2);
    ObjectMove(0, swpWkN, 0, sweepTime, sweepLevel);
    ObjectMove(0, swpWkN, 1, sweepTime, sweepWick);
  }
}

void DrawMSSMarkers()
{
  if (!InpDebugDraw) return;

  // MiddleTF MSS – vẽ KHÔNG kèm sweep (MiddleTF không cần sweep)
  if (g_MiddleTrend.lastMssTime > 0)
  {
    string mid = "M_" + IntegerToString((long)g_MiddleTrend.lastMssTime);
    DrawMSSMarker(mid, InpMiddleTF,
      g_MiddleTrend.lastMssTime, g_MiddleTrend.lastMssLevel, g_MiddleTrend.lastMssBreak,
      0, 0, 0);                                        // Không có sweep data
  }

  // TriggerTF MSS – vẽ KÈM sweep (đã validate trong UpdateTFTrendContext)
  if (g_TriggerTrend.lastMssTime > 0)
  {
    string tid = "T_" + IntegerToString((long)g_TriggerTrend.lastMssTime);
    DrawMSSMarker(tid, InpTriggerTF,
      g_TriggerTrend.lastMssTime, g_TriggerTrend.lastMssLevel, g_TriggerTrend.lastMssBreak,
      g_TriggerTrend.mssSweepTime,                     // Sweep time đi kèm MSS
      g_TriggerTrend.mssSweepLevel,                    // Swept swing level
      g_TriggerTrend.mssSweepWick);                    // Wick extreme
  }
}

//----------------------------------------------------------------------
// v3: DrawOrderVisualization – TradingView-style Entry/SL/TP
//
// Layout:
//  ┌───────────────────────────┐  ◎ TP 1.23568  +112p  (2.0R)
//  │    TP zone (dark green)   │
//  ├───────────────────────────┤  ▶ BUY LIM 1.23456  |  0.05 lot
//  │    SL zone (dark red)     │
//  └───────────────────────────┘  ✕ SL 1.23400  -56p
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

  // Nếu không có order plan → xóa tất cả ORD_ objects
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
  double lot   = g_OrderPlan.lot;

  // Time range cho rectangles
  datetime tStart = (g_TrigFVG.valid) ? g_TrigFVG.createdTime : iTime(_Symbol, InpTriggerTF, 20);
  datetime tEnd   = iTime(_Symbol, InpTriggerTF, 0) + PeriodSeconds(InpTriggerTF) * 25;

  // Tính pips & R:R
  double slPips = MathAbs(entry - sl) / _Point;
  double tpPips = MathAbs(tp - entry) / _Point;
  double rr     = (slPips > 0) ? tpPips / slPips : 0;

  // Colors
  color entryClr = isBuy ? C'33,150,243'  : C'255,152,0'; // Blue / Orange
  color tpFill   = C'15,65,35';                            // Dark green fill
  color slFill   = C'85,15,15';                            // Dark red fill
  color tpLine   = C'38,166,91';                            // Green line
  color slLine   = C'229,57,53';                            // Red line

  // ── TP Zone rectangle ──────────────────────────────────────────
  double tpTop = (isBuy) ? tp : entry;
  double tpBot = (isBuy) ? entry : tp;
  if (ObjectFind(0, tpZoneN) < 0)
    ObjectCreate(0, tpZoneN, OBJ_RECTANGLE, 0, tStart, tpTop, tEnd, tpBot);
  ObjectSetInteger(0, tpZoneN, OBJPROP_COLOR, tpFill);
  ObjectSetInteger(0, tpZoneN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, tpZoneN, OBJPROP_BACK,  true);
  ObjectMove(0, tpZoneN, 0, tStart, tpTop);
  ObjectMove(0, tpZoneN, 1, tEnd, tpBot);

  // ── SL Zone rectangle ──────────────────────────────────────────
  double slTop = (isBuy) ? entry : sl;
  double slBot = (isBuy) ? sl : entry;
  if (ObjectFind(0, slZoneN) < 0)
    ObjectCreate(0, slZoneN, OBJ_RECTANGLE, 0, tStart, slTop, tEnd, slBot);
  ObjectSetInteger(0, slZoneN, OBJPROP_COLOR, slFill);
  ObjectSetInteger(0, slZoneN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, slZoneN, OBJPROP_BACK,  true);
  ObjectMove(0, slZoneN, 0, tStart, slTop);
  ObjectMove(0, slZoneN, 1, tEnd, slBot);

  // ── Entry line (solid 2px, ray right) ──────────────────────────
  if (ObjectFind(0, entLineN) < 0)
    ObjectCreate(0, entLineN, OBJ_TREND, 0, tStart, entry, tEnd, entry);
  ObjectSetInteger(0, entLineN, OBJPROP_COLOR,     entryClr);
  ObjectSetInteger(0, entLineN, OBJPROP_STYLE,     STYLE_SOLID);
  ObjectSetInteger(0, entLineN, OBJPROP_WIDTH,     2);
  ObjectSetInteger(0, entLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, entLineN, 0, tStart, entry);
  ObjectMove(0, entLineN, 1, tEnd, entry);

  // ── TP line (dashed, ray right) ────────────────────────────────
  if (ObjectFind(0, tpLineN) < 0)
    ObjectCreate(0, tpLineN, OBJ_TREND, 0, tStart, tp, tEnd, tp);
  ObjectSetInteger(0, tpLineN, OBJPROP_COLOR,     tpLine);
  ObjectSetInteger(0, tpLineN, OBJPROP_STYLE,     STYLE_DASH);
  ObjectSetInteger(0, tpLineN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, tpLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, tpLineN, 0, tStart, tp);
  ObjectMove(0, tpLineN, 1, tEnd, tp);

  // ── SL line (dashed, ray right) ────────────────────────────────
  if (ObjectFind(0, slLineN) < 0)
    ObjectCreate(0, slLineN, OBJ_TREND, 0, tStart, sl, tEnd, sl);
  ObjectSetInteger(0, slLineN, OBJPROP_COLOR,     slLine);
  ObjectSetInteger(0, slLineN, OBJPROP_STYLE,     STYLE_DASH);
  ObjectSetInteger(0, slLineN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, slLineN, OBJPROP_RAY_RIGHT, true);
  ObjectMove(0, slLineN, 0, tStart, sl);
  ObjectMove(0, slLineN, 1, tEnd, sl);

  // ── Entry label ────────────────────────────────────────────────
  datetime lblTime = tEnd;
  string entTxt = StringFormat("%s %s  |  %.2f lot",
    isBuy ? "▶ BUY LIM" : "▶ SELL LIM",
    DoubleToString(entry, _Digits), lot);
  if (ObjectFind(0, entLblN) < 0)
    ObjectCreate(0, entLblN, OBJ_TEXT, 0, lblTime, entry);
  ObjectMove(0, entLblN, 0, lblTime, entry);
  ObjectSetString (0, entLblN, OBJPROP_TEXT,     entTxt);
  ObjectSetInteger(0, entLblN, OBJPROP_COLOR,    entryClr);
  ObjectSetInteger(0, entLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, entLblN, OBJPROP_ANCHOR,   ANCHOR_LEFT);

  // ── TP label ───────────────────────────────────────────────────
  string tpTxt = StringFormat("◎ TP %s  +%.0fp  (%.1fR)",
    DoubleToString(tp, _Digits), tpPips, rr);
  if (ObjectFind(0, tpLblN) < 0)
    ObjectCreate(0, tpLblN, OBJ_TEXT, 0, lblTime, tp);
  ObjectMove(0, tpLblN, 0, lblTime, tp);
  ObjectSetString (0, tpLblN, OBJPROP_TEXT,     tpTxt);
  ObjectSetInteger(0, tpLblN, OBJPROP_COLOR,    tpLine);
  ObjectSetInteger(0, tpLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, tpLblN, OBJPROP_ANCHOR,   isBuy ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

  // ── SL label ───────────────────────────────────────────────────
  string slTxt = StringFormat("✕ SL %s  -%.0fp",
    DoubleToString(sl, _Digits), slPips);
  if (ObjectFind(0, slLblN) < 0)
    ObjectCreate(0, slLblN, OBJ_TEXT, 0, lblTime, sl);
  ObjectMove(0, slLblN, 0, lblTime, sl);
  ObjectSetString (0, slLblN, OBJPROP_TEXT,     slTxt);
  ObjectSetInteger(0, slLblN, OBJPROP_COLOR,    slLine);
  ObjectSetInteger(0, slLblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, slLblN, OBJPROP_ANCHOR,   isBuy ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

  // ── Risk info label (giữa entry và SL) ─────────────────────────
  double infoY = (entry + sl) / 2.0;
  string infoTxt = StringFormat("Risk %.1f%% | SL %.0fp | TP %.0fp | %.1fR",
    InpRiskPercent, slPips, tpPips, rr);
  if (ObjectFind(0, infoLblN) < 0)
    ObjectCreate(0, infoLblN, OBJ_TEXT, 0, lblTime, infoY);
  ObjectMove(0, infoLblN, 0, lblTime, infoY);
  ObjectSetString (0, infoLblN, OBJPROP_TEXT,     infoTxt);
  ObjectSetInteger(0, infoLblN, OBJPROP_COLOR,    C'160,160,160');
  ObjectSetInteger(0, infoLblN, OBJPROP_FONTSIZE, 7);
  ObjectSetInteger(0, infoLblN, OBJPROP_ANCHOR,   ANCHOR_LEFT);
}

//----------------------------------------------------------------------
// DrawTriggerFVG – TriggerTF FVG rectangle + midline + label
//----------------------------------------------------------------------
void DrawTriggerFVG()
{
  if (!InpDebugDraw) return;
  if (!g_TrigFVG.valid) return;

  string rectN = TFVG_PREFIX + "RECT";
  string midN  = TFVG_PREFIX + "MID";
  string lblN  = TFVG_PREFIX + "LBL";
  string entN  = TFVG_PREFIX + "ENTRY";

  datetime tStart = g_TrigFVG.createdTime;
  datetime tEnd   = iTime(_Symbol, InpTriggerTF, 0);
  if (tEnd <= tStart) tEnd = tStart + PeriodSeconds(InpTriggerTF) * 10;

  color fillColor = (g_TrigFVG.direction == DIR_UP) ? C'0,180,100' : C'200,50,80';

  if (ObjectFind(0, rectN) < 0)
    ObjectCreate(0, rectN, OBJ_RECTANGLE, 0, tStart, g_TrigFVG.high, tEnd, g_TrigFVG.low);
  ObjectSetInteger(0, rectN, OBJPROP_COLOR, fillColor);
  ObjectSetInteger(0, rectN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, rectN, OBJPROP_BACK,  true);
  ObjectSetInteger(0, rectN, OBJPROP_WIDTH, 1);
  ObjectMove(0, rectN, 0, tStart, g_TrigFVG.high);
  ObjectMove(0, rectN, 1, tEnd,   g_TrigFVG.low);

  if (ObjectFind(0, midN) < 0)
    ObjectCreate(0, midN, OBJ_TREND, 0, tStart, g_TrigFVG.mid, tEnd, g_TrigFVG.mid);
  ObjectSetInteger(0, midN, OBJPROP_COLOR,     clrWhite);
  ObjectSetInteger(0, midN, OBJPROP_STYLE,     STYLE_DASHDOT);
  ObjectSetInteger(0, midN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, midN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, midN, 0, tStart, g_TrigFVG.mid);
  ObjectMove(0, midN, 1, tEnd,   g_TrigFVG.mid);

  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(0, lblN, OBJ_TEXT, 0, tStart, g_TrigFVG.high);
  ObjectMove(0, lblN, 0, tStart, g_TrigFVG.high);
  string sym = (g_TrigFVG.direction == DIR_UP) ? "▲" : "▼";
  ObjectSetString (0, lblN, OBJPROP_TEXT, StringFormat("tFVG %s [%.5f]", sym, g_TrigFVG.mid));
  ObjectSetInteger(0, lblN, OBJPROP_COLOR,    fillColor);
  ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 7);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);

  if (g_OrderPlan.valid)
  {
    if (ObjectFind(0, entN) < 0)
      ObjectCreate(0, entN, OBJ_TREND, 0, tStart, g_OrderPlan.entry, tEnd, g_OrderPlan.entry);
    ObjectSetInteger(0, entN, OBJPROP_COLOR,     clrGold);
    ObjectSetInteger(0, entN, OBJPROP_STYLE,     STYLE_SOLID);
    ObjectSetInteger(0, entN, OBJPROP_WIDTH,     2);
    ObjectSetInteger(0, entN, OBJPROP_RAY_RIGHT, true);
    ObjectMove(0, entN, 0, tStart, g_OrderPlan.entry);
    ObjectMove(0, entN, 1, tEnd,   g_OrderPlan.entry);
  }
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
    ObjectCreate(0, rectN, OBJ_RECTANGLE, 0,
      g_FVGPool[idx].createdTime, g_FVGPool[idx].high, rectEnd, g_FVGPool[idx].low);
  ObjectSetInteger(0, rectN, OBJPROP_COLOR, fillColor);
  ObjectSetInteger(0, rectN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, rectN, OBJPROP_BACK,  true);
  ObjectSetInteger(0, rectN, OBJPROP_WIDTH, 1);
  ObjectMove(0, rectN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectMove(0, rectN, 1, rectEnd,                    g_FVGPool[idx].low);

  color midColor = (g_FVGPool[idx].status == FVG_USED) ? C'60,60,60' : clrSilver;
  if (ObjectFind(0, midN) < 0)
    ObjectCreate(0, midN, OBJ_TREND, 0,
      g_FVGPool[idx].createdTime, g_FVGPool[idx].mid, rectEnd, g_FVGPool[idx].mid);
  ObjectSetInteger(0, midN, OBJPROP_COLOR,     midColor);
  ObjectSetInteger(0, midN, OBJPROP_STYLE,     STYLE_DOT);
  ObjectSetInteger(0, midN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, midN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, midN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].mid);
  ObjectMove(0, midN, 1, rectEnd,                    g_FVGPool[idx].mid);

  string sym   = (g_FVGPool[idx].direction == DIR_UP) ? "▲" : "▼";
  string stTxt = "";
  if      (g_FVGPool[idx].status == FVG_TOUCHED)  stTxt = " [TOUCHED]";
  else if (g_FVGPool[idx].usedCase == 2)           stTxt = " [TRIGGERED]";
  else if (g_FVGPool[idx].usedCase == 1)           stTxt = " [BROKEN]";
  else if (g_FVGPool[idx].status == FVG_USED)      stTxt = " [EXPIRED]";

  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(0, lblN, OBJ_TEXT, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectMove(0, lblN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectSetString (0, lblN, OBJPROP_TEXT,
    StringFormat("FVG#%d %s%s", g_FVGPool[idx].id, sym, stTxt));
  ObjectSetInteger(0, lblN, OBJPROP_COLOR,    fillColor);
  ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);
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

  LBL("DBG_HDR",  "── ICT EA v3 ──", 10, clrSilver)

  // Bias
  color cB = (g_Bias.bias==BIAS_UP)?clrLime:(g_Bias.bias==BIAS_DOWN)?clrTomato:(g_Bias.bias==BIAS_SIDEWAY)?clrOrange:clrGray;
  LBL("DBG_BIAS", StringFormat("Bias : %s", EnumToString(g_Bias.bias)), 34, cB)

  // H1 trend
  color cMT = (g_MiddleTrend.trend==DIR_UP)?clrLime:(g_MiddleTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_MT",   StringFormat("H1   : %s  KL=%.5f", EnumToString(g_MiddleTrend.trend), g_MiddleTrend.keyLevel), 58, cMT)

  // H1 MSS
  if (g_MiddleTrend.lastMssTime > 0)
  {
    color cMSS = (g_MiddleTrend.lastMssBreak==DIR_UP) ? clrLime : clrTomato;
    LBL("DBG_MMSS", StringFormat("H1MSS: %s @ %s", (g_MiddleTrend.lastMssBreak==DIR_UP)?"▲":"▼",
      TimeToString(g_MiddleTrend.lastMssTime, TIME_MINUTES)), 82, cMSS)
  }
  else ObjectDelete(0,"DBG_MMSS");

  // M5 trend
  color cTT = (g_TriggerTrend.trend==DIR_UP)?clrLime:(g_TriggerTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_TT",   StringFormat("M5   : %s  KL=%.5f", EnumToString(g_TriggerTrend.trend), g_TriggerTrend.keyLevel), 106, cTT)

  // M5 MSS (v3: đã bao gồm sweep validation)
  if (g_TriggerTrend.lastMssTime > 0)
  {
    color cMSS2 = (g_TriggerTrend.lastMssBreak==DIR_UP) ? clrLime : clrTomato;
    string sweepInfo = (g_TriggerTrend.mssSweepTime > 0)
      ? StringFormat(" sweep@%s", TimeToString(g_TriggerTrend.mssSweepTime, TIME_MINUTES))
      : "";
    LBL("DBG_TMSS", StringFormat("M5MSS: %s @ %s%s",
      (g_TriggerTrend.lastMssBreak==DIR_UP)?"▲":"▼",
      TimeToString(g_TriggerTrend.lastMssTime, TIME_MINUTES),
      sweepInfo), 130, cMSS2)
  }
  else ObjectDelete(0,"DBG_TMSS");

  // Sweep status (internal, không vẽ riêng nhưng show trong panel)
  if (g_LastLiqSweep.valid)
  {
    color cSw = (g_LastLiqSweep.direction == DIR_UP) ? C'0,210,230' : C'230,80,210';
    LBL("DBG_SWEEP", StringFormat("Sweep: %s @%.5f (pending)",
      (g_LastLiqSweep.direction==DIR_UP)?"▲":"▼",
      g_LastLiqSweep.sweptLevel), 154, cSw)
  }
  else ObjectDelete(0,"DBG_SWEEP");

  // Daily risk
  double lostPct = g_DailyRisk.startBalance > 0
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance) / g_DailyRisk.startBalance * 100.0 : 0.0;
  color cR = g_DailyRisk.limitHit?clrRed:(lostPct>InpMaxDailyLossPct*0.7?clrOrange:clrLime);
  LBL("DBG_RISK", StringFormat("Risk : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct), 178, cR)
  LBL("DBG_BAL",  StringFormat("Bal  : %.2f (start %.2f)", g_DailyRisk.currentBalance, g_DailyRisk.startBalance), 202, clrSilver)
  LBL("DBG_LIM",  g_DailyRisk.limitHit?"⛔ DAILY LOSS HIT":"✅ Loss OK", 226, g_DailyRisk.limitHit?clrRed:clrLime)

  // State
  color cS = (g_State==EA_IDLE)?clrSilver:(g_State==EA_WAIT_TOUCH)?clrOrange:(g_State==EA_WAIT_TRIGGER)?clrYellow:clrLime;
  LBL("DBG_ST",   StringFormat("State: %s", EnumToString(g_State)), 250, cS)

  if (g_BlockReason != BLOCK_NONE)
    { LBL("DBG_BLK", StringFormat("Block: %s", EnumToString(g_BlockReason)), 274, clrTomato) }
  else ObjectDelete(0,"DBG_BLK");

  // FVG pool
  int nP=0,nT=0,nU=0;
  for(int i=0;i<g_FVGCount;i++)
  {
    if      (g_FVGPool[i].status==FVG_PENDING) nP++;
    else if (g_FVGPool[i].status==FVG_TOUCHED) nT++;
    else                                        nU++;
  }
  color cP = (nT>0)?clrDeepSkyBlue:(nP>0)?clrDodgerBlue:clrGray;
  LBL("DBG_POOL", StringFormat("Pool : P=%d T=%d U=%d (%d/%d)", nP,nT,nU,g_FVGCount,MAX_FVG_POOL), 298, cP)

  // Active FVG
  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount)
  {
    int ai = g_ActiveFVGIdx;
    color cA = (g_FVGPool[ai].status==FVG_TOUCHED)?clrDeepSkyBlue:clrDodgerBlue;
    LBL("DBG_ACT", StringFormat("Act  : #%d %s [%.5f–%.5f] %s",
      g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
      g_FVGPool[ai].low, g_FVGPool[ai].high,
      EnumToString(g_FVGPool[ai].status)), 322, cA)
  }
  else ObjectDelete(0,"DBG_ACT");

  // Pending order
  if (g_PendingTicket > 0 && g_OrderPlan.valid)
  {
    string ordDir = (g_OrderPlan.direction > 0) ? "BUY_LIM" : "SELL_LIM";
    LBL("DBG_ORD", StringFormat("Order: %s #%llu @ %.5f SL=%.5f TP=%.5f",
      ordDir, g_PendingTicket, g_OrderPlan.entry,
      g_OrderPlan.stopLoss, g_OrderPlan.takeProfit), 346, clrGold)
  }
  else ObjectDelete(0,"DBG_ORD");

  // TriggerTF FVG
  if (g_TrigFVG.valid)
  {
    string tDir = (g_TrigFVG.direction == DIR_UP) ? "▲" : "▼";
    LBL("DBG_TFVG", StringFormat("tFVG : %s [%.5f–%.5f] mid=%.5f",
      tDir, g_TrigFVG.low, g_TrigFVG.high, g_TrigFVG.mid), 370, C'0,220,150')
  }
  else ObjectDelete(0,"DBG_TFVG");

  #undef LBL
  ChartRedraw(0);
}

//----------------------------------------------------------------------
// DrawVisuals – master draw function
//----------------------------------------------------------------------
void DrawVisuals()
{
  DrawMiddleSwingPoints();     // H1 swing H0/H1/L0/L1
  DrawTriggerSwingPoints();    // M5 swing tH0/tH1/tL0/tL1
  DrawMSSMarkers();            // MSS + sweep (combined, v3)
  DrawFVGPool();               // MiddleTF FVG rectangles
  DrawTriggerFVG();            // TriggerTF FVG rectangle
  DrawOrderVisualization();    // TradingView-style Entry/SL/TP
  DrawContextDebug();          // Info panel
}

//+------------------------------------------------------------------+
//|  SECTION 12 – EA LIFECYCLE                                       |
//+------------------------------------------------------------------+

int OnInit()
{
  ZeroMemory(g_Bias); ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);
  ZeroMemory(g_Trigger); ZeroMemory(g_DailyRisk);
  ZeroMemory(g_TrigFVG); ZeroMemory(g_OrderPlan);
  ZeroMemory(g_LastLiqSweep);
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);
  g_FVGCount = 0; g_NextFVGId = 0;
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1;
  g_PendingTicket = 0;
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;

  UpdateAllContexts();
  ScanAndRegisterFVGs();
  DrawVisuals();

  PrintFormat("✅ ICT EA v3 init | Bias=%s | H1=%s | M5=%s | FVGPool=%d",
    EnumToString(g_Bias.bias), EnumToString(g_MiddleTrend.trend),
    EnumToString(g_TriggerTrend.trend), g_FVGCount);
  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts();
  if (EvaluateGuards())
    RunStateMachine();
  else if (g_State != EA_IDLE)
    ResetToIdle(EnumToString(g_BlockReason));
  if (InpDebugDraw) DrawVisuals();
}

void OnDeinit(const int reason)
{
  // Giữ lại trên chart: FVGP_, TFVG_, MSS_, ORD_ (post-session review)
  ObjectsDeleteAll(0, SW_PREFIX);
  ObjectsDeleteAll(0, TS_PREFIX);
  ObjectsDeleteAll(0, DBG_PREFIX);
  ChartRedraw(0);
  PrintFormat("ICT EA v3 deinit | reason=%d | pool had %d FVGs", reason, g_FVGCount);
}