//+------------------------------------------------------------------+
//|                 MARKET REGIME CLASSIFIER EA                      |
//|                     REGIME ENGINE v1                             |
//+------------------------------------------------------------------+
#property copyright "MARKET REGIME CLASSIFIER"
#property version   "1.00"
#property description "CLASSIFICATION TO STRATEGY"

//====================================================
// ENUMS
//====================================================

enum MarketRegime
{
   REGIME_UNKNOWN = 0,
   REGIME_TREND_EXPANSION,
   REGIME_PULLBACK,
   REGIME_BALANCED_RANGE,
   REGIME_VOLATILE_RANGE,
   REGIME_COMPRESSION
};

//====================================================
// INPUTS
//====================================================

input int ATR_Period = 14;
input int EMA_Period = 50;
input int ADX_Period = 14;

input int LookbackBars = 20;

input double MinConfidence = 0.30;

//====================================================
// STRUCTS
//====================================================

struct MarketFeatures
{
   double atrRelative;
   double emaSlope;
   double overlapRatio;
   double wickRatio;
   double bbWidth;

   double displacementCount;

   double smallBodyRatio;
   double insideBarFrequency;

   double adxValue;

   bool htfTrendBullish;
   bool htfTrendBearish;
};

struct RegimeScores
{
   int trendExpansion;
   int pullback;
   int balancedRange;
   int volatileRange;
   int compression;
};

//====================================================
// GLOBALS
//====================================================

int atrHandle;
int emaHandle;
int adxHandle;
int bbHandle;

//====================================================
// INIT
//====================================================

int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   emaHandle = iMA(
      _Symbol,
      PERIOD_CURRENT,
      EMA_Period,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   adxHandle = iADX(
      _Symbol,
      PERIOD_CURRENT,
      ADX_Period
   );

   bbHandle = iBands(
      _Symbol,
      PERIOD_CURRENT,
      20,
      0,
      2.0,
      PRICE_CLOSE
   );

   return(INIT_SUCCEEDED);
}

//====================================================
// DEINIT
//====================================================

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   if(emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(emaHandle);
      emaHandle = INVALID_HANDLE;
   }
   if(adxHandle != INVALID_HANDLE)
   {
      IndicatorRelease(adxHandle);
      adxHandle = INVALID_HANDLE;
   }
   if(bbHandle != INVALID_HANDLE)
   {
      IndicatorRelease(bbHandle);
      bbHandle = INVALID_HANDLE;
   }
}

//====================================================
// MAIN
//====================================================

void OnTick()
{
   static datetime lastBarTime = 0;

   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar == lastBarTime)
      return;

   lastBarTime = currentBar;

   MarketFeatures features;

   ExtractMarketFeatures(features);

   RegimeScores scores;

   CalculateRegimeScores(features, scores);

   MarketRegime regime = GetHighestScoreRegime(scores);

   double confidence = CalculateConfidence(scores);

   if(confidence < MinConfidence)
      regime = REGIME_UNKNOWN;

   PrintRegime(regime, confidence, scores);

   //===========================================
   // ROUTER
   //===========================================

   switch(regime)
   {
      case REGIME_TREND_EXPANSION:

         Print("MODE = TREND EXPANSION");

         break;

      case REGIME_PULLBACK:

         Print("MODE = PULLBACK");

         break;

      case REGIME_BALANCED_RANGE:

         Print("MODE = BALANCED RANGE");

         break;

      case REGIME_VOLATILE_RANGE:

         Print("MODE = VOLATILE RANGE");

         break;

      case REGIME_COMPRESSION:

         Print("MODE = COMPRESSION");

         break;
   }
}

//====================================================
// FEATURE EXTRACTION
//====================================================

void ExtractMarketFeatures(MarketFeatures &f)
{
   f.atrRelative = CalculateATRRelative();

   f.emaSlope = CalculateEMASlope();

   f.overlapRatio = CalculateOverlapRatio();

   f.wickRatio = CalculateWickRatio();

   f.bbWidth = CalculateBBWidth();

   f.displacementCount = CountDisplacementCandles();

   f.smallBodyRatio = CalculateSmallBodyRatio();

   f.insideBarFrequency = CalculateInsideBarFrequency();

   f.adxValue = CalculateADX();

   f.htfTrendBullish = (f.emaSlope > 1.0);

   f.htfTrendBearish = false;
}

//====================================================
// ATR RELATIVE
//====================================================

double CalculateATRRelative()
{
   double atr[];

   ArraySetAsSeries(atr, true);

   CopyBuffer(atrHandle, 0, 0, 60, atr);

   double currentATR = atr[0];

   double sum = 0;

   for(int i=0; i<50; i++)
      sum += atr[i];

   double avgATR = sum / 50.0;

   if(avgATR == 0)
      return 0;

   return currentATR / avgATR;
}

//====================================================
// EMA SLOPE
//====================================================

double CalculateEMASlope()
{
   double ema[];
   double atr[];

   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);

   CopyBuffer(emaHandle, 0, 0, 20, ema);

   CopyBuffer(atrHandle, 0, 0, 20, atr);

   if(atr[0] == 0)
      return 0;

   return MathAbs(ema[0] - ema[10]) / atr[0];
}

//====================================================
// OVERLAP RATIO
//====================================================

double CalculateOverlapRatio()
{
   double totalOverlap = 0;

   double totalRange = 0;

   for(int i=1; i<=LookbackBars; i++)
   {
      double high1 = iHigh(_Symbol, PERIOD_CURRENT, i);

      double low1 = iLow(_Symbol, PERIOD_CURRENT, i);

      double high2 = iHigh(_Symbol, PERIOD_CURRENT, i+1);

      double low2 = iLow(_Symbol, PERIOD_CURRENT, i+1);

      double overlapHigh = MathMin(high1, high2);

      double overlapLow = MathMax(low1, low2);

      double overlap = overlapHigh - overlapLow;

      if(overlap < 0)
         overlap = 0;

      totalOverlap += overlap;

      totalRange += (high1 - low1);
   }

   if(totalRange == 0)
      return 0;

   return totalOverlap / totalRange;
}

//====================================================
// WICK RATIO
//====================================================

double CalculateWickRatio()
{
   double totalWick = 0;

   double totalRange = 0;

   for(int i=1; i<=LookbackBars; i++)
   {
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);

      double low = iLow(_Symbol, PERIOD_CURRENT, i);

      double open = iOpen(_Symbol, PERIOD_CURRENT, i);

      double close = iClose(_Symbol, PERIOD_CURRENT, i);

      double upperWick = high - MathMax(open, close);

      double lowerWick = MathMin(open, close) - low;

      double wick = upperWick + lowerWick;

      double range = high - low;

      totalWick += wick;

      totalRange += range;
   }

   if(totalRange == 0)
      return 0;

   return totalWick / totalRange;
}

//====================================================
// DISPLACEMENT COUNT
//====================================================

int CountDisplacementCandles()
{
   double atr[];

   ArraySetAsSeries(atr, true);

   CopyBuffer(atrHandle, 0, 0, 100, atr);

   int count = 0;

   for(int i=1; i<=LookbackBars; i++)
   {
      double open = iOpen(_Symbol, PERIOD_CURRENT, i);

      double close = iClose(_Symbol, PERIOD_CURRENT, i);

      double high = iHigh(_Symbol, PERIOD_CURRENT, i);

      double low = iLow(_Symbol, PERIOD_CURRENT, i);

      double body = MathAbs(close - open);

      double range = high - low;

      if(range == 0)
         continue;

      double bodyRatio = body / range;

      if(
         body > atr[i] * 1.5
         &&
         bodyRatio > 0.7
      )
      {
         count++;
      }
   }

   return count;
}

//====================================================
// SMALL BODY RATIO
//====================================================

double CalculateSmallBodyRatio()
{
   int count = 0;

   for(int i=1; i<=LookbackBars; i++)
   {
      double body =
         MathAbs(
            iClose(_Symbol, PERIOD_CURRENT, i)
            -
            iOpen(_Symbol, PERIOD_CURRENT, i)
         );

      double range =
         iHigh(_Symbol, PERIOD_CURRENT, i)
         -
         iLow(_Symbol, PERIOD_CURRENT, i);

      if(range == 0)
         continue;

      double ratio = body / range;

      if(ratio < 0.3)
         count++;
   }

   return (double)count / LookbackBars;
}

//====================================================
// INSIDE BAR FREQUENCY
//====================================================

double CalculateInsideBarFrequency()
{
   int count = 0;

   for(int i=1; i<=LookbackBars; i++)
   {
      double high1 = iHigh(_Symbol, PERIOD_CURRENT, i);

      double low1 = iLow(_Symbol, PERIOD_CURRENT, i);

      double high2 = iHigh(_Symbol, PERIOD_CURRENT, i+1);

      double low2 = iLow(_Symbol, PERIOD_CURRENT, i+1);

      bool insideBar =
         high1 < high2
         &&
         low1 > low2;

      if(insideBar)
         count++;
   }

   return count;
}

//====================================================
// ADX
//====================================================

double CalculateADX()
{
   double adx[];

   ArraySetAsSeries(adx, true);

   CopyBuffer(adxHandle, 0, 0, 10, adx);

   return adx[0];
}

//====================================================
// BOLLINGER WIDTH
//====================================================

double CalculateBBWidth()
{
   double upper[];
   double lower[];
   double atr[];

   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   ArraySetAsSeries(atr, true);

   CopyBuffer(bbHandle, 1, 0, 10, upper);

   CopyBuffer(bbHandle, 2, 0, 10, lower);

   CopyBuffer(atrHandle, 0, 0, 10, atr);

   double width = upper[0] - lower[0];

   if(atr[0] == 0)
      return 0;

   return width / atr[0];
}

//====================================================
// SCORE ENGINE
//====================================================

void CalculateRegimeScores(
   MarketFeatures &f,
   RegimeScores &s
)
{
   s.trendExpansion = 0;
   s.pullback = 0;
   s.balancedRange = 0;
   s.volatileRange = 0;
   s.compression = 0;

   //-----------------------------------------
   // TREND EXPANSION
   //-----------------------------------------

   if(f.atrRelative > 1.3)
      s.trendExpansion += 2;

   if(f.emaSlope > 1.0)
      s.trendExpansion += 2;

   if(f.overlapRatio < 0.4)
      s.trendExpansion += 2;

   if(f.displacementCount > 5)
      s.trendExpansion += 3;

   if(f.wickRatio < 0.4)
      s.trendExpansion += 1;

   //-----------------------------------------
   // PULLBACK
   //-----------------------------------------

   if(f.htfTrendBullish || f.htfTrendBearish)
      s.pullback += 3;

   if(
      f.atrRelative >= 0.8
      &&
      f.atrRelative <= 1.2
   )
   {
      s.pullback += 2;
   }

   if(
      f.overlapRatio >= 0.4
      &&
      f.overlapRatio <= 0.7
   )
   {
      s.pullback += 2;
   }

   //-----------------------------------------
   // BALANCED RANGE
   //-----------------------------------------

   if(f.atrRelative < 0.9)
      s.balancedRange += 2;

   if(f.adxValue < 20)
      s.balancedRange += 2;

   if(f.overlapRatio > 0.7)
      s.balancedRange += 3;

   if(f.wickRatio > 0.6)
      s.balancedRange += 1;

   //-----------------------------------------
   // VOLATILE RANGE
   //-----------------------------------------

   if(f.atrRelative > 1.3)
      s.volatileRange += 2;

   if(f.wickRatio > 0.6)
      s.volatileRange += 2;

   if(f.overlapRatio > 0.5)
      s.volatileRange += 2;

   //-----------------------------------------
   // COMPRESSION
   //-----------------------------------------

   if(f.atrRelative < 0.7)
      s.compression += 3;

   if(f.bbWidth < 1.0)
      s.compression += 3;

   if(f.insideBarFrequency > 5)
      s.compression += 2;

   if(f.smallBodyRatio > 0.6)
      s.compression += 2;
}

//====================================================
// CLASSIFIER
//====================================================

MarketRegime GetHighestScoreRegime(
   RegimeScores &s
)
{
   int maxScore = -1;

   MarketRegime regime = REGIME_UNKNOWN;

   if(s.trendExpansion > maxScore)
   {
      maxScore = s.trendExpansion;
      regime = REGIME_TREND_EXPANSION;
   }

   if(s.pullback > maxScore)
   {
      maxScore = s.pullback;
      regime = REGIME_PULLBACK;
   }

   if(s.balancedRange > maxScore)
   {
      maxScore = s.balancedRange;
      regime = REGIME_BALANCED_RANGE;
   }

   if(s.volatileRange > maxScore)
   {
      maxScore = s.volatileRange;
      regime = REGIME_VOLATILE_RANGE;
   }

   if(s.compression > maxScore)
   {
      maxScore = s.compression;
      regime = REGIME_COMPRESSION;
   }

   return regime;
}

//====================================================
// CONFIDENCE
//====================================================

double CalculateConfidence(
   RegimeScores &s
)
{
   int arr[5];

   arr[0] = s.trendExpansion;
   arr[1] = s.pullback;
   arr[2] = s.balancedRange;
   arr[3] = s.volatileRange;
   arr[4] = s.compression;

   int highest = 0;
   int second = 0;

   for(int i=0; i<5; i++)
   {
      if(arr[i] > highest)
      {
         second = highest;
         highest = arr[i];
      }
      else if(arr[i] > second)
      {
         second = arr[i];
      }
   }

   if(highest == 0)
      return 0;

   return (double)(highest - second) / highest;
}

//====================================================
// PRINT
//====================================================

void PrintRegime(
   MarketRegime regime,
   double confidence,
   RegimeScores &scores
)
{
   string name = "UNKNOWN";

   switch(regime)
   {
      case REGIME_TREND_EXPANSION:
         name = "TREND_EXPANSION";
         break;

      case REGIME_PULLBACK:
         name = "PULLBACK";
         break;

      case REGIME_BALANCED_RANGE:
         name = "BALANCED_RANGE";
         break;

      case REGIME_VOLATILE_RANGE:
         name = "VOLATILE_RANGE";
         break;

      case REGIME_COMPRESSION:
         name = "COMPRESSION";
         break;
   }

   Print(
      "REGIME = ",
      name,
      " | CONFIDENCE = ",
      DoubleToString(confidence, 2),
      " | EXP=",
      scores.trendExpansion,
      " | PB=",
      scores.pullback,
      " | BR=",
      scores.balancedRange,
      " | VR=",
      scores.volatileRange,
      " | COMP=",
      scores.compression
   );
}