//+------------------------------------------------------------------+
//| FVG.mqh – Step 2: Fair Value Gap detection & management            |
//|                                                                    |
//| 3-candle pattern:                                                  |
//|   CandleA (oldest) ── CandleB (impulse) ── CandleC (newest)       |
//|                                                                    |
//| Bullish FVG: CandleA.High < CandleC.Low  →  gap UP                |
//|   zone = [CandleA.High .. CandleC.Low]                            |
//|   CandleB must be bullish with strong body                         |
//|                                                                    |
//| Bearish FVG: CandleA.Low > CandleC.High →  gap DOWN               |
//|   zone = [CandleC.High .. CandleA.Low]                            |
//|   CandleB must be bearish with strong body                         |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_FVG_MQH__
#define __SIMPLE_FVG_FVG_MQH__

#include "Config.mqh"

//+------------------------------------------------------------------+
//| FVG data structure                                                 |
//+------------------------------------------------------------------+
struct FVGZone
{
   ENUM_FVG_TYPE   type;
   ENUM_FVG_STATUS status;
   double          upperEdge;
   double          lowerEdge;
   double          slReferencePrice;
   datetime        createdTime;
   int             ageInBars;
};

//+------------------------------------------------------------------+
//| Module state                                                       |
//+------------------------------------------------------------------+
FVGZone g_FVGZones[];
int     g_FVGCount = 0;

//+------------------------------------------------------------------+
//| Init: allocate array                                               |
//+------------------------------------------------------------------+
void FVGInit()
{
   ArrayResize(g_FVGZones, MAX_FVG_SLOTS);
   for(int i = 0; i < MAX_FVG_SLOTS; i++)
      ZeroMemory(g_FVGZones[i]);
   g_FVGCount = 0;
}

//+------------------------------------------------------------------+
//| Helper: status helpers & impulse strength                        |
//+------------------------------------------------------------------+
bool IsZoneActive(const FVGZone &z)
{
   return (z.status != EXPIRED);
}

bool IsZoneLive(const FVGZone &z)
{
   return (z.status == ACTIVE || z.status == TOUCHED);
}

bool IsZoneMitigated(const FVGZone &z)
{
   return (z.status == MITIGATED);
}

bool IsZoneTouched(const FVGZone &z)
{
   return (z.status == TOUCHED);
}

bool IsZoneExpired(const FVGZone &z)
{
   return (z.status == EXPIRED);
}

// Impulse candle strength: body/range >= threshold
bool IsImpulseCandleStrong(string symbol, ENUM_TIMEFRAMES tf, int shift)
{
   double high  = iHigh(symbol, tf, shift);
   double low   = iLow(symbol, tf, shift);
   double open  = iOpen(symbol, tf, shift);
   double close = iClose(symbol, tf, shift);

   double totalRange = high - low;
   if(totalRange < _Point)
      return false;

   double bodySize   = MathAbs(close - open);
   double bodyRatio  = bodySize / totalRange * 100.0;

   return (bodyRatio >= InpFVGMinBodyPct);
}

//+------------------------------------------------------------------+
//| Check if this FVG timestamp already exists in our array          |
//+------------------------------------------------------------------+
bool FVGAlreadyTracked(datetime fvgTime, ENUM_FVG_TYPE fvgType)
{
   for(int i = 0; i < g_FVGCount; i++)
   {
      if(IsZoneActive(g_FVGZones[i])
         && g_FVGZones[i].createdTime == fvgTime
         && g_FVGZones[i].type == fvgType)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Add a new FVG zone to the array                                  |
//+------------------------------------------------------------------+
bool AddFVGZone(ENUM_FVG_TYPE type,
                double        upper,
                double        lower,
                double        slReference,
                datetime      time)
{
   if(g_FVGCount >= MAX_FVG_SLOTS)
      return false;

   if(InpFVGMinSizePoints > 0)
   {
      double gapSizePoints = (upper - lower) / _Point;
      if(gapSizePoints < InpFVGMinSizePoints)
         return false;
   }

   ZeroMemory(g_FVGZones[g_FVGCount]);
   g_FVGZones[g_FVGCount].type            = type;
   g_FVGZones[g_FVGCount].status          = ACTIVE;
   g_FVGZones[g_FVGCount].upperEdge       = upper;
   g_FVGZones[g_FVGCount].lowerEdge       = lower;
   g_FVGZones[g_FVGCount].slReferencePrice = slReference;
   g_FVGZones[g_FVGCount].createdTime     = time;
   g_FVGZones[g_FVGCount].ageInBars       = 0;
   g_FVGCount++;

   if(InpDebugLog)
      PrintFormat("[FVG] NEW %s [%.5f – %.5f] at %s",
                  (type == FVG_BULLISH) ? "BULL" : "BEAR",
                  lower, upper, TimeToString(time));
   return true;
}

//+------------------------------------------------------------------+
//| Scan for new FVG patterns across the lookback range                |
//| Finds ALL FVGs regardless of current trend                         |
//+------------------------------------------------------------------+
void ScanForNewFVGs()
{
   string symbol   = GetTradeSymbol();
   int    totalBars = Bars(symbol, InpTimeframe);
   int    maxShift  = MathMin(InpFVGLookbackBars, totalBars - 3);

   for(int shift = 1; shift <= maxShift; shift++)
   {
      int shiftA = shift + 2;   // oldest candle
      int shiftB = shift + 1;   // impulse (middle) candle
      int shiftC = shift;       // newest candle

      double candleA_High = iHigh(symbol, InpTimeframe, shiftA);
      double candleA_Low  = iLow (symbol, InpTimeframe, shiftA);

      double candleB_High = iHigh(symbol, InpTimeframe, shiftB);
      double candleB_Low  = iLow (symbol, InpTimeframe, shiftB);
      double candleB_Open  = iOpen (symbol, InpTimeframe, shiftB);
      double candleB_Close = iClose(symbol, InpTimeframe, shiftB);

      double candleC_High = iHigh(symbol, InpTimeframe, shiftC);
      double candleC_Low  = iLow (symbol, InpTimeframe, shiftC);

      datetime fvgTime = iTime(symbol, InpTimeframe, shiftC);

      double rangeA = candleA_High - candleA_Low;
      double rangeB = candleB_High - candleB_Low;
      double rangeC = candleC_High - candleC_Low;
      double bodyB  = MathAbs(candleB_Close - candleB_Open);

      if(rangeB <= 0)
         continue;
      if(bodyB <= 0)
         continue;

      double maxOuterRatio = InpFVGMaxOuterBarRatio;
      if(rangeA > maxOuterRatio * rangeB || rangeC > maxOuterRatio * rangeB)
         continue;

      double minGapVsBody = InpFVGMinGapVsImpulsePct / 100.0;

      //--- Bullish FVG: gap between A.High and C.Low ---
      if(candleA_High < candleC_Low
         && candleB_Close > candleB_Open
         && IsImpulseCandleStrong(symbol, InpTimeframe, shiftB))
      {
         double gap      = candleC_Low - candleA_High;
         double gapRatio = gap / bodyB;

         if(gapRatio >= minGapVsBody && !FVGAlreadyTracked(fvgTime, FVG_BULLISH))
         {
            double slRef = candleA_Low;   // SL dưới bar A
            AddFVGZone(FVG_BULLISH, candleC_Low, candleA_High, slRef, fvgTime);
         }
      }

      //--- Bearish FVG: gap between C.High and A.Low ---
      if(candleA_Low > candleC_High
         && candleB_Close < candleB_Open
         && IsImpulseCandleStrong(symbol, InpTimeframe, shiftB))
      {
         double gap      = candleA_Low - candleC_High;
         double gapRatio = gap / bodyB;

         if(gapRatio >= minGapVsBody && !FVGAlreadyTracked(fvgTime, FVG_BEARISH))
         {
            double slRef = candleA_High;  // SL trên bar A
            AddFVGZone(FVG_BEARISH, candleA_Low, candleC_High, slRef, fvgTime);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Quét TF bất kỳ, tìm FVG cùng hướng gần nhất (shift 1..maxLookback) |
//| Trả về cạnh trên/dưới vùng và bar A low/high (để đặt SL).         |
//+------------------------------------------------------------------+
bool GetLatestLowTFFVG(string             symbol,
                       ENUM_TIMEFRAMES    tf,
                       ENUM_FVG_TYPE      type,
                       int                maxLookbackBars,
                       double            &outUpper,
                       double            &outLower,
                       double            &outBarALow,
                       double            &outBarAHigh)
{
   int totalBars = Bars(symbol, tf);
   int maxShift  = MathMin(maxLookbackBars, totalBars - 3);
   if(maxShift < 1)
      return false;

   double maxOuterRatio = InpFVGMaxOuterBarRatio;
   double minGapVsBody  = InpFVGMinGapVsImpulsePct / 100.0;

   for(int shift = 1; shift <= maxShift; shift++)
   {
      int shiftA = shift + 2;
      int shiftB = shift + 1;
      int shiftC = shift;

      double candleA_High = iHigh(symbol, tf, shiftA);
      double candleA_Low  = iLow (symbol, tf, shiftA);
      double candleB_High = iHigh(symbol, tf, shiftB);
      double candleB_Low  = iLow (symbol, tf, shiftB);
      double candleB_Open  = iOpen (symbol, tf, shiftB);
      double candleB_Close = iClose(symbol, tf, shiftB);
      double candleC_High = iHigh(symbol, tf, shiftC);
      double candleC_Low  = iLow (symbol, tf, shiftC);

      double rangeA = candleA_High - candleA_Low;
      double rangeB = candleB_High - candleB_Low;
      double rangeC = candleC_High - candleC_Low;
      double bodyB  = MathAbs(candleB_Close - candleB_Open);

      if(rangeB <= 0 || bodyB <= 0)
         continue;
      if(rangeA > maxOuterRatio * rangeB || rangeC > maxOuterRatio * rangeB)
         continue;
      if(!IsImpulseCandleStrong(symbol, tf, shiftB))
         continue;

      if(type == FVG_BULLISH)
      {
         if(candleA_High >= candleC_Low || candleB_Close <= candleB_Open)
            continue;
         double gap      = candleC_Low - candleA_High;
         double gapRatio = gap / bodyB;
         if(gapRatio < minGapVsBody)
            continue;
         outUpper    = candleC_Low;
         outLower    = candleA_High;
         outBarALow  = candleA_Low;
         outBarAHigh = candleA_High;
         return true;
      }
      else // FVG_BEARISH
      {
         if(candleA_Low <= candleC_High || candleB_Close >= candleB_Open)
            continue;
         double gap      = candleA_Low - candleC_High;
         double gapRatio = gap / bodyB;
         if(gapRatio < minGapVsBody)
            continue;
         outUpper    = candleA_Low;
         outLower    = candleC_High;
         outBarALow  = candleA_Low;
         outBarAHigh = candleA_High;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if price has mitigated (filled through) any active FVG       |
//+------------------------------------------------------------------+
void CheckMitigationStatus()
{
   string symbol = GetTradeSymbol();

   for(int i = 0; i < g_FVGCount; i++)
   {
      if(IsZoneMitigated(g_FVGZones[i]) || !IsZoneActive(g_FVGZones[i]))
         continue;

      double lastLow  = iLow (symbol, InpTimeframe, 1);
      double lastHigh = iHigh(symbol, InpTimeframe, 1);

      double zoneHeight = g_FVGZones[i].upperEdge - g_FVGZones[i].lowerEdge;
      if(zoneHeight <= 0)
         continue;

      //--- Bullish FVG: price comes down into the gap ---
      if(g_FVGZones[i].type == FVG_BULLISH)
      {
         // Mitigated: price drops through lower edge
         if(lastLow <= g_FVGZones[i].lowerEdge)
         {
            g_FVGZones[i].status = MITIGATED;
            if(InpDebugLog)
               PrintFormat("[FVG] MITIGATED BULL [%.5f – %.5f]",
                           g_FVGZones[i].lowerEdge, g_FVGZones[i].upperEdge);
            continue;
         }

         // Touched: price has filled at least X% of gap, but not fully
         double deepestPrice = MathMin(lastLow, g_FVGZones[i].upperEdge);
         deepestPrice        = MathMax(deepestPrice, g_FVGZones[i].lowerEdge);
         double fillPct      = (g_FVGZones[i].upperEdge - deepestPrice) / zoneHeight * 100.0;

         if(g_FVGZones[i].status == ACTIVE && fillPct >= InpFVGTouchedPercent)
            g_FVGZones[i].status = TOUCHED;
      }

      //--- Bearish FVG: price goes up into the gap ---
      if(g_FVGZones[i].type == FVG_BEARISH)
      {
         // Mitigated: price rises through upper edge
         if(lastHigh >= g_FVGZones[i].upperEdge)
         {
            g_FVGZones[i].status = MITIGATED;
            if(InpDebugLog)
               PrintFormat("[FVG] MITIGATED BEAR [%.5f – %.5f]",
                           g_FVGZones[i].lowerEdge, g_FVGZones[i].upperEdge);
            continue;
         }

         // Touched: price has filled at least X% of gap, but not fully
         double highestPrice = MathMax(lastHigh, g_FVGZones[i].lowerEdge);
         highestPrice        = MathMin(highestPrice, g_FVGZones[i].upperEdge);
         double fillPct      = (highestPrice - g_FVGZones[i].lowerEdge) / zoneHeight * 100.0;

         if(g_FVGZones[i].status == ACTIVE && fillPct >= InpFVGTouchedPercent)
            g_FVGZones[i].status = TOUCHED;
      }
   }
}

//+------------------------------------------------------------------+
//| Age out old FVGs beyond max age                                    |
//+------------------------------------------------------------------+
void ExpireOldFVGs()
{
   for(int i = 0; i < g_FVGCount; i++)
   {
      if(!IsZoneActive(g_FVGZones[i])) continue;

      g_FVGZones[i].ageInBars++;

      if(g_FVGZones[i].ageInBars > InpFVGMaxAgeBars)
      {
         g_FVGZones[i].status = EXPIRED;
         if(InpDebugLog)
            PrintFormat("[FVG] EXPIRED %s [%.5f – %.5f] age=%d bars",
                        (g_FVGZones[i].type == FVG_BULLISH) ? "BULL" : "BEAR",
                        g_FVGZones[i].lowerEdge, g_FVGZones[i].upperEdge,
                        g_FVGZones[i].ageInBars);
      }
   }
}

//+------------------------------------------------------------------+
//| Remove inactive FVGs from array to free slots                      |
//+------------------------------------------------------------------+
void CompactFVGArray()
{
   int writeIndex = 0;
   for(int i = 0; i < g_FVGCount; i++)
   {
      if(IsZoneActive(g_FVGZones[i]))
      {
         if(writeIndex != i)
            g_FVGZones[writeIndex] = g_FVGZones[i];
         writeIndex++;
      }
   }
   g_FVGCount = writeIndex;
}

//+------------------------------------------------------------------+
//| Main update: mitigation → expiry → scan new → compact             |
//+------------------------------------------------------------------+
void FVGUpdate()
{
   CheckMitigationStatus();
   ExpireOldFVGs();
   ScanForNewFVGs();
   CompactFVGArray();
}

//+------------------------------------------------------------------+
//| Count helpers for panel display                                    |
//+------------------------------------------------------------------+
int CountActiveFVGs(ENUM_FVG_TYPE type)
{
   int count = 0;
   for(int i = 0; i < g_FVGCount; i++)
   {
      if(IsZoneActive(g_FVGZones[i]) && g_FVGZones[i].type == type)
         count++;
   }
   return count;
}

int CountMitigatedFVGs()
{
   int count = 0;
   for(int i = 0; i < g_FVGCount; i++)
   {
      if(IsZoneMitigated(g_FVGZones[i]))
         count++;
   }
   return count;
}

#endif
