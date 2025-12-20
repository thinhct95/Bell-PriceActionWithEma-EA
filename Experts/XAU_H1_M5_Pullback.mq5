//+------------------------------------------------------------------+
//| ICT Early Trend Detection EA                                     |
//| Structure + Early Key-Level Break (MSS-style)                   |
//| Clean Architecture – Meaningful Naming                          |
//| Author: Bell CW                                                  |
//+------------------------------------------------------------------+
#property strict

//====================================================
// INPUT PARAMETERS
//====================================================
input ENUM_TIMEFRAMES BiasTimeframe       = PERIOD_D1;  // TF bias cao hơn Trend TF
input ENUM_TIMEFRAMES TrendTimeframe      = PERIOD_H1;  // Timeframe xác định trend
input ENUM_TIMEFRAMES TriggerTimeframe    = PERIOD_M5;  // Timeframe kích hoạt logic

input int SwingDetectionRange             = 2;          // Số nến trái/phải xác định swing
input int StructureScanLookbackBars       = 150;        // Số nến quét structure

input int OBMaxAliveMinutes = 180; // OB sống tối đa 180 phút

//====================================================
// SESSION FILTER (SERVER TIME)
//====================================================

// London Session
input int LondonStartHour      = 8;
input int LondonEndHour        = 17;
input int LondonAvoidLastMin   = 60;   // tránh 60 phút cuối phiên

// New York Session
input int NewYorkStartHour     = 13;
input int NewYorkEndHour       = 22;
input int NewYorkAvoidLastMin  = 60;   // tránh 60 phút cuối phiên

input double RiskPercent = 1.0;   // % vốn rủi ro mỗi lệnh
input double RiskReward = 2.0;    // R:R = 1:2

//====================================================
// DATA STRUCTURE
//====================================================

struct TrendState
{
   int      trendDirection;          // 1 = uptrend, -1 = downtrend, 0 = neutral

   double   latestSwingHigh;          // Swing High mới nhất
   double   previousSwingHigh;        // Swing High trước đó

   double   latestSwingLow;           // Swing Low mới nhất
   double   previousSwingLow;         // Swing Low trước đó

   int      latestSwingHighIndex;
   int      previousSwingHighIndex;

   int      latestSwingLowIndex;
   int      previousSwingLowIndex;

   double   currentKeyLevel;          // Key level theo ICT structure

   bool     earlyFlipUsedThisBar;     // Đã dùng early flip trong HTF bar này chưa
   datetime lastStructureUpdateTime;  // Thời gian HTF bar cuối cùng đã xử lý
};

//====================================================
// GLOBAL STATE
//====================================================
TrendState g_TrendState;
datetime   g_LastTriggerBarTime = 0;

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
   bool     active;        // đang theo dõi OB
   int      direction;     // 1 = buy, -1 = sell
   bool     used;          // OB đã được sử dụng (entry xong)
   double   obHigh;
   double   obLow;
   datetime createdTime;
};

OBWatchState g_OBWatch;

struct OrderPlan
{
   bool    valid;

   int     direction;   // 1 = buy, -1 = sell
   double  entry;
   double  stopLoss;
   double  takeProfit;
   double  lot;
   int     sourceSwingIndex; // cây nến tạo swing bị phá
};

struct TriggerTFStructure
{
   bool     valid;

   int      direction;          // 1 = up, -1 = down
   double   lastSwingHigh;
   double   lastSwingLow;

   int      lastSwingHighIndex;
   int      lastSwingLowIndex;

   double   breakLevel;         // level sẽ bị phá
   double   newKeyLevel;        // 🔥 key level mới sau break
};

TriggerTFStructure g_TriggerTF;

void UpdateHTFBias(
   ENUM_TIMEFRAMES biasTf,
   HTFBiasState   &state
) {
   datetime tf0Time = iTime(_Symbol, biasTf, 0);
   if(tf0Time == state.lastUpdateTime)
      return;

   state.lastUpdateTime = tf0Time;

   // --- Bar 1 và Bar 2 đã đóng
   double b1Open  = iOpen (_Symbol, biasTf, 1);
   double b1Close = iClose(_Symbol, biasTf, 1);
   double b1High  = iHigh (_Symbol, biasTf, 1);
   double b1Low   = iLow  (_Symbol, biasTf, 1);

   double b2High  = iHigh (_Symbol, biasTf, 2);
   double b2Low   = iLow  (_Symbol, biasTf, 2);

   state.rangeHigh = 0;
   state.rangeLow  = 0;

   // ===== UP BIAS =====
   if(b1Close > b2High)
   {
      state.bias = HTF_BIAS_UP;
      return;
   }

   // ===== DOWN BIAS =====
   if(b1Close < b2Low)
   {
      state.bias = HTF_BIAS_DOWN;
      return;
   }

   // ===== SIDEWAY: inside bar =====
   bool insideBar =
      b1High <= b2High &&
      b1Low  >= b2Low;

   if(insideBar)
   {
      state.bias      = HTF_BIAS_SIDEWAY;
      state.rangeHigh = b2High;
      state.rangeLow  = b2Low;
      return;
   }

   // ===== SIDEWAY: indecision =====
   bool indecision =
      b1Close < b2High &&
      b1Close > b2Low;

   if(indecision)
   {
      state.bias      = HTF_BIAS_SIDEWAY;
      state.rangeHigh = b1High;
      state.rangeLow  = b1Low;
      return;
   }

   state.bias = HTF_BIAS_NONE;
}

bool IsHTFBiasAligned(
   ENUM_HTF_BIAS bias,
   int trendDirection
)
{
   if(bias == HTF_BIAS_UP   && trendDirection == 1)  return true;
   if(bias == HTF_BIAS_DOWN && trendDirection == -1) return true;

   return false;
}

//====================================================
// INITIALIZATION
//====================================================
int OnInit()
{
   ZeroMemory(g_TrendState);
   g_TrendState.trendDirection = 0;
   g_TrendState.lastStructureUpdateTime = 0;

   g_HTFBias.bias           = HTF_BIAS_NONE;
   g_HTFBias.rangeHigh      = 0;
   g_HTFBias.rangeLow       = 0;
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
   if(currentBarTime != lastBarTime)
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
   int             barIndex
)
{
   double highPrice = iHigh(_Symbol, timeframe, barIndex);

   for(int offset = 1; offset <= SwingDetectionRange; offset++)
   {
      if(iHigh(_Symbol, timeframe, barIndex - offset) >= highPrice) return false;
      if(iHigh(_Symbol, timeframe, barIndex + offset) >= highPrice) return false;
   }
   return true;
}

bool IsSwingLowAtBar(
   ENUM_TIMEFRAMES timeframe,
   int             barIndex
)
{
   double lowPrice = iLow(_Symbol, timeframe, barIndex);

   for(int offset = 1; offset <= SwingDetectionRange; offset++)
   {
      if(iLow(_Symbol, timeframe, barIndex - offset) <= lowPrice) return false;
      if(iLow(_Symbol, timeframe, barIndex + offset) <= lowPrice) return false;
   }
   return true;
}

//====================================================
// STRUCTURE VALIDATION
//====================================================

bool HasConfirmedMarketStructure(const TrendState &state)
{
   return (
      state.latestSwingHigh   > 0 &&
      state.previousSwingHigh > 0 &&
      state.latestSwingLow    > 0 &&
      state.previousSwingLow  > 0
   );
}

//====================================================
// STRUCTURE UPDATE (TIMEFRAME AGNOSTIC)
//====================================================

void UpdateMarketStructure(
   ENUM_TIMEFRAMES timeframe,
   TrendState     &state
)
{
   datetime currentStructureBarTime = iTime(_Symbol, timeframe, 0);
   if(currentStructureBarTime == state.lastStructureUpdateTime)
      return;

   state.lastStructureUpdateTime = currentStructureBarTime;
   state.earlyFlipUsedThisBar    = false;

   double detectedSwingHighs[2];
   double detectedSwingLows[2];
   int    detectedSwingHighIndices[2];
   int    detectedSwingLowIndices[2];

   int highCount = 0;
   int lowCount  = 0;

   for(int barIndex = SwingDetectionRange + 1;
       barIndex < StructureScanLookbackBars;
       barIndex++)
   {
      if(highCount < 2 && IsSwingHighAtBar(timeframe, barIndex))
      {
         detectedSwingHighs[highCount]       = iHigh(_Symbol, timeframe, barIndex);
         detectedSwingHighIndices[highCount] = barIndex;
         highCount++;
      }

      if(lowCount < 2 && IsSwingLowAtBar(timeframe, barIndex))
      {
         detectedSwingLows[lowCount]       = iLow(_Symbol, timeframe, barIndex);
         detectedSwingLowIndices[lowCount] = barIndex;
         lowCount++;
      }

      if(highCount == 2 && lowCount == 2)
         break;
   }

   if(highCount < 2 || lowCount < 2)
      return;

   state.latestSwingHigh        = detectedSwingHighs[0];
   state.previousSwingHigh      = detectedSwingHighs[1];
   state.latestSwingLow         = detectedSwingLows[0];
   state.previousSwingLow       = detectedSwingLows[1];

   state.latestSwingHighIndex   = detectedSwingHighIndices[0];
   state.previousSwingHighIndex = detectedSwingHighIndices[1];
   state.latestSwingLowIndex    = detectedSwingLowIndices[0];
   state.previousSwingLowIndex  = detectedSwingLowIndices[1];

   // ===== STRUCTURE INTERPRETATION =====
   if(state.previousSwingHigh < state.latestSwingHigh &&
      state.previousSwingLow  < state.latestSwingLow)
   {
      state.trendDirection = 1;
      state.currentKeyLevel = state.latestSwingLow;
   }
   else if(state.previousSwingHigh > state.latestSwingHigh &&
           state.previousSwingLow  > state.latestSwingLow)
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
   double      currentPrice
)
{
   if(!HasConfirmedMarketStructure(state)) return;
   if(state.earlyFlipUsedThisBar)          return;

   if(state.trendDirection == 1 &&
      currentPrice < state.currentKeyLevel)
   {
      state.trendDirection     = -1;
      state.currentKeyLevel    = state.latestSwingHigh;
      state.earlyFlipUsedThisBar = true;
   }
   else if(state.trendDirection == -1 &&
           currentPrice > state.currentKeyLevel)
   {
      state.trendDirection     = 1;
      state.currentKeyLevel    = state.latestSwingLow;
      state.earlyFlipUsedThisBar = true;
   }
}

//====================================================
// DRAWING UTILITIES
//====================================================

void DrawSwingLabel(
   string            objectName,
   string            labelText,
   ENUM_TIMEFRAMES   timeframe,
   int               barIndex,
   double            price,
   color             labelColor
)
{
   if(barIndex < 0) return;

   datetime barTime = iTime(_Symbol, timeframe, barIndex);

   ObjectDelete(0, objectName);
   ObjectCreate(0, objectName, OBJ_TEXT, 0, barTime, price);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR, labelColor);
   ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE, 8);
   ObjectSetString (0, objectName, OBJPROP_TEXT, labelText);
}

void DrawMarketStructure(
   ENUM_TIMEFRAMES timeframe,
   const TrendState &state
)
{
   DrawSwingLabel("SWING_HIGH_LATEST",   "H0", timeframe,
                  state.latestSwingHighIndex,
                  state.latestSwingHigh, clrLime);

   DrawSwingLabel("SWING_HIGH_PREVIOUS", "H1", timeframe,
                  state.previousSwingHighIndex,
                  state.previousSwingHigh, clrGreen);

   DrawSwingLabel("SWING_LOW_LATEST",    "L0", timeframe,
                  state.latestSwingLowIndex,
                  state.latestSwingLow, clrRed);

   DrawSwingLabel("SWING_LOW_PREVIOUS",  "L1", timeframe,
                  state.previousSwingLowIndex,
                  state.previousSwingLow, clrMaroon);
}

void DrawTrendSummaryLabel(const TrendState &state)
{
   string labelName = "TREND_SUMMARY";
   ObjectDelete(0, labelName);

   string labelText = "TREND: NEUTRAL";
   color  labelColor = clrGray;

   if(state.trendDirection == 1)
   {
      labelText = StringFormat(
         "UPTREND - Key Level: %.2f%s",
         state.currentKeyLevel,
         state.earlyFlipUsedThisBar ? " -> EARLY FLIP" : ""
      );
      labelColor = state.earlyFlipUsedThisBar ? clrOrange : clrLime;
   }
   else if(state.trendDirection == -1)
   {
      labelText = StringFormat(
         "DOWNTREND - Key Level: %.2f%s",
         state.currentKeyLevel,
         state.earlyFlipUsedThisBar ? " -> EARLY FLIP" : ""
      );
      labelColor = state.earlyFlipUsedThisBar ? clrOrange : clrRed;
   }

   ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, labelColor);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
   ObjectSetString (0, labelName, OBJPROP_TEXT, labelText);
}

//====================================================
// MAIN LOOP
//====================================================

//====================================================
// SESSION GUARD
//====================================================

bool IsWithinSession(
   int currentMinutes,
   int sessionStartHour,
   int sessionEndHour,
   int avoidLastMinutes
)
{
   int sessionStartMin = sessionStartHour * 60;
   int sessionEndMin   = sessionEndHour   * 60;

   // Trong phiên
   if(currentMinutes < sessionStartMin ||
      currentMinutes >= sessionEndMin)
      return false;

   // Tránh cuối phiên
   if(currentMinutes >= (sessionEndMin - avoidLastMinutes))
      return false;

   return true;
}

bool IsTradingSessionAllowed()
{
   datetime now = TimeCurrent();

   MqlDateTime tm;
   TimeToStruct(now, tm);

   int currentMinutes = tm.hour * 60 + tm.min;

   if(IsWithinSession(currentMinutes,
                      LondonStartHour,
                      LondonEndHour,
                      LondonAvoidLastMin))
      return true;

   if(IsWithinSession(currentMinutes,
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
   double price
) {
   if(direction == 1) // buy
      return price <= obHigh && price >= obLow;

   if(direction == -1) // sell
      return price >= obLow && price <= obHigh;

   return false;
}

bool FindTrendOrderBlock(
   ENUM_TIMEFRAMES   timeframe,
   const TrendState &trend,
   double           &obHigh,
   double           &obLow,
   int              &obCandleIndex
)
{
   obHigh = 0;
   obLow  = 0;
   obCandleIndex = -1;

   // ===== UP TREND =====
   if(trend.trendDirection == 1)
   {
      // Bắt đầu từ swing low gần nhất (key level)
      for(int i = trend.latestSwingLowIndex - 1; i >= 1; i--)
      {
         double open  = iOpen (_Symbol, timeframe, i);
         double close = iClose(_Symbol, timeframe, i);

         // Nến giảm
         if(close < open)
         {
            obHigh = iHigh(_Symbol, timeframe, i);
            obLow  = iLow (_Symbol, timeframe, i);
            obCandleIndex = i;
            return true;
         }
      }
   }

   // ===== DOWN TREND =====
   if(trend.trendDirection == -1)
   {
      // Bắt đầu từ swing high gần nhất (key level)
      for(int i = trend.latestSwingHighIndex - 1; i >= 1; i--)
      {
         double open  = iOpen (_Symbol, timeframe, i);
         double close = iClose(_Symbol, timeframe, i);

         // Nến tăng
         if(close > open)
         {
            obHigh = iHigh(_Symbol, timeframe, i);
            obLow  = iLow (_Symbol, timeframe, i);
            obCandleIndex = i;
            return true;
         }
      }
   }

   return false;
}

void ResetOBWatch()
{
   g_OBWatch.active      = false;
   g_OBWatch.used        = false;
   g_OBWatch.direction   = 0;
   g_OBWatch.obHigh      = 0;
   g_OBWatch.obLow       = 0;
   g_OBWatch.createdTime = 0;
}

bool IsOBInvalidated(
   int direction,
   double obHigh,
   double obLow,
   double price
) {
   if(direction == 1)   // buy
      return price < obLow;

   if(direction == -1)  // sell
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
   ENUM_TIMEFRAMES tf
)
{
   if(!ts.valid) return false;

   double close = iClose(_Symbol, tf, 1);

   if(trendDirection == 1)
      return close > ts.breakLevel;

   if(trendDirection == -1)
      return close < ts.breakLevel;

   return false;
}

void UpdateTriggerTFStructure(
   ENUM_TIMEFRAMES tf,
   TriggerTFStructure &ts
) {
   double sh, sl;
   int shi, sli;

   bool foundHigh = false;
   bool foundLow  = false;

   for(int i = SwingDetectionRange + 1; i < StructureScanLookbackBars; i++)
   {
      if(!foundHigh && IsSwingHighAtBar(tf, i))
      {
         sh  = iHigh(_Symbol, tf, i);
         shi = i;
         foundHigh = true;
      }

      if(!foundLow && IsSwingLowAtBar(tf, i))
      {
         sl  = iLow(_Symbol, tf, i);
         sli = i;
         foundLow = true;
      }

      if(foundHigh && foundLow) break;
   }

   if(!foundHigh || !foundLow) return;

   ts.lastSwingHigh = sh;
   ts.lastSwingLow  = sl;
   ts.lastSwingHighIndex = shi;
   ts.lastSwingLowIndex  = sli;

   ts.direction = g_TrendState.trendDirection;
   ts.valid = true;

   if(ts.direction == 1)
   {
      ts.breakLevel  = ts.lastSwingHigh;
      ts.newKeyLevel = ts.lastSwingLow;
   }
   else
   {
      ts.breakLevel  = ts.lastSwingLow;
      ts.newKeyLevel = ts.lastSwingHigh;
   }
}

void TryActivateOBWatch(
   const TrendState &trend,
   double            currentPrice
) {
   if(g_OBWatch.used) return;
   double obHigh, obLow;
   int    obIndex;

   if(!FindTrendOrderBlock(TrendTimeframe,
                           trend,
                           obHigh,
                           obLow,
                           obIndex))
      return;

   if(!HasPriceTouchedOB(trend.trendDirection,
                          obHigh,
                          obLow,
                          currentPrice))
      return;

   g_OBWatch.active      = true;
   ResetTriggerTFStructure();
   g_OBWatch.direction   = trend.trendDirection;
   g_OBWatch.obHigh      = obHigh;
   g_OBWatch.obLow       = obLow;
   g_OBWatch.createdTime = TimeCurrent();

   // Debug (optional)
   PrintFormat(
      "OB WATCH ACTIVATED | dir=%d | OB[%.2f - %.2f]",
      g_OBWatch.direction,
      g_OBWatch.obLow,
      g_OBWatch.obHigh
   );
}

void HandleOBWatching(
   const TrendState &trend,
   double            currentPrice
)
{
   // 1️⃣ Bias hoặc trend không còn hợp lệ
   if(!IsHTFBiasAligned(g_HTFBias.bias, trend.trendDirection))
   {
      ResetOBWatch();
      return;
   }

   // 2️⃣ OB quá hạn
   if(IsOBExpired(g_OBWatch))
   {
      ResetOBWatch();
      return;
   }

   // 3️⃣ Giá đóng nến xuyên qua OB
   if(IsOBCloseBreak(g_OBWatch.direction,
                     g_OBWatch.obHigh,
                     g_OBWatch.obLow))
   {
      ResetOBWatch();
      return;
   }

   // 4️⃣ OB bị phá sâu (tick safety)
   if(IsOBInvalidated(g_OBWatch.direction,
                      g_OBWatch.obHigh,
                      g_OBWatch.obLow,
                      currentPrice))
   {
      ResetOBWatch();
      return;
   }

   // =================================================
   // 🔥 TRIGGER TF STRUCTURE LOGIC (CHỖ QUAN TRỌNG)
   // =================================================
   if(!g_TriggerTF.valid)
   {
      UpdateTriggerTFStructure(TriggerTimeframe, g_TriggerTF);
   }

   if(IsTriggerTFStructureBreak(g_TriggerTF,
                             trend.trendDirection,
                             TriggerTimeframe))
   {
      OrderPlan plan =
         BuildOrderPlanFromTriggerTF(g_TriggerTF,
                                    TriggerTimeframe);

      if(plan.valid)
      {
         plan.lot = CalculateRiskLot(plan.entry, plan.stopLoss);

         if(plan.lot <= 0)
            return;

         ExecuteOrder(plan);

         PrintFormat(
            "🎯 ENTRY CONFIRMED | dir=%d | entry=%.2f | SL=%.2f | TP=%.2f | RR=1:%.1f",
            plan.direction,
            plan.entry,
            plan.stopLoss,
            plan.takeProfit,
            RiskReward
         );

         // === SEND ORDER Ở ĐÂY ===
         // SendMarketOrder(plan) hoặc PlacePending(plan)

         MarkOBAsUsed();
      }
   }

}

bool IsOBExpired(const OBWatchState &ob)
{
   if(!ob.active)
      return true;

   int aliveSec = (int)(TimeCurrent() - ob.createdTime);
   return aliveSec > OBMaxAliveMinutes * 60;
}

void MarkOBAsUsed()
{
   g_OBWatch.used   = true;
   g_OBWatch.active = false;
}

bool IsOBCloseBreak(
   int direction,
   double obHigh,
   double obLow
) {
   double close = iClose(_Symbol, TriggerTimeframe, 1);

   if(direction == 1)   // buy OB
      return close < obLow;

   if(direction == -1)  // sell OB
      return close > obHigh;

   return false;
}

bool IsTriggerKeyLevelBreak(
   const TrendState &trend,
   ENUM_TIMEFRAMES   triggerTf
) {
   double close = iClose(_Symbol, triggerTf, 1);

   if(trend.trendDirection == 1)
      return close > trend.currentKeyLevel;

   if(trend.trendDirection == -1)
      return close < trend.currentKeyLevel;

   return false;
}

OrderPlan BuildOrderPlanFromTriggerTF(
   const TriggerTFStructure &ts,
   ENUM_TIMEFRAMES           tf
)
{
   OrderPlan plan;
   ZeroMemory(plan);

   double entryPrice = iClose(_Symbol, tf, 1);

   plan.valid     = true;
   plan.direction = ts.direction;
   plan.entry     = entryPrice;

   double riskPoints;

   // ===== BUY =====
   if(ts.direction == 1)
   {
      plan.stopLoss = MathMin(ts.newKeyLevel, g_OBWatch.obLow);

      riskPoints = plan.entry - plan.stopLoss;
      if(riskPoints <= 0)
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
      if(riskPoints <= 0)
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
   double stopLossPrice
) {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney  = balance * RiskPercent / 100.0;

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return 0;

   double slPoints = MathAbs(entryPrice - stopLossPrice) / _Point;
   if(slPoints <= 0)
      return 0;

   double costPerLot = slPoints * (tickValue / tickSize);
   double lot        = riskMoney / costPerLot;

   // ===== Normalize theo broker =====
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(lot, maxLot));
   lot = NormalizeDouble(lot, (int)MathLog10(1.0 / lotStep));

   return lot;
}

void ExecuteOrder(const OrderPlan &plan)
{
   if(!plan.valid) return;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = plan.lot;
   req.type     = plan.direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price    = plan.direction == 1 ?
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);

   req.sl       = plan.stopLoss;
   req.tp       = plan.takeProfit;
   req.deviation= 5;
   req.magic    = 202501;
   req.comment  = "ICT_OB_Trigger";

   OrderSend(req, res);

   if(res.retcode != TRADE_RETCODE_DONE)
   {
      Print("❌ OrderSend failed: ", res.retcode);
   }
   else
   {
      PrintFormat(
         "✅ ORDER SENT | lot=%.2f | entry=%.2f | SL=%.2f | TP=%.2f",
         plan.lot,
         plan.entry,
         plan.stopLoss,
         plan.takeProfit
      );
   }
}

void OnTick()
{
   if(!IsNewBarFormed(TriggerTimeframe, g_LastTriggerBarTime))
      return;

   if(!IsTradingSessionAllowed())
      return;

   // ===== HTF BIAS =====
   UpdateHTFBias(BiasTimeframe, g_HTFBias);

   // ===== TREND STRUCTURE =====
   UpdateMarketStructure(TrendTimeframe, g_TrendState);

   double currentBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   CheckForEarlyTrendFlip(g_TrendState, currentBidPrice);

   DrawMarketStructure(TrendTimeframe, g_TrendState);
   DrawTrendSummaryLabel(g_TrendState);

   // ===== ENTRY FILTER =====
   if(!IsHTFBiasAligned(g_HTFBias.bias,
                        g_TrendState.trendDirection))
      return;

   // ===== ORDER BLOCK FLOW =====
   if(!g_OBWatch.active) {
      TryActivateOBWatch(g_TrendState, currentBidPrice);
   } else {
      HandleOBWatching(g_TrendState, currentBidPrice);
   }
}

//+------------------------------------------------------------------+
