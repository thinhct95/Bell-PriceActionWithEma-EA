//+------------------------------------------------------------------+
//| ICT EA – FVG Edition                                             |
//| Architecture : BiasTF(D1) + MiddleTF(H1) + TriggerTF(M5)       |
//| State Machine: IDLE → WAIT_TOUCH → WAIT_TRIGGER → IN_TRADE      |
//|                                                                  |
//| FVG lifecycle:                                                   |
//|   PENDING  → hình thành, chưa touch                             |
//|   TOUCHED  → giá chạm vào gap (bid inside)                      |
//|   USED     → case0=expired / case1=broken / case2=triggered      |
//|                                                                  |
//| MSS (Market Structure Shift):                                    |
//|   Xảy ra khi bar[1].close phá vỡ KeyLevel của trend hiện tại    |
//|   MiddleTF: vẽ marker M_ / TriggerTF: vẽ marker T_              |
//|   TriggerTF MSS = điều kiện case 2 entry                        |
//|                                                                  |
//| Drawing: objects KHÔNG BAO GIỜ bị xóa, chỉ update              |
//+------------------------------------------------------------------+
#property strict

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

// Shared for both MiddleTF and TriggerTF.
// Includes MSS tracking: recorded each time bar[1].close breaks the KeyLevel.
struct TFTrendContext
{
  // ── Swing structure ────────────────────────────────────────────
  MarketDir trend;
  double    h0, h1, l0, l1;
  int       idxH0, idxH1, idxL0, idxL1;
  double    keyLevel;        // L0 (uptrend) or H0 (downtrend)
  datetime  lastBarTime;     // Guard: recalculate only on new bar

  // ── MSS tracking ───────────────────────────────────────────────
  // lastMssTime  : open time of the bar whose close broke keyLevel
  // lastMssLevel : the key level that was broken
  // lastMssBreak : DIR_UP   = close > KL  (bear→bull flip)
  //                DIR_DOWN = close < KL  (bull→bear flip)
  datetime  lastMssTime;
  double    lastMssLevel;
  MarketDir lastMssBreak;
};

struct FVGRecord  // Direct array access only – no & ref
{
  int       id;
  FVGStatus status;
  int       usedCase;              // 0=expired 1=broken 2=triggered
  MarketDir direction;
  double    high, low, mid;
  datetime  createdTime;
  datetime  touchTime;             // Tick time when bid first entered gap
  datetime  usedTime;
  MarketDir triggerTrendAtTouch;   // M5 trend at touch, used for case2 detect
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
  int    direction;
  double entry, stopLoss, takeProfit, lot;
};

struct DailyRiskContext
{
  double   startBalance, currentBalance;
  datetime dayStartTime;
  bool     limitHit;
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

// Chart object name prefixes
// SW_   : MiddleTF swing arrows/labels/key-level lines
// TS_   : TriggerTF swing arrows/labels/key-level lines
// MSS_  : MSS markers (both TFs, distinguished by M/T inside name)
// FVGP_ : FVG pool rectangles / midlines / labels
// DBG_  : Debug panel labels
const string SW_PREFIX   = "SW_";
const string TS_PREFIX   = "TS_";
const string MSS_PREFIX  = "MSS_";
const string FVGP_PREFIX = "FVGP_";
const string DBG_PREFIX  = "DBG_";

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
// Called once per bar on each TF. Does two things:
//
// 1. MSS CHECK (before re-scan):
//    Compares bar[1].close against the CURRENT keyLevel.
//    If close breaks below L0 (uptrend) or above H0 (downtrend):
//      → records MSS event in ctx.lastMssTime / lastMssLevel / lastMssBreak
//    MSS objects are drawn separately in DrawMSSMarkers().
//
// 2. SWING RE-SCAN:
//    Finds new H0/H1/L0/L1 from bar data and resolves trend.
//    keyLevel may change after re-scan (new L0 or H0).
//
// Note: MSS is detected BEFORE re-scan so we capture the old keyLevel
// that was broken, not the new one computed after the flip.
//----------------------------------------------------------------------
void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime t0 = iTime(_Symbol, tf, 0);
  if (t0 == ctx.lastBarTime) return;
  ctx.lastBarTime = t0;

  // ── 1. MSS check against existing key level ─────────────────────
  if (ctx.trend != DIR_NONE && ctx.keyLevel > 0)
  {
    double   c1 = iClose(_Symbol, tf, 1);
    datetime t1 = iTime (_Symbol, tf, 1);

    bool mssHit =
      (ctx.trend == DIR_UP   && c1 < ctx.keyLevel) ||  // bull→bear: close below L0
      (ctx.trend == DIR_DOWN && c1 > ctx.keyLevel);     // bear→bull: close above H0

    if (mssHit && t1 != ctx.lastMssTime)
    {
      ctx.lastMssTime  = t1;
      ctx.lastMssLevel = ctx.keyLevel;
      ctx.lastMssBreak = (ctx.trend == DIR_UP) ? DIR_DOWN : DIR_UP;

      if (InpDebugLog)
        PrintFormat("[%s MSS] %s | KL=%.5f | close=%.5f | bar=%s",
          EnumToString(tf),
          (ctx.lastMssBreak == DIR_UP) ? "Bear→Bull ▲" : "Bull→Bear ▼",
          ctx.lastMssLevel, c1, TimeToString(t1));
    }
  }

  // ── 2. Re-scan swing structure ───────────────────────────────────
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
  ZeroMemory(g_Trigger);
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
//|                                                                  |
//|  Called once per MiddleTF bar (static guard).                    |
//|  Scans InpFVGScanBars window. Determines initial status:         |
//|    P1 → case1 (close through gap)     → USED(1)                 |
//|    P2 → touch  (wick entered gap)     → TOUCHED                 |
//|    P3 → default                       → PENDING / USED(expired) |
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

    // P1: case1 – H1 close punched through gap
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
//|                                                                  |
//|  Priority per FVG:                                               |
//|  1. Case1 : H1 bar[1] close through gap          → USED(1)      |
//|  2. Expire: PENDING age > limit                  → USED(0)      |
//|  3. Touch : bid entered gap zone                 → TOUCHED       |
//|  4. Case2 : TOUCHED + TriggerTF MSS confirmed    → USED(2)      |
//|             (wasOpposing at touch, nowAligned)                   |
//|  5. Timeout: TOUCHED too long → release active FVG (keep TOUCHED)|
//+------------------------------------------------------------------+

void UpdateFVGStatuses()
{
  double   bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double   midC1 = iClose(_Symbol, InpMiddleTF, 1);
  datetime midT1 = iTime (_Symbol, InpMiddleTF, 1);

  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;

    // ── 1. Case1 ─────────────────────────────────────────────────────
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
      // ── 2. Expire ────────────────────────────────────────────────────
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
      // ── 3. Touch ─────────────────────────────────────────────────────
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
      // ── 4. Case2 – TriggerTF MSS ─────────────────────────────────────
      // Condition: at touch the TriggerTF trend was OPPOSING the FVG direction
      //            (retracement confirmed), and NOW it has FLIPPED to align
      //            (MSS confirmed on TriggerTF → entry signal)
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
      // TODO: BuildOrderPlan() → ExecuteOrder()
      TransitionTo(EA_IN_TRADE);
    }
    else
      ResetToIdle(StringFormat("FVG #%d used(case%d) during trigger", g_FVGPool[ai].id, g_FVGPool[ai].usedCase));
    return;
  }
  if (g_FVGPool[ai].status == FVG_PENDING) { TransitionTo(EA_WAIT_TOUCH); return; }
  // Still TOUCHED – wait for case2
}

void OnStateInTrade()
{
  if (Bars(_Symbol, InpTriggerTF) <= g_TradeBarIndex) return;
  // TODO: Monitor position → ResetToIdle("trade closed") when flat
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
// DrawOneSwingPoint
//
// Generic swing-point drawing. Used for both MiddleTF and TriggerTF.
// Parameters:
//   prefix   – object name prefix ("SW_" or "TS_")
//   tf       – timeframe whose bar data supplies the time/range
//   tag      – short label ("H0" / "H1" / "L0" / "L1")
//   isHigh   – true for swing high, false for swing low
//   barIdx   – bar index on tf
//   price    – swing price
//   clr      – arrow + label color
//   isKL     – draw a dashed key-level line to bar[0]
//   arrowSz  – OBJPROP_WIDTH of arrow (2 for MTF, 1 for LTF)
//   fontSize – label font size
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

//----------------------------------------------------------------------
// DrawMiddleSwingPoints – MiddleTF (H1) H0/H1/L0/L1
// Colors: H=Aqua / L=Yellow  (brighter, thicker – higher TF)
//----------------------------------------------------------------------
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

//----------------------------------------------------------------------
// DrawTriggerSwingPoints – TriggerTF (M5) H0/H1/L0/L1
// Colors: H=Violet / L=Orange  (smaller, distinct from H1)
// Key-level line drawn for the active side (L0 in uptrend, H0 in downtrend)
//----------------------------------------------------------------------
void DrawTriggerSwingPoints()
{
  if (!InpDebugDraw) return;
  if (g_TriggerTrend.idxH0 <= 0 || g_TriggerTrend.idxH1 <= 0 ||
      g_TriggerTrend.idxL0 <= 0 || g_TriggerTrend.idxL1 <= 0)
    { ObjectsDeleteAll(0, TS_PREFIX); return; }

  bool isUp   = (g_TriggerTrend.trend == DIR_UP);
  bool isDown = (g_TriggerTrend.trend == DIR_DOWN);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "H0", true,  g_TriggerTrend.idxH0, g_TriggerTrend.h0, C'180,100,255', isDown, 1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "H1", true,  g_TriggerTrend.idxH1, g_TriggerTrend.h1, C'100,60,160',  false,  1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "L0", false, g_TriggerTrend.idxL0, g_TriggerTrend.l0, C'255,160,40',  isUp,   1, 7);
  DrawOneSwingPoint(TS_PREFIX, InpTriggerTF, "L1", false, g_TriggerTrend.idxL1, g_TriggerTrend.l1, C'160,100,20',  false,  1, 7);
}

//----------------------------------------------------------------------
// DrawMSSMarker
//
// Draws a single MSS event on the chart. Objects are named with the
// MSS bar timestamp so they accumulate without overwriting each other.
//
// Objects per MSS:
//   MSS_<id>_ARR  – arrow at close of break candle
//   MSS_<id>_LBL  – text "▲MSS" or "▼MSS" next to arrow
//   MSS_<id>_KL   – horizontal dotted line AT the broken key level
//                   (spans from break candle to current bar[0])
//
// mssId     : unique string identifier (e.g. "M_1234567890" for MiddleTF)
// tf        : timeframe of the MSS candle
// mssTime   : open time of the break candle (bar[1] when MSS was detected)
// mssLevel  : key level price that was broken
// mssBreak  : DIR_UP = broke above (bear→bull) / DIR_DOWN = broke below (bull→bear)
//----------------------------------------------------------------------
void DrawMSSMarker(
  string mssId, ENUM_TIMEFRAMES tf,
  datetime mssTime, double mssLevel, MarketDir mssBreak)
{
  if (!InpDebugDraw || mssTime == 0) return;

  string arrN = MSS_PREFIX + mssId + "_ARR";
  string lblN = MSS_PREFIX + mssId + "_LBL";
  string klN  = MSS_PREFIX + mssId + "_KL";

  bool   isBull = (mssBreak == DIR_UP);    // broke UP → bull MSS
  color  clr    = isBull ? clrLime : clrTomato;

  int    shift     = iBarShift(_Symbol, tf, mssTime);
  double closeAtMss = iClose(_Symbol, tf, shift);

  // ── Arrow at close price of MSS candle ─────────────────────────────
  if (ObjectFind(0, arrN) < 0)
    ObjectCreate(0, arrN, OBJ_ARROW, 0, mssTime, closeAtMss);
  ObjectSetInteger(0, arrN, OBJPROP_ARROWCODE, isBull ? 233 : 234); // 233=up 234=down
  ObjectSetInteger(0, arrN, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrN, OBJPROP_WIDTH,     2);
  ObjectSetInteger(0, arrN, OBJPROP_ANCHOR,    isBull ? ANCHOR_TOP : ANCHOR_BOTTOM);
  ObjectMove(0, arrN, 0, mssTime, closeAtMss);

  // ── Text label ─────────────────────────────────────────────────────
  double rng  = iHigh(_Symbol, tf, shift) - iLow(_Symbol, tf, shift);
  double lblY = isBull ? closeAtMss - rng * 0.4 : closeAtMss + rng * 0.4;
  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(0, lblN, OBJ_TEXT, 0, mssTime, lblY);
  ObjectMove(0, lblN, 0, mssTime, lblY);
  ObjectSetString (0, lblN, OBJPROP_TEXT,    isBull ? "▲MSS" : "▼MSS");
  ObjectSetInteger(0, lblN, OBJPROP_COLOR,   clr);
  ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR,  isBull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

  // ── Dotted horizontal line at broken key level ─────────────────────
  // Shows WHERE the structure broke – extends to current bar
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

//----------------------------------------------------------------------
// DrawMSSMarkers
//
// Calls DrawMSSMarker for the last recorded MSS on each TF.
// Objects are keyed by timestamp so earlier MSS events persist.
// The key-level line for the most recent MSS updates its right edge
// to bar[0] on every tick (keeping it "live" until the next MSS).
//----------------------------------------------------------------------
void DrawMSSMarkers()
{
  if (!InpDebugDraw) return;

  // MiddleTF MSS – prefix "M_<timestamp>"
  if (g_MiddleTrend.lastMssTime > 0)
  {
    string mid = "M_" + IntegerToString((int)g_MiddleTrend.lastMssTime);
    DrawMSSMarker(mid, InpMiddleTF,
      g_MiddleTrend.lastMssTime,
      g_MiddleTrend.lastMssLevel,
      g_MiddleTrend.lastMssBreak);
  }

  // TriggerTF MSS – prefix "T_<timestamp>"
  if (g_TriggerTrend.lastMssTime > 0)
  {
    string tid = "T_" + IntegerToString((int)g_TriggerTrend.lastMssTime);
    DrawMSSMarker(tid, InpTriggerTF,
      g_TriggerTrend.lastMssTime,
      g_TriggerTrend.lastMssLevel,
      g_TriggerTrend.lastMssBreak);
  }
}

//----------------------------------------------------------------------
// DrawFVGPool
//
// Right-edge rules:
//   PENDING              → live MiddleTF bar[0]
//   TOUCHED / USED + touchTime > 0 → pin to exact TriggerTF (M5) candle
//   USED case1 (touchTime = 0)     → pin to MiddleTF broken candle
//
// Colors:
//   PENDING  bull=C'0,50,110'  bear=C'90,25,0'
//   TOUCHED  bull=C'0,120,220' bear=C'220,75,0'
//   USED c2  C'0,100,0'  green
//   USED c1  C'70,0,0'   red
//   USED c0  C'50,50,50' grey
//----------------------------------------------------------------------
void DrawOneFVGRecord(int idx)
{
  if (!InpDebugDraw || idx < 0 || idx >= g_FVGCount) return;

  string sid   = IntegerToString(g_FVGPool[idx].id);
  string rectN = FVGP_PREFIX + "RECT_" + sid;
  string midN  = FVGP_PREFIX + "MID_"  + sid;
  string lblN  = FVGP_PREFIX + "LBL_"  + sid;

  // ── Right edge ────────────────────────────────────────────────────
  datetime rectEnd;
  if (g_FVGPool[idx].status == FVG_PENDING)
    rectEnd = iTime(_Symbol, InpMiddleTF, 0);
  else if (g_FVGPool[idx].touchTime > 0)
  {
    int shift = iBarShift(_Symbol, InpTriggerTF, g_FVGPool[idx].touchTime);
    rectEnd   = iTime(_Symbol, InpTriggerTF, shift);
  }
  else
  {
    int shift = iBarShift(_Symbol, InpMiddleTF, g_FVGPool[idx].usedTime);
    rectEnd   = iTime(_Symbol, InpMiddleTF, shift);
  }
  if (rectEnd <= g_FVGPool[idx].createdTime) rectEnd = iTime(_Symbol, InpMiddleTF, 0);

  // ── Fill color ────────────────────────────────────────────────────
  color fillColor;
  if      (g_FVGPool[idx].status == FVG_PENDING) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,50,110'  : C'90,25,0';
  else if (g_FVGPool[idx].status == FVG_TOUCHED) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,120,220' : C'220,75,0';
  else if (g_FVGPool[idx].usedCase == 2)          fillColor = C'0,100,0';
  else if (g_FVGPool[idx].usedCase == 1)          fillColor = C'70,0,0';
  else                                             fillColor = C'50,50,50';

  // ── Rectangle ─────────────────────────────────────────────────────
  if (ObjectFind(0, rectN) < 0)
    ObjectCreate(0, rectN, OBJ_RECTANGLE, 0,
      g_FVGPool[idx].createdTime, g_FVGPool[idx].high, rectEnd, g_FVGPool[idx].low);
  ObjectSetInteger(0, rectN, OBJPROP_COLOR, fillColor);
  ObjectSetInteger(0, rectN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, rectN, OBJPROP_BACK,  true);
  ObjectSetInteger(0, rectN, OBJPROP_WIDTH, 1);
  ObjectMove(0, rectN, 0, g_FVGPool[idx].createdTime, g_FVGPool[idx].high);
  ObjectMove(0, rectN, 1, rectEnd,                    g_FVGPool[idx].low);

  // ── Midpoint dotted line ──────────────────────────────────────────
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

  // ── Label ─────────────────────────────────────────────────────────
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

  LBL("DBG_HDR",  "── ICT EA ──", 10, clrSilver)

  // Bias
  color cB = (g_Bias.bias==BIAS_UP)?clrLime:(g_Bias.bias==BIAS_DOWN)?clrTomato:(g_Bias.bias==BIAS_SIDEWAY)?clrOrange:clrGray;
  LBL("DBG_BIAS", StringFormat("Bias : %s", EnumToString(g_Bias.bias)), 34, cB)

  // H1 trend + last MSS
  color cMT = (g_MiddleTrend.trend==DIR_UP)?clrLime:(g_MiddleTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_MT",   StringFormat("H1   : %s  KL=%.5f", EnumToString(g_MiddleTrend.trend), g_MiddleTrend.keyLevel), 58, cMT)
  if (g_MiddleTrend.lastMssTime > 0)
  {
    color cMSS = (g_MiddleTrend.lastMssBreak==DIR_UP) ? clrLime : clrTomato;
    LBL("DBG_MMSS", StringFormat("H1MSS: %s @ %s", (g_MiddleTrend.lastMssBreak==DIR_UP)?"▲":"▼", TimeToString(g_MiddleTrend.lastMssTime, TIME_MINUTES)), 82, cMSS)
  }
  else ObjectDelete(0,"DBG_MMSS");

  // M5 trend + last MSS
  color cTT = (g_TriggerTrend.trend==DIR_UP)?clrLime:(g_TriggerTrend.trend==DIR_DOWN)?clrTomato:clrGray;
  LBL("DBG_TT",   StringFormat("M5   : %s  KL=%.5f", EnumToString(g_TriggerTrend.trend), g_TriggerTrend.keyLevel), 106, cTT)
  if (g_TriggerTrend.lastMssTime > 0)
  {
    color cMSS2 = (g_TriggerTrend.lastMssBreak==DIR_UP) ? clrLime : clrTomato;
    LBL("DBG_TMSS", StringFormat("M5MSS: %s @ %s", (g_TriggerTrend.lastMssBreak==DIR_UP)?"▲":"▼", TimeToString(g_TriggerTrend.lastMssTime, TIME_MINUTES)), 130, cMSS2)
  }
  else ObjectDelete(0,"DBG_TMSS");

  // Daily risk
  double lostPct = g_DailyRisk.startBalance > 0
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance) / g_DailyRisk.startBalance * 100.0 : 0.0;
  color cR = g_DailyRisk.limitHit?clrRed:(lostPct>InpMaxDailyLossPct*0.7?clrOrange:clrLime);
  LBL("DBG_RISK", StringFormat("Risk : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct), 154, cR)
  LBL("DBG_BAL",  StringFormat("Bal  : %.2f (start %.2f)", g_DailyRisk.currentBalance, g_DailyRisk.startBalance), 178, clrSilver)
  LBL("DBG_LIM",  g_DailyRisk.limitHit?"⛔ DAILY LOSS HIT":"✅ Loss OK", 202, g_DailyRisk.limitHit?clrRed:clrLime)

  // State
  color cS = (g_State==EA_IDLE)?clrSilver:(g_State==EA_WAIT_TOUCH)?clrOrange:(g_State==EA_WAIT_TRIGGER)?clrYellow:clrLime;
  LBL("DBG_ST",   StringFormat("State: %s", EnumToString(g_State)), 226, cS)

  if (g_BlockReason != BLOCK_NONE)
    { LBL("DBG_BLK", StringFormat("Block: %s", EnumToString(g_BlockReason)), 250, clrTomato) }
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
  LBL("DBG_POOL", StringFormat("Pool : P=%d T=%d U=%d (%d/%d)", nP,nT,nU,g_FVGCount,MAX_FVG_POOL), 274, cP)

  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount)
  {
    int ai = g_ActiveFVGIdx;
    color cA = (g_FVGPool[ai].status==FVG_TOUCHED)?clrDeepSkyBlue:clrDodgerBlue;
    LBL("DBG_ACT", StringFormat("Act  : #%d %s [%.5f–%.5f] %s",
      g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
      g_FVGPool[ai].low, g_FVGPool[ai].high,
      EnumToString(g_FVGPool[ai].status)), 298, cA)
  }
  else ObjectDelete(0,"DBG_ACT");

  #undef LBL
  ChartRedraw(0);
}

void DrawVisuals()
{
  DrawMiddleSwingPoints();   // H1 H0/H1/L0/L1 + key level
  DrawTriggerSwingPoints();  // M5 H0/H1/L0/L1 + key level
  DrawMSSMarkers();          // MSS markers for both TFs
  DrawFVGPool();             // FVG rectangles
  DrawContextDebug();        // Info panel
}

//+------------------------------------------------------------------+
//|  SECTION 12 – EA LIFECYCLE                                       |
//+------------------------------------------------------------------+

int OnInit()
{
  ZeroMemory(g_Bias); ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);
  ZeroMemory(g_Trigger); ZeroMemory(g_DailyRisk);
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);
  g_FVGCount = 0; g_NextFVGId = 0;
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1;
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;

  UpdateAllContexts();
  ScanAndRegisterFVGs();
  DrawVisuals();

  PrintFormat("✅ ICT EA init | Bias=%s | H1=%s | M5=%s | FVGPool=%d",
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
  // FVGP_* and MSS_* intentionally kept on chart for post-session review
  ObjectsDeleteAll(0, SW_PREFIX);
  ObjectsDeleteAll(0, TS_PREFIX);
  ObjectsDeleteAll(0, DBG_PREFIX);
  ChartRedraw(0);
  PrintFormat("ICT EA deinit | reason=%d | pool had %d FVGs", reason, g_FVGCount);
}