//+------------------------------------------------------------------+
//| ICT Early Trend Detection EA                                     |
//| Structure + Early Key-Level Break (MSS-style)                   |
//| Clean Architecture – Meaningful Naming                          |
//| Author: Bell CW                                                  |
//+------------------------------------------------------------------+
#property strict

#define OBJ_OB_RECT   "OB_RECT"
#define OBJ_OB_LABEL  "OB_LABEL"

//====================================================
// DEBUG CONFIG
//====================================================
input bool Debug_Session = false;
input bool Debug_HTFBias = false;
input bool Debug_Trend = false;
input bool Debug_OB = false;
input bool Debug_TriggerTF = false;
input bool Debug_Order = true;
input bool Debug_DrawOnChart = true;

input int TriggerMaxScanBars = 30;

enum ENUM_OB_STATE
{
  OB_NONE = 0,     // chưa có OB nào
  OB_CANDIDATE,   // tìm được OB hợp lệ, CHƯA CHẠM
  OB_TOUCHED,      // đã chạm (mitigated), chờ trigger
  OB_USED,        // đã trade HOẶC bị invalidate (KẾT THÚC)
};

enum ENUM_BLOCK_REASON
{
    BLOCK_NONE,
    BLOCK_NO_OB,
    BLOCK_OB_NOT_TOUCHED,
    BLOCK_BIAS_MISMATCH,
    BLOCK_SESSION,
    BLOCK_DAILY_LOSS
};

ENUM_BLOCK_REASON g_BlockReason = BLOCK_NONE;

enum ENUM_OB_RESET_REASON
{
  OB_RESET_NONE,
  OB_RESET_BIAS_MISMATCH,
  OB_RESET_EXPIRED,
  OB_RESET_BAR_TIMEOUT,
  OB_RESET_CLOSE_BREAK,
  OB_RESET_INVALIDATED
};

ENUM_OB_RESET_REASON g_LastOBResetReason;

enum ENUM_EA_STEP
{
  EA_STEP_IDLE = 0,
  EA_STEP_CONTEXT,
  EA_STEP_WAIT_OB,
  EA_STEP_WAIT_TRIGGER,
  EA_STEP_ORDER_SENT
};

ENUM_EA_STEP g_EAStep = EA_STEP_IDLE;
int g_OrderSentBarIndex = -1;

//====================================================
// INPUT PARAMETERS
//====================================================
input ENUM_TIMEFRAMES BiasTimeframe = PERIOD_D1;    // TF bias cao hơn Trend TF
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H1;   // Timeframe xác định trend
input ENUM_TIMEFRAMES TriggerTimeframe = PERIOD_M5; // Timeframe kích hoạt logic

input int SwingDetectionRange = 2;         // Số nến trái/phải xác định swing
input int StructureScanLookbackBars = 50; // Số nến quét structure

input int OBMaxAliveMinutes = 180; // OB sống tối đa 180 phút

//====================================================
// SESSION FILTER (SERVER TIME)
//====================================================

// London Session
input int LondonStartHour = 8;
input int LondonEndHour = 17;
input int LondonAvoidLastMin = 60; // tránh 60 phút cuối phiên

// New York Session
input int NewYorkStartHour = 13;
input int NewYorkEndHour = 22;
input int NewYorkAvoidLastMin = 60; // tránh 60 phút cuối phiên

input double RiskPercent = 1.0; // % vốn rủi ro mỗi lệnh
input double RiskReward = 2.0;  // R:R = 1:2

input double MaxDailyLossPercent = 3.0; // Dừng lệnh nếu lỗ vượt 3% vốn trong ngày
//====================================================
// DATA STRUCTURE
//====================================================

struct TrendState
{
  int trendDirection; // 1 = uptrend, -1 = downtrend, 0 = neutral

  double latestSwingHigh;   // Swing High mới nhất
  double previousSwingHigh; // Swing High trước đó

  double latestSwingLow;   // Swing Low mới nhất
  double previousSwingLow; // Swing Low trước đó

  int latestSwingHighIndex;
  int previousSwingHighIndex;

  int latestSwingLowIndex;
  int previousSwingLowIndex;

  double currentKeyLevel; // Key level theo ICT structure

  bool earlyFlipUsedThisBar;        // Đã dùng early flip trong HTF bar này chưa
  datetime lastStructureUpdateTime; // Thời gian HTF bar cuối cùng đã xử lý
};

//====================================================
// GLOBAL STATE
//====================================================
TrendState g_TrendState;
datetime g_LastTriggerBarTime = 0;

enum ENUM_HTF_BIAS
{
  HTF_BIAS_NONE = 0,
  HTF_BIAS_UP,
  HTF_BIAS_DOWN,
  HTF_BIAS_SIDEWAY
};

struct HTFBiasState
{
  ENUM_HTF_BIAS bias;

  double rangeHigh;
  double rangeLow;

  datetime lastUpdateTime;
};

HTFBiasState g_HTFBias;

struct OBWatchState
{
  int direction; // 1 = buy, -1 = sell

  ENUM_OB_STATE state;
  datetime touchTime;  // 🔥 thời điểm chạm đầu tiên

  double obHigh;
  double obLow;
  datetime createdTime;

  int barsAlive; // số bar trigger TF đã trôi qua
  int triggerStartBar;
};

OBWatchState g_OBWatch;

struct OrderPlan
{
  bool valid;
  int direction; // 1 = buy, -1 = sell
  double entry;

  double stopLoss;
  double takeProfit;

  double riskPoints;
  double lot;
};

struct TriggerTFStructure
{
  bool valid;

  int direction; // 1 = up, -1 = down
  double lastSwingHigh;
  double lastSwingLow;

  int lastSwingHighIndex;
  int lastSwingLowIndex;

  double breakLevel;  // level sẽ bị phá
  double newKeyLevel; // 🔥 key level mới sau break
};

TriggerTFStructure g_TriggerTF;

struct DailyRiskState
{
  double startBalance;
  datetime dayStartTime;
  bool lossLimitHit;
};

DailyRiskState g_DailyRisk;

void UpdateHTFBias(
    ENUM_TIMEFRAMES biasTf,
    HTFBiasState &state)
{
  datetime tf0Time = iTime(_Symbol, biasTf, 0);
  if (tf0Time == state.lastUpdateTime)
    return;

  state.lastUpdateTime = tf0Time;

  // --- Bar 1 và Bar 2 đã đóng
  double b1Open = iOpen(_Symbol, biasTf, 1);
  double b1Close = iClose(_Symbol, biasTf, 1);
  double b1High = iHigh(_Symbol, biasTf, 1);
  double b1Low = iLow(_Symbol, biasTf, 1);

  double b2High = iHigh(_Symbol, biasTf, 2);
  double b2Low = iLow(_Symbol, biasTf, 2);

  state.rangeHigh = 0;
  state.rangeLow = 0;

  // ===== UP BIAS =====
  if (b1Close > b2High)
  {
    state.bias = HTF_BIAS_UP;
    return;
  }

  // ===== DOWN BIAS =====
  if (b1Close < b2Low)
  {
    state.bias = HTF_BIAS_DOWN;
    return;
  }

  // ===== SIDEWAY: inside bar =====
  bool insideBar =
      b1High <= b2High &&
      b1Low >= b2Low;

  if (insideBar)
  {
    state.bias = HTF_BIAS_SIDEWAY;
    state.rangeHigh = b2High;
    state.rangeLow = b2Low;
    return;
  }

  // ===== SIDEWAY: indecision =====
  bool indecision =
      b1Close < b2High &&
      b1Close > b2Low;

  if (indecision)
  {
    state.bias = HTF_BIAS_SIDEWAY;
    state.rangeHigh = b1High;
    state.rangeLow = b1Low;
    return;
  }

  state.bias = HTF_BIAS_NONE;
}

bool IsHTFBiasAligned(ENUM_HTF_BIAS bias, int trendDirection)
{
  if (bias == HTF_BIAS_UP && trendDirection == 1)
    return true;
  if (bias == HTF_BIAS_DOWN && trendDirection == -1)
    return true;

  return false;
}

bool IsDailyLossExceeded(
    DailyRiskState &risk,
    double maxLossPercent)
{
  if (risk.lossLimitHit)
    return true;

  double balance = AccountInfoDouble(ACCOUNT_BALANCE);

  double lossPct =
      (risk.startBalance - balance) / risk.startBalance * 100.0;

  if (lossPct >= maxLossPercent)
  {
    risk.lossLimitHit = true;

    PrintFormat(
        "⛔ MAX DAILY LOSS HIT | Loss=%.2f%% (Limit=%.2f%%)",
        lossPct,
        maxLossPercent);
    return true;
  }

  return false;
}

void UpdateDailyRiskState(DailyRiskState &risk)
{
  // Thời gian mở nến D1 hiện tại
  datetime dailyBarTime = iTime(_Symbol, PERIOD_D1, 0);

  if (dailyBarTime != risk.dayStartTime)
  {
    risk.dayStartTime = dailyBarTime;
    risk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    risk.lossLimitHit = false;
  }
}

void BootstrapHTFBias(
    ENUM_TIMEFRAMES biasTf,
    HTFBiasState &state)
{
  // ép reset
  state.lastUpdateTime = 0;

  // đảm bảo đủ data
  if (Bars(_Symbol, biasTf) < 5)
    return;

  UpdateHTFBias(biasTf, state);
}

void BootstrapMarketStructure(
    ENUM_TIMEFRAMES tf,
    TrendState &state)
{
  ZeroMemory(state);
  state.trendDirection = 0;
  state.lastStructureUpdateTime = 0;

  int maxBar =
      MathMin(StructureScanLookbackBars,
              Bars(_Symbol, tf) - SwingDetectionRange - 2);

  double highs[2], lows[2];
  int hiIdx[2], loIdx[2];
  int hc = 0, lc = 0;

  for (int i = SwingDetectionRange + 1; i <= maxBar; i++)
  {
    if (hc < 2 && IsSwingHighAtBar(tf, i))
    {
      highs[hc] = iHigh(_Symbol, tf, i);
      hiIdx[hc] = i;
      hc++;
    }

    if (lc < 2 && IsSwingLowAtBar(tf, i))
    {
      lows[lc] = iLow(_Symbol, tf, i);
      loIdx[lc] = i;
      lc++;
    }

    if (hc == 2 && lc == 2)
      break;
  }

  if (hc < 2 || lc < 2)
    return;

  state.latestSwingHigh = highs[0];
  state.previousSwingHigh = highs[1];
  state.latestSwingLow = lows[0];
  state.previousSwingLow = lows[1];

  state.latestSwingHighIndex = hiIdx[0];
  state.previousSwingHighIndex = hiIdx[1];
  state.latestSwingLowIndex = loIdx[0];
  state.previousSwingLowIndex = loIdx[1];

  // interpret structure
  if (state.previousSwingHigh < state.latestSwingHigh &&
      state.previousSwingLow < state.latestSwingLow)
  {
    state.trendDirection = 1;
    state.currentKeyLevel = state.latestSwingLow;
  }
  else if (state.previousSwingHigh > state.latestSwingHigh &&
           state.previousSwingLow > state.latestSwingLow)
  {
    state.trendDirection = -1;
    state.currentKeyLevel = state.latestSwingHigh;
  }
}

bool BootstrapOBCandidate(
    ENUM_TIMEFRAMES tf,
    const TrendState &trend,
    OBWatchState &ob)
{
    double h, l;
    int idx;

    if (!FindTrendOrderBlock(tf, trend, h, l, idx))
        return false;

    ob.state  = OB_CANDIDATE;   // candidate
    ob.direction   = trend.trendDirection;
    ob.obHigh      = h;
    ob.obLow       = l;
    ob.createdTime = iTime(_Symbol, tf, idx);
    ob.barsAlive   = 0;
    ob.triggerStartBar = 1;

    return true;
}

void DrawInitialContext()
{
  DrawMarketStructure(TrendTimeframe, g_TrendState);
  DrawTrendSummaryLabel(g_TrendState);
  DrawEAStateOverlay();

  // OB candidate (chưa chạm)
  if (g_OBWatch.obHigh > 0 && g_OBWatch.state == OB_CANDIDATE)
    DrawCandidateOB(g_OBWatch);
}

//====================================================
// INITIALIZATION
//====================================================
int OnInit()
{
  // ===============================
  // 0️⃣ RESET TOÀN BỘ STATE
  // ===============================
  ZeroMemory(g_TrendState);
  ZeroMemory(g_HTFBias);
  ZeroMemory(g_OBWatch);
  ZeroMemory(g_TriggerTF);
  ZeroMemory(g_DailyRisk);

  g_EAStep = EA_STEP_IDLE;
  g_LastTriggerBarTime = 0;

  // ===============================
  // 1️⃣ ENSURE HISTORY READY
  // ===============================
  if (Bars(_Symbol, TrendTimeframe) < StructureScanLookbackBars + 10 ||
      Bars(_Symbol, BiasTimeframe) < 5)
  {
    Print("⏳ Not enough historical data to initialize EA");
    return INIT_FAILED;
  }

  // ===============================
  // 2️⃣ BOOTSTRAP HTF BIAS
  // ===============================
  BootstrapHTFBias(BiasTimeframe, g_HTFBias);

  if (Debug_HTFBias)
    PrintFormat("INIT | HTF Bias = %d", g_HTFBias.bias);

  // ===============================
  // 3️⃣ BOOTSTRAP TREND STRUCTURE
  // ===============================
  BootstrapMarketStructure(TrendTimeframe, g_TrendState);

  if (!HasConfirmedMarketStructure(g_TrendState))
  {
    Print("⚠ INIT | Market structure not confirmed yet");
    return INIT_SUCCEEDED; // vẫn cho EA chạy, nhưng không trade
  }

  if (Debug_Trend)
  {
    PrintFormat(
      "INIT | Trend=%d | H0=%.2f | H1=%.2f | L0=%.2f | L1=%.2f",
      g_TrendState.trendDirection,
      g_TrendState.latestSwingHigh,
      g_TrendState.previousSwingHigh,
      g_TrendState.latestSwingLow,
      g_TrendState.previousSwingLow
    );
  }

  // ===============================
  // 4️⃣ BOOTSTRAP OB CANDIDATE
  // ===============================
  if (IsHTFBiasAligned(g_HTFBias.bias, g_TrendState.trendDirection))
  {
    bool obFound = BootstrapOBCandidate(
        TrendTimeframe,
        g_TrendState,
        g_OBWatch);

    if (obFound)
    {
      g_EAStep = EA_STEP_WAIT_OB;

      if (Debug_OB)
        PrintFormat(
          "INIT | OB Candidate [%0.2f - %0.2f]",
          g_OBWatch.obLow,
          g_OBWatch.obHigh
        );
    }
    else
    {
      if (Debug_OB)
        Print("INIT | No valid OB candidate found");
    }
  }
  else
  {
    if (Debug_HTFBias)
      Print("INIT | Bias not aligned with trend → skip OB bootstrap");
  }

  Print("✅ ICT Early Trend Detection EA initialized (BOOTSTRAPPED)");

  DrawInitialContext();

  return INIT_SUCCEEDED;
}


//====================================================
// BAR UTILITY
//====================================================

bool IsNewBarFormed(ENUM_TIMEFRAMES timeframe, datetime &lastBarTime)
{
  datetime currentBarTime = iTime(_Symbol, timeframe, 0);
  if (currentBarTime != lastBarTime)
  {
    lastBarTime = currentBarTime;
    return true;
  }
  return false;
}

//====================================================
// SWING DETECTION (GENERIC)
//====================================================

bool IsSwingHighAtBar(
    ENUM_TIMEFRAMES timeframe,
    int barIndex)
{
  double highPrice = iHigh(_Symbol, timeframe, barIndex);

  for (int offset = 1; offset <= SwingDetectionRange; offset++)
  {
    if (iHigh(_Symbol, timeframe, barIndex - offset) >= highPrice)
      return false;
    if (iHigh(_Symbol, timeframe, barIndex + offset) >= highPrice)
      return false;
  }
  return true;
}

bool IsSwingLowAtBar(
    ENUM_TIMEFRAMES timeframe,
    int barIndex)
{
  double lowPrice = iLow(_Symbol, timeframe, barIndex);

  for (int offset = 1; offset <= SwingDetectionRange; offset++)
  {
    if (iLow(_Symbol, timeframe, barIndex - offset) <= lowPrice)
      return false;
    if (iLow(_Symbol, timeframe, barIndex + offset) <= lowPrice)
      return false;
  }
  return true;
}

//====================================================
// STRUCTURE VALIDATION
//====================================================

bool HasConfirmedMarketStructure(const TrendState &state)
{
  return (
      state.latestSwingHigh > 0 &&
      state.previousSwingHigh > 0 &&
      state.latestSwingLow > 0 &&
      state.previousSwingLow > 0);
}

//====================================================
// STRUCTURE UPDATE (TIMEFRAME AGNOSTIC)
//====================================================

void UpdateMarketStructure(
    ENUM_TIMEFRAMES timeframe,
    TrendState &state)
{
  datetime currentStructureBarTime = iTime(_Symbol, timeframe, 0);
  if (currentStructureBarTime == state.lastStructureUpdateTime)
    return;

  state.lastStructureUpdateTime = currentStructureBarTime;
  state.earlyFlipUsedThisBar = false;

  double detectedSwingHighs[2];
  double detectedSwingLows[2];
  int detectedSwingHighIndices[2];
  int detectedSwingLowIndices[2];

  int highCount = 0;
  int lowCount = 0;

  for (int barIndex = SwingDetectionRange + 1;
       barIndex < StructureScanLookbackBars;
       barIndex++)
  {
    if (highCount < 2 && IsSwingHighAtBar(timeframe, barIndex))
    {
      detectedSwingHighs[highCount] = iHigh(_Symbol, timeframe, barIndex);
      detectedSwingHighIndices[highCount] = barIndex;
      highCount++;
    }

    if (lowCount < 2 && IsSwingLowAtBar(timeframe, barIndex))
    {
      detectedSwingLows[lowCount] = iLow(_Symbol, timeframe, barIndex);
      detectedSwingLowIndices[lowCount] = barIndex;
      lowCount++;
    }

    if (highCount == 2 && lowCount == 2)
      break;
  }

  if (highCount < 2 || lowCount < 2) {
    if(Debug_Trend)
      Print("⏳ Waiting for enough swing points...");
    return;
  }

  state.latestSwingHigh = detectedSwingHighs[0];
  state.previousSwingHigh = detectedSwingHighs[1];
  state.latestSwingLow = detectedSwingLows[0];
  state.previousSwingLow = detectedSwingLows[1];

  state.latestSwingHighIndex = detectedSwingHighIndices[0];
  state.previousSwingHighIndex = detectedSwingHighIndices[1];
  state.latestSwingLowIndex = detectedSwingLowIndices[0];
  state.previousSwingLowIndex = detectedSwingLowIndices[1];

  // ===== STRUCTURE INTERPRETATION =====
  if (state.previousSwingHigh < state.latestSwingHigh &&
      state.previousSwingLow < state.latestSwingLow)
  {
    state.trendDirection = 1;
    state.currentKeyLevel = state.latestSwingLow;
  }
  else if (state.previousSwingHigh > state.latestSwingHigh &&
           state.previousSwingLow > state.latestSwingLow)
  {
    state.trendDirection = -1;
    state.currentKeyLevel = state.latestSwingHigh;
  }
}

//====================================================
// EARLY TREND FLIP (MSS-STYLE)
//====================================================

void CheckForEarlyTrendFlip(
    TrendState &state,
    double currentPrice)
{
  if (!HasConfirmedMarketStructure(state))
    return;
  if (state.earlyFlipUsedThisBar)
    return;

  if (state.trendDirection == 1 &&
      currentPrice < state.currentKeyLevel)
  {
    state.trendDirection = -1;
    state.currentKeyLevel = state.latestSwingHigh;
    state.earlyFlipUsedThisBar = true;
  }
  else if (state.trendDirection == -1 &&
           currentPrice > state.currentKeyLevel)
  {
    state.trendDirection = 1;
    state.currentKeyLevel = state.latestSwingLow;
    state.earlyFlipUsedThisBar = true;
  }
}

//====================================================
// SESSION GUARD
//====================================================

bool IsWithinSession(
    int currentMinutes,
    int sessionStartHour,
    int sessionEndHour,
    int avoidLastMinutes)
{
  int sessionStartMin = sessionStartHour * 60;
  int sessionEndMin = sessionEndHour * 60;

  // Trong phiên
  if (currentMinutes < sessionStartMin ||
      currentMinutes >= sessionEndMin)
    return false;

  // Tránh cuối phiên
  if (currentMinutes >= (sessionEndMin - avoidLastMinutes))
    return false;

  return true;
}

bool IsTradingSessionAllowed()
{
  datetime now = TimeCurrent();

  MqlDateTime tm;
  TimeToStruct(now, tm);

  int currentMinutes = tm.hour * 60 + tm.min;

  if (IsWithinSession(currentMinutes,
                      LondonStartHour,
                      LondonEndHour,
                      LondonAvoidLastMin))
    return true;

  if (IsWithinSession(currentMinutes,
                      NewYorkStartHour,
                      NewYorkEndHour,
                      NewYorkAvoidLastMin))
    return true;

  return false;
}

bool HasPriceTouchedOB(
    int direction,
    double obHigh,
    double obLow,
    double price)
{
  if (direction == 1) // buy
    return price <= obHigh && price >= obLow;

  if (direction == -1) // sell
    return price >= obLow && price <= obHigh;

  return false;
}

bool FindTrendOrderBlock(
    ENUM_TIMEFRAMES timeframe,
    const TrendState &trend,
    double &obHigh,
    double &obLow,
    int &obCandleIndex)
{
    obHigh = 0;
    obLow = 0;
    obCandleIndex = -1;

    // ===== XÁC ĐỊNH VÙNG QUÉT =====
    int scanFrom, scanTo;

    if (trend.trendDirection == 1)
    {
        // Uptrend: OB phải nằm giữa L1 -> L0
        scanFrom = trend.latestSwingLowIndex - 1;
        scanTo   = trend.previousSwingLowIndex + 1;
    }
    else if (trend.trendDirection == -1)
    {
        // Downtrend: OB phải nằm giữa H1 -> H0
        scanFrom = trend.latestSwingHighIndex - 1;
        scanTo   = trend.previousSwingHighIndex + 1;
    }
    else
        return false;

    scanFrom = MathMax(scanFrom, 1);
    scanTo   = MathMax(scanTo, 1);

    // ===== QUÉT OB =====
    for (int i = scanFrom; i >= scanTo; i--)
    {
        double open  = iOpen(_Symbol, timeframe, i);
        double close = iClose(_Symbol, timeframe, i);

        // ===== NẾN NGƯỢC TREND =====
        bool isBear = close < open;
        bool isBull = close > open;

        if ((trend.trendDirection == 1 && !isBear) ||
            (trend.trendDirection == -1 && !isBull))
            continue;

        double h = iHigh(_Symbol, timeframe, i);
        double l = iLow(_Symbol, timeframe, i);

        // ===== RANGE FILTER =====
        if (MathAbs(h - l) < 10 * _Point)
            continue;

        // ===== FILTER 1: OB PHẢI NẰM TRONG CON SÓNG =====
        if (trend.trendDirection == 1 && l < trend.latestSwingLow)
            continue;

        if (trend.trendDirection == -1 && h > trend.latestSwingHigh)
            continue;

        // ===== FILTER 2: CHƯA BỊ MITIGATION =====
        bool mitigated = false;
        for (int j = i - 1; j >= 1; j--)
        {
            double price = iClose(_Symbol, timeframe, j);
            if (HasPriceTouchedOB(trend.trendDirection, h, l, price))
            {
                mitigated = true;
                break;
            }
        }
        if (mitigated)
            continue;

        // ===== FILTER 3: CHƯA BỊ CLOSE BREAK (HTF) =====
        if (IsOBCloseBreak(trend.trendDirection, h, l))
            continue;

        // ===== OK → OB HỢP LỆ =====
        obHigh = h;
        obLow  = l;
        obCandleIndex = i;
        return true;
    }

    return false;
}

void ResetOBWatch()
{
  g_OBWatch.state = OB_NONE;
  g_OBWatch.touchTime = 0;

  g_OBWatch.direction = 0;
  g_OBWatch.obHigh = 0;
  g_OBWatch.obLow  = 0;
  g_OBWatch.createdTime = 0;

  DebugLabel("EA_OB_RESET", 
    StringFormat("OB Reset Reason=%d", g_LastOBResetReason),
    130, 
    clrRed
  );

}

bool IsOBInvalidated(
    int direction,
    double obHigh,
    double obLow,
    double price)
{
  if (direction == 1) // buy
    return price < obLow;

  if (direction == -1) // sell
    return price > obHigh;

  return false;
}

void ResetTriggerTFStructure()
{
  ZeroMemory(g_TriggerTF);
}

bool IsTriggerTFStructureBreak(
    const TriggerTFStructure &ts,
    int trendDirection,
    ENUM_TIMEFRAMES tf)
{
  if (!ts.valid)
    return false;

  double high = iHigh(_Symbol, tf, 1);
  double low = iLow(_Symbol, tf, 1);

  if (trendDirection == 1)
    return high > ts.breakLevel;

  if (trendDirection == -1)
    return low < ts.breakLevel;

  return false;
}

void UpdateTriggerTFStructure(
    ENUM_TIMEFRAMES tf,
    TriggerTFStructure &ts,
    int startBar)
{
  double sh = 0.0;
  double sl = 0.0;
  int shi = -1;
  int sli = -1;

  bool foundHigh = false;
  bool foundLow = false;

  for (int i = startBar + SwingDetectionRange;
       i < startBar + TriggerMaxScanBars;
       i++)
  {
    if (!foundHigh && IsSwingHighAtBar(tf, i))
    {
      sh = iHigh(_Symbol, tf, i);
      shi = i;
      foundHigh = true;
    }

    if (!foundLow && IsSwingLowAtBar(tf, i))
    {
      sl = iLow(_Symbol, tf, i);
      sli = i;
      foundLow = true;
    }

    if (foundHigh && foundLow)
      break;
  }

  if (!foundHigh || !foundLow)
    return;

  ts.lastSwingHigh = sh;
  ts.lastSwingLow = sl;
  ts.lastSwingHighIndex = shi;
  ts.lastSwingLowIndex = sli;

  ts.direction = g_TrendState.trendDirection;
  ts.valid = true;

  if (ts.direction == 1)
  {
    ts.breakLevel = ts.lastSwingHigh;
    ts.newKeyLevel = ts.lastSwingLow;
  }
  else
  {
    ts.breakLevel = ts.lastSwingLow;
    ts.newKeyLevel = ts.lastSwingHigh;
  }
}

void CheckOBTouchAndActivate(
    const TrendState &trend,
    double currentPrice)
{
    // Chỉ xử lý khi có OB candidate đang chờ active
    if (g_OBWatch.state != OB_CANDIDATE) return;

    // Kiểm tra giá chạm OB đang theo dõi
    if (!HasPriceTouchedOB(
            g_OBWatch.direction,
            g_OBWatch.obHigh,
            g_OBWatch.obLow,
            currentPrice))
    {
        g_BlockReason = BLOCK_OB_NOT_TOUCHED;
        return;
    }

    // ===== OB BỊ MITIGATE =====
    MarkOBAsTouched(g_OBWatch, TriggerTimeframe);

    if (Debug_OB)
    {
        PrintFormat(
            "🟦 OB MITIGATED | dir=%d | OB[%.2f - %.2f]",
            g_OBWatch.direction,
            g_OBWatch.obLow,
            g_OBWatch.obHigh);
    }
}

void HandleOBWatching(
    const TrendState &trend,
    double currentPrice)
{
  // 1️⃣ Bias hoặc trend không còn hợp lệ
  if (!IsHTFBiasAligned(g_HTFBias.bias, trend.trendDirection))
  {
    g_LastOBResetReason = OB_RESET_BIAS_MISMATCH; // DEBUG
    ResetOBWatch();
    return;
  }

  // 2️⃣ Giá đóng nến xuyên qua OB
  if (IsOBCloseBreak(g_OBWatch.direction,
                     g_OBWatch.obHigh,
                     g_OBWatch.obLow))
  {
    g_LastOBResetReason = OB_RESET_CLOSE_BREAK; // DEBUG
    MarkOBAsUsed(); // đánh dấu đã dùng
    return;
  }

  // 3️⃣ OB bị phá sâu (tick safety)
  if (IsOBInvalidated(g_OBWatch.direction,
                      g_OBWatch.obHigh,
                      g_OBWatch.obLow,
                      currentPrice))
  {
    g_LastOBResetReason = OB_RESET_INVALIDATED; // DEBUG
    MarkOBAsUsed(); // đánh dấu đã dùng
    return;
  }

  // 4️⃣ OB quá hạn
  if (IsOBExpired(g_OBWatch))
  {
    g_LastOBResetReason = OB_RESET_EXPIRED; // DEBUG
    ResetOBWatch();
    return;
  }

  // 5️⃣ Trigger quá chậm
  g_OBWatch.barsAlive++;
  if (g_OBWatch.barsAlive > 150) // ~30 bar M5 = ~150 phút
  {
    g_LastOBResetReason = OB_RESET_BAR_TIMEOUT; // DEBUG
    ResetOBWatch();
    return;
  }

  // =================================================
  // 🔥 TRIGGER TF STRUCTURE LOGIC (CHỖ QUAN TRỌNG)
  // =================================================
  UpdateTriggerTFStructure(
      TriggerTimeframe,
      g_TriggerTF,
      g_OBWatch.triggerStartBar);

  if (IsTriggerTFStructureBreak(g_TriggerTF,
                                trend.trendDirection,
                                TriggerTimeframe))
  {
    OrderPlan plan =
        BuildOrderPlanFromTriggerTF(g_TriggerTF,
                                    TriggerTimeframe);

    if (plan.valid)
    {
      plan.lot = CalculateRiskLot(plan.entry, plan.stopLoss);

      if (plan.lot <= 0)
        return;

      ExecuteOrder(plan);

      PrintFormat(
          "🎯 ENTRY CONFIRMED | dir=%d | entry=%.2f | SL=%.2f | TP=%.2f | RR=1:%.1f",
          plan.direction,
          plan.entry,
          plan.stopLoss,
          plan.takeProfit,
          RiskReward);
    }
  }
}

bool IsOBExpired(const OBWatchState &ob)
{
  if (ob.createdTime <= 0)
    return false;

  int aliveSec = (int)(TimeCurrent() - ob.createdTime);
  return aliveSec > OBMaxAliveMinutes * 60;
}

void MarkOBAsUsed()
{
  g_OBWatch.state = OB_USED;
}

void MarkOBAsTouched(
    OBWatchState &ob,
    ENUM_TIMEFRAMES triggerTf)
{
  if (ob.state != OB_CANDIDATE) return;

  ob.state = OB_TOUCHED;

  // Thời điểm chạm đầu tiên (bar đã đóng)
  ob.touchTime = iTime(_Symbol, triggerTf, 1);

  // Reset trigger waiting
  ob.barsAlive = 0;
  ob.triggerStartBar = 1;

  // Reset trigger TF structure
  ResetTriggerTFStructure();

  if (Debug_OB)
  {
    PrintFormat(
        "🟦 OB TOUCHED | dir=%d | OB[%.2f - %.2f]",
        ob.direction,
        ob.obLow,
        ob.obHigh
    );
  }
}


bool IsOBCloseBreak(
    int direction,
    double obHigh,
    double obLow)
{
  double close = iClose(_Symbol, TrendTimeframe, 1);

  if (direction == 1) // buy OB
    return close < obLow;

  if (direction == -1) // sell OB
    return close > obHigh;

  return false;
}

bool IsTriggerKeyLevelBreak(
    const TrendState &trend,
    ENUM_TIMEFRAMES triggerTf)
{
  double close = iClose(_Symbol, triggerTf, 1);

  if (trend.trendDirection == 1)
    return close > trend.currentKeyLevel;

  if (trend.trendDirection == -1)
    return close < trend.currentKeyLevel;

  return false;
}

OrderPlan BuildOrderPlanFromTriggerTF(
    const TriggerTFStructure &ts,
    ENUM_TIMEFRAMES tf)
{
  OrderPlan plan;
  ZeroMemory(plan);

  double entryPrice = iClose(_Symbol, tf, 1);

  plan.valid = true;
  plan.direction = ts.direction;
  plan.entry = (ts.direction == 1)
                   ? g_OBWatch.obHigh // buy tại đỉnh OB
                   : g_OBWatch.obLow; // sell tại đáy OB

  double riskPoints;

  // ===== BUY =====
  if (ts.direction == 1)
  {
    plan.stopLoss = MathMin(ts.newKeyLevel, g_OBWatch.obLow);

    riskPoints = plan.entry - plan.stopLoss;
    if (riskPoints <= 0)
    {
      plan.valid = false;
      return plan;
    }

    plan.takeProfit = plan.entry + riskPoints * RiskReward;
  }
  // ===== SELL =====
  else
  {
    plan.stopLoss = MathMax(ts.newKeyLevel, g_OBWatch.obHigh);

    riskPoints = plan.stopLoss - plan.entry;
    if (riskPoints <= 0)
    {
      plan.valid = false;
      return plan;
    }

    plan.takeProfit = plan.entry - riskPoints * RiskReward;
  }

  return plan;
}

double CalculateRiskLot(
    double entryPrice,
    double stopLossPrice)
{
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = equity * RiskPercent / 100.0;

  double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
  if (contractSize <= 0)
    return 0;

  double slDistance = MathAbs(entryPrice - stopLossPrice);
  if (slDistance <= _Point)
    return 0;

  // Cost cho 1 lot nếu SL hit
  double costPerLot = slDistance * contractSize;

  if (costPerLot <= 0)
    return 0;

  double rawLot = riskMoney / costPerLot;

  // ===== Normalize theo broker =====
  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

  rawLot = MathMax(minLot, MathMin(rawLot, maxLot));
  rawLot = MathFloor(rawLot / lotStep) * lotStep;

  return NormalizeDouble(rawLot, 2);
}

void ExecuteOrder(const OrderPlan &plan)
{
  if (!plan.valid)
    return;

  MqlTradeRequest req;
  MqlTradeResult res;
  ZeroMemory(req);
  ZeroMemory(res);

  req.action = TRADE_ACTION_PENDING;
  req.symbol = _Symbol;
  req.volume = plan.lot;
  req.type = plan.direction == 1 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
  req.price = plan.entry;

  req.sl = plan.stopLoss;
  req.tp = plan.takeProfit;
  req.deviation = 5;
  req.magic = 202501;
  req.comment = "ICT_OB_Trigger";

  bool sent = OrderSend(req, res);

  if (!sent || res.retcode != TRADE_RETCODE_DONE)
  {
    PrintFormat(
        "❌ OrderSend failed | sent=%d | retcode=%d",
        sent,
        res.retcode);
    return;
  }
  else
  {
    g_EAStep = EA_STEP_ORDER_SENT; // DEBUG
    g_OrderSentBarIndex = Bars(_Symbol, TriggerTimeframe); // DEBUG: 🔑 bar hiện tại để dễ nhìn

    PrintFormat(
        "✅ ORDER SENT | lot=%.2f | entry=%.2f | SL=%.2f | TP=%.2f",
        plan.lot,
        plan.entry,
        plan.stopLoss,
        plan.takeProfit);
    MarkOBAsUsed();
  }
}

bool IsOBCandidateStillValid(
    const OBWatchState &ob,
    const TrendState &trend)
{
    // OB phải cùng direction
    if (ob.direction != trend.trendDirection)
        return false;

    // OB phải nằm trong con sóng hiện tại
    if (trend.trendDirection == 1) // uptrend
    {
        if (ob.obLow < trend.previousSwingLow ||
            ob.obLow > trend.latestSwingLow)
            return false;
    }
    else // downtrend
    {
        if (ob.obHigh > trend.previousSwingHigh ||
            ob.obHigh < trend.latestSwingHigh)
            return false;
    }

    return true;
}

void OnTick()
{
    // ===== RUN ON NEW BAR (TRIGGER TF) =====
    if (!IsNewBarFormed(TriggerTimeframe, g_LastTriggerBarTime))
        return;

    // =============================
    // STEP HOLD AFTER ORDER SENT
    // =============================
    if (g_EAStep == EA_STEP_ORDER_SENT)
    {
        int currentBar = Bars(_Symbol, TriggerTimeframe);
        if (currentBar <= g_OrderSentBarIndex)
        {
            DrawEAStateOverlay();
            return;
        }
        g_OrderSentBarIndex = -1;
    }

    g_EAStep = EA_STEP_IDLE;

    // =============================
    // SESSION & RISK GUARD
    // =============================
    if (!IsTradingSessionAllowed())
    {
        g_BlockReason = BLOCK_SESSION;
        DrawEAStateOverlay();
        return;
    }

    UpdateDailyRiskState(g_DailyRisk);
    if (IsDailyLossExceeded(g_DailyRisk, MaxDailyLossPercent))
    {
        g_BlockReason = BLOCK_DAILY_LOSS;
        DrawEAStateOverlay();
        return;
    }

    // =============================
    // CONTEXT UPDATE
    // =============================
    g_EAStep = EA_STEP_CONTEXT;

    UpdateHTFBias(BiasTimeframe, g_HTFBias);
    UpdateMarketStructure(TrendTimeframe, g_TrendState);

    double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    CheckForEarlyTrendFlip(g_TrendState, currentBid);

    if (!IsHTFBiasAligned(g_HTFBias.bias, g_TrendState.trendDirection))
    {
        g_BlockReason = BLOCK_BIAS_MISMATCH;
        DrawEAStateOverlay();
        return;
    }

    // =====================================================
    // 🔥 PHASE 0.5: VALIDATE EXISTING OB CANDIDATE
    // =====================================================
    if (g_OBWatch.state == OB_CANDIDATE)
    {
      if (!IsOBCandidateStillValid(g_OBWatch, g_TrendState))
      {
        g_LastOBResetReason = OB_RESET_INVALIDATED; // hoặc OB_RESET_STRUCTURE_CHANGED
        ResetOBWatch();

        if (Debug_OB)
            Print("🔴 OB INVALIDATED → STRUCTURE CHANGED");
      }
    }

    // =====================================================
    // 🔥 PHASE 0: NO OB → FIND NEW OB CANDIDATE
    // =====================================================
    if (g_OBWatch.state != OB_CANDIDATE && g_OBWatch.state != OB_TOUCHED)
    {
        g_EAStep = EA_STEP_WAIT_OB;

        bool found = BootstrapOBCandidate(
            TrendTimeframe,
            g_TrendState,
            g_OBWatch
        );

        if (found && Debug_OB)
        {
            PrintFormat(
                "🟧 NEW OB CANDIDATE | dir=%d | [%.2f - %.2f]",
                g_OBWatch.direction,
                g_OBWatch.obLow,
                g_OBWatch.obHigh
            );
        }
    }

    // =====================================================
    // 🔵 PHASE 1: OB CANDIDATE → WAIT FOR TOUCH
    // =====================================================
    else if (g_OBWatch.state == OB_CANDIDATE)
    {
      g_EAStep = EA_STEP_WAIT_OB;
      CheckOBTouchAndActivate(g_TrendState, currentBid);
    }
    // =====================================================
    // 🟦 PHASE 2: OB TOUCHED → WAIT TRIGGER
    // =====================================================
    else if (g_OBWatch.state == OB_TOUCHED)
    {
      g_EAStep = EA_STEP_WAIT_TRIGGER;
      HandleOBWatching(g_TrendState, currentBid);
    }

    // =============================
    // DRAW
    // =============================
    DrawMarketStructure(TrendTimeframe, g_TrendState);
    DrawTrendSummaryLabel(g_TrendState);
    DrawEAStateOverlay();

    if (g_OBWatch.state == OB_CANDIDATE && g_OBWatch.state != OB_TOUCHED)
        DrawCandidateOB(g_OBWatch);

    if (g_OBWatch.state == OB_TOUCHED)
        DrawTouchedOB(g_OBWatch);
}

void DebugPrint(bool enabled, string message)
{
  if (!enabled)
    return;
  Print(message);
}

//----------------------------------------------------
void DebugLabel(string name, string text, int y, color clr)
{
  if (!Debug_DrawOnChart)
    return;

  ObjectDelete(0, name);
  ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
  ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
  ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
  ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//====================================================
// DRAWING UTILITIES
//====================================================

void DrawEAStateOverlay()
{
  string stepText;
  color stepColor = clrGray;

  switch (g_EAStep)
  {
  case EA_STEP_IDLE:
    stepText = "STEP 0: IDLE / GUARD";
    stepColor = clrSilver;
    break;

  case EA_STEP_CONTEXT:
    stepText = "STEP 1: CONTEXT OK";
    stepColor = clrAqua;
    break;

  case EA_STEP_WAIT_OB:
    stepText = "STEP 2: WAIT OB TOUCH";
    stepColor = clrOrange;
    break;

  case EA_STEP_WAIT_TRIGGER:
    stepText = "STEP 3: WAIT TRIGGER";
    stepColor = clrYellow;
    break;

  case EA_STEP_ORDER_SENT:
    stepText = "STEP 4: ORDER SENT";
    stepColor = clrLime;
    break;
  }

  DebugLabel("EA_STATE", stepText, 40, stepColor);

  DebugLabel("EA_TREND",
             StringFormat("Trend=%d | Bias=%d",
                          g_TrendState.trendDirection,
                          g_HTFBias.bias),
             70, clrWhite);

  if (g_OBWatch.state == OB_CANDIDATE)
  {
    DebugLabel("EA_OB",
               StringFormat("OB [%0.2f - %0.2f] alive=%d",
                            g_OBWatch.obLow,
                            g_OBWatch.obHigh,
                            g_OBWatch.barsAlive),
               100, clrOrange);
  }
}

void DrawSwingLabel(
    string objectName,
    string labelText,
    ENUM_TIMEFRAMES timeframe,
    int barIndex,
    double price,
    color labelColor)
{
  if (barIndex < 0 || price <= 0)
    return;

  datetime barTime = iTime(_Symbol, timeframe, barIndex);

  ObjectDelete(0, objectName);
  ObjectCreate(0, objectName, OBJ_TEXT, 0, barTime, price);

  ObjectSetInteger(0, objectName, OBJPROP_COLOR, labelColor);
  ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE, 9);
  ObjectSetString(0, objectName, OBJPROP_TEXT, labelText);

  // ===== PIXEL OFFSET =====
  int SwingLabelYOffsetPx = 20;
  if (labelText == "H0" || labelText == "H1")
  {
    ObjectSetInteger(0, objectName, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
    ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, SwingLabelYOffsetPx);
  }
  else if (labelText == "L0" || labelText == "L1")
  {
    ObjectSetInteger(0, objectName, OBJPROP_ANCHOR, ANCHOR_TOP);
    ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, SwingLabelYOffsetPx);
  }
}

void DrawMarketStructure(
    ENUM_TIMEFRAMES timeframe,
    const TrendState &state)
{
  DrawSwingLabel("SWING_HIGH_LATEST", "H0", timeframe,
                 state.latestSwingHighIndex,
                 state.latestSwingHigh, clrLime);

  DrawSwingLabel("SWING_HIGH_PREVIOUS", "H1", timeframe,
                 state.previousSwingHighIndex,
                 state.previousSwingHigh, clrGreen);

  DrawSwingLabel("SWING_LOW_LATEST", "L0", timeframe,
                 state.latestSwingLowIndex,
                 state.latestSwingLow, clrRed);

  DrawSwingLabel("SWING_LOW_PREVIOUS", "L1", timeframe,
                 state.previousSwingLowIndex,
                 state.previousSwingLow, clrMaroon);
}

void DrawTrendSummaryLabel(const TrendState &state)
{
  string labelName = "TREND_SUMMARY";
  ObjectDelete(0, labelName);

  string labelText = "TREND: NEUTRAL";
  color labelColor = clrGray;

  if (state.trendDirection == 1)
  {
    labelText = StringFormat(
        "UPTREND - Key Level: %.2f%s",
        state.currentKeyLevel,
        state.earlyFlipUsedThisBar ? " -> EARLY FLIP" : "");
    labelColor = state.earlyFlipUsedThisBar ? clrOrange : clrLime;
  }
  else if (state.trendDirection == -1)
  {
    labelText = StringFormat(
        "DOWNTREND - Key Level: %.2f%s",
        state.currentKeyLevel,
        state.earlyFlipUsedThisBar ? " -> EARLY FLIP" : "");
    labelColor = state.earlyFlipUsedThisBar ? clrOrange : clrRed;
  }

  ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
  ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, 20);
  ObjectSetInteger(0, labelName, OBJPROP_COLOR, labelColor);
  ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
  ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
}

void DrawOBRectangle(
   string   name,
   datetime timeStart,
   datetime timeEnd,
   double   priceHigh,
   double   priceLow,
   color    clr,
   bool     filled = true
) {
   ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                timeStart, priceHigh,
                timeEnd,   priceLow);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   ObjectSetInteger(0, name, OBJPROP_FILL, filled);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
}

void DrawCandidateOB(const OBWatchState &ob)
{
   if(ob.state != OB_CANDIDATE) return;

   datetime now = iTime(_Symbol, TriggerTimeframe, 0);

   color clr = (ob.direction == 1)
               ? clrDodgerBlue    // buy OB
               : clrTomato;       // sell OB

   DrawOBRectangle(
      "OB_CANDIDATE",
      ob.createdTime,
      now,
      ob.obHigh,
      ob.obLow,
      clr
   );
}

void DrawTouchedOB(const OBWatchState &ob)
{
   if(ob.state != OB_TOUCHED) return;

   color clr = (ob.direction == 1)
               ? clrDeepSkyBlue
               : clrIndianRed;

   DrawOBRectangle(
      "OB_TOUCHED",
      ob.createdTime,
      ob.touchTime,
      ob.obHigh,
      ob.obLow,
      clr
   );
}

void DrawOrUpdateOBRectangle(const OBWatchState &ob)
{
    if (ob.state == OB_NONE)
        return;

    datetime endTime;

    if (ob.state == OB_CANDIDATE)
        endTime = iTime(_Symbol, TriggerTimeframe, 0); // kéo tới hiện tại
    else
        endTime = ob.touchTime; // cố định khi touched / used

    color clr;

    switch (ob.state)
    {
        case OB_CANDIDATE: clr = clrDodgerBlue; break;
        case OB_TOUCHED:   clr = clrDeepSkyBlue; break;
        case OB_USED:      clr = clrGray; break;
        default: return;
    }

    if (!ObjectFind(0, OBJ_OB_RECT))
    {
        ObjectCreate(0, OBJ_OB_RECT, OBJ_RECTANGLE, 0,
                     ob.createdTime, ob.obHigh,
                     endTime,        ob.obLow);

        ObjectSetInteger(0, OBJ_OB_RECT, OBJPROP_BACK, true);
        ObjectSetInteger(0, OBJ_OB_RECT, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, OBJ_OB_RECT, OBJPROP_FILL, true);
    }

    ObjectSetInteger(0, OBJ_OB_RECT, OBJPROP_COLOR, clr);
    ObjectMove(0, OBJ_OB_RECT, 1, endTime, ob.obLow);
}

void DrawOrUpdateOBLabel(const OBWatchState &ob)
{
    if (ob.state == OB_NONE)
        return;

    string text;
    color clr;

    switch (ob.state)
    {
        case OB_CANDIDATE:
            text = "OB: CANDIDATE";
            clr = clrDodgerBlue;
            break;

        case OB_TOUCHED:
            text = "OB: TOUCHED";
            clr = clrDeepSkyBlue;
            break;

        case OB_USED:
            text = "OB: USED";
            clr = clrGray;
            break;

        default:
            return;
    }

    datetime labelTime = ob.createdTime;
    double   labelPrice = ob.obHigh;

    if (!ObjectFind(0, OBJ_OB_LABEL))
    {
        ObjectCreate(0, OBJ_OB_LABEL, OBJ_TEXT, 0,
                     labelTime, labelPrice);
    }

    ObjectSetString(0, OBJ_OB_LABEL, OBJPROP_TEXT, text);
    ObjectSetInteger(0, OBJ_OB_LABEL, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, OBJ_OB_LABEL, OBJPROP_FONTSIZE, 9);
}
