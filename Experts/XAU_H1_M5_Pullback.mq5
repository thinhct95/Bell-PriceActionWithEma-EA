//+------------------------------------------------------------------+
//| ICT Early Trend Detection EA                                     |
//| Structure + Early Key-Level Break (MSS-style)                   |
//| Clean Architecture – Meaningful Naming                          |
//| Author: Bell CW                                                  |
//+------------------------------------------------------------------+
#property strict

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

  bool active;   // đang theo dõi OB
  bool used;     // OB đã được sử dụng (entry xong)

  bool touched;        // 🔥 GIÁ ĐÃ CHẠM OB
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

//====================================================
// INITIALIZATION
//====================================================
int OnInit()
{
  ZeroMemory(g_TrendState);
  g_TrendState.trendDirection = 0;
  g_TrendState.lastStructureUpdateTime = 0;

  g_HTFBias.bias = HTF_BIAS_NONE;
  g_HTFBias.rangeHigh = 0;
  g_HTFBias.rangeLow = 0;
  g_HTFBias.lastUpdateTime = 0;

  g_OBWatch.active = false;

  Print("ICT Early Trend Detection EA initialized successfully");
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

  // ===== UP TREND =====
  if (trend.trendDirection == 1)
  {
    // Bắt đầu từ swing low gần nhất (key level)
    for (int i = trend.latestSwingLowIndex - 1; i >= 1; i--)
    {
      double open = iOpen(_Symbol, timeframe, i);
      double close = iClose(_Symbol, timeframe, i);

      // Nến giảm
      if (close < open)
      {
        obHigh = iHigh(_Symbol, timeframe, i);
        obLow = iLow(_Symbol, timeframe, i);
        obCandleIndex = i;

        double range = MathAbs(obHigh - obLow);
        double minRange = 10 * _Point;

        if (range < minRange)
          continue;

        return true;
      }
    }
  }

  // ===== DOWN TREND =====
  if (trend.trendDirection == -1)
  {
    // Bắt đầu từ swing high gần nhất (key level)
    for (int i = trend.latestSwingHighIndex - 1; i >= 1; i--)
    {
      double open = iOpen(_Symbol, timeframe, i);
      double close = iClose(_Symbol, timeframe, i);

      // Nến tăng
      if (close > open)
      {
        obHigh = iHigh(_Symbol, timeframe, i);
        obLow = iLow(_Symbol, timeframe, i);
        obCandleIndex = i;

        double range = MathAbs(obHigh - obLow);
        double minRange = 10 * _Point;

        if (range < minRange)
          continue;

        return true;
      }
    }
  }

  return false;
}

void ResetOBWatch()
{
  g_OBWatch.active  = false;
  g_OBWatch.used    = false;
  g_OBWatch.touched = false;
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
       i < startBar + StructureScanLookbackBars;
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

void TryActivateOBWatch(
    const TrendState &trend,
    double currentPrice)
{
  if (g_OBWatch.used)
    return;
  double obHigh, obLow;
  int obIndex;

  if (!FindTrendOrderBlock(TrendTimeframe,
                           trend,
                           obHigh,
                           obLow,
                           obIndex))
    return;

  g_OBWatch.active = true;
  g_OBWatch.touched = false;
  g_OBWatch.used = false;

  ResetTriggerTFStructure();
  
  g_OBWatch.direction = trend.trendDirection;
  g_OBWatch.obHigh = obHigh;
  g_OBWatch.obLow = obLow;
  g_OBWatch.createdTime = iTime(_Symbol, TriggerTimeframe, 0);
  g_OBWatch.barsAlive = 0;
  g_OBWatch.triggerStartBar = 1;

  // Debug (optional)
  PrintFormat(
      "OB WATCH ACTIVATED | dir=%d | OB[%.2f - %.2f]",
      g_OBWatch.direction,
      g_OBWatch.obLow,
      g_OBWatch.obHigh);
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
    ResetOBWatch();
    return;
  }

  // 3️⃣ OB bị phá sâu (tick safety)
  if (IsOBInvalidated(g_OBWatch.direction,
                      g_OBWatch.obHigh,
                      g_OBWatch.obLow,
                      currentPrice))
  {
    g_LastOBResetReason = OB_RESET_INVALIDATED; // DEBUG
    ResetOBWatch();
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

  // DEBUG: Touch -> Draw on chart
  if(!g_OBWatch.touched &&
   HasPriceTouchedOB(g_OBWatch.direction,
                     g_OBWatch.obHigh,
                     g_OBWatch.obLow,
                     currentPrice))
  {
    g_OBWatch.touched   = true;
    g_OBWatch.touchTime = iTime(_Symbol, TriggerTimeframe, 1);

    if(Debug_OB)
        Print("🟦 OB TOUCHED");
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
  if (!ob.active)
    return true;

  int aliveSec = (int)(TimeCurrent() - ob.createdTime);
  return aliveSec > OBMaxAliveMinutes * 60;
}

void MarkOBAsUsed()
{
  g_OBWatch.used = true;
  g_OBWatch.active = false;
}

bool IsOBCloseBreak(
    int direction,
    double obHigh,
    double obLow)
{
  double close = iClose(_Symbol, TriggerTimeframe, 1);

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

void OnTick()
{
  if (!IsNewBarFormed(TriggerTimeframe, g_LastTriggerBarTime))
    return;

  // STEP HOLD LOGIC (DEBUG PURPOSE)
  if(g_EAStep == EA_STEP_ORDER_SENT)
  {
    int currentBar = Bars(_Symbol, TriggerTimeframe);

    // giữ STEP_ORDER_SENT cho tới khi sang bar mới
    if(currentBar <= g_OrderSentBarIndex) {
        DrawEAStateOverlay(); // DEBUG
        return;
    }

    // sang bar mới → cho phép reset to IDLE
    g_OrderSentBarIndex = -1;
  }

  g_EAStep = EA_STEP_IDLE; // DEBUG

  if (!IsTradingSessionAllowed()) 
  {
    DrawEAStateOverlay(); // DEBUG
    return;
  }

  UpdateDailyRiskState(g_DailyRisk);

  if (IsDailyLossExceeded(g_DailyRisk, MaxDailyLossPercent))
  {
    DrawEAStateOverlay(); // DEBUG
    return;
  }

  g_EAStep = EA_STEP_CONTEXT; // DEBUG

  // ===== HTF BIAS =====
  UpdateHTFBias(BiasTimeframe, g_HTFBias);

  // ===== TREND STRUCTURE =====
  UpdateMarketStructure(TrendTimeframe, g_TrendState);

  double currentBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  CheckForEarlyTrendFlip(g_TrendState, currentBidPrice);

  // ===== ENTRY FILTER =====
  if (!IsHTFBiasAligned(g_HTFBias.bias, g_TrendState.trendDirection))
  {
    DrawEAStateOverlay(); // DEBUG
    return;
  }

  // ===== ORDER BLOCK FLOW =====
  if (!g_OBWatch.active)
  {
    g_EAStep = EA_STEP_WAIT_OB; // DEBUG
    TryActivateOBWatch(g_TrendState, currentBidPrice);
  }
  else
  {
    g_EAStep = EA_STEP_WAIT_TRIGGER; // DEBUG
    HandleOBWatching(g_TrendState, currentBidPrice);
  }

  DrawMarketStructure(TrendTimeframe, g_TrendState);
  DrawTrendSummaryLabel(g_TrendState);
  DrawEAStateOverlay();
  // OB đang sống (chưa bị chạm)
  if(g_OBWatch.active && !g_OBWatch.touched)
    DrawActiveOB(g_OBWatch);

  // OB đã chạm → rectangle kết thúc
  if(g_OBWatch.touched)
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

  if (g_OBWatch.active)
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
  if (barIndex < 0)
    return;

  datetime barTime = iTime(_Symbol, timeframe, barIndex);

  ObjectDelete(0, objectName);
  ObjectCreate(0, objectName, OBJ_TEXT, 0, barTime, price);
  ObjectSetInteger(0, objectName, OBJPROP_COLOR, labelColor);
  ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE, 8);
  ObjectSetString(0, objectName, OBJPROP_TEXT, labelText);
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

void DrawActiveOB(const OBWatchState &ob)
{
   if(!ob.active) return;

   datetime now = iTime(_Symbol, TriggerTimeframe, 0);

   color clr = (ob.direction == 1)
               ? clrDodgerBlue    // buy OB
               : clrTomato;       // sell OB

   DrawOBRectangle(
      "OB_ACTIVE",
      ob.createdTime,
      now,
      ob.obHigh,
      ob.obLow,
      clr
   );
}

void DrawTouchedOB(const OBWatchState &ob)
{
   if(!ob.touched) return;

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