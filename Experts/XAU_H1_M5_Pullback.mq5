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

input ENUM_TIMEFRAMES TrendTimeframe      = PERIOD_H1;  // Timeframe xác định trend
input ENUM_TIMEFRAMES TriggerTimeframe    = PERIOD_M5;  // Timeframe kích hoạt logic

input int SwingDetectionRange             = 2;          // Số nến trái/phải xác định swing
input int StructureScanLookbackBars       = 150;        // Số nến quét structure

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

//====================================================
// INITIALIZATION
//====================================================

int OnInit()
{
   ZeroMemory(g_TrendState);
   g_TrendState.trendDirection = 0;
   g_TrendState.lastStructureUpdateTime = 0;

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

void OnTick()
{
   if(!IsNewBarFormed(TriggerTimeframe, g_LastTriggerBarTime))
      return;

   UpdateMarketStructure(TrendTimeframe, g_TrendState);

   double currentBidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   CheckForEarlyTrendFlip(g_TrendState, currentBidPrice);

   DrawMarketStructure(TrendTimeframe, g_TrendState);
   DrawTrendSummaryLabel(g_TrendState);

   // === Entry logic sẽ gắn tại đây ===
}
//+------------------------------------------------------------------+
