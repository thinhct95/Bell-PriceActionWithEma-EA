//+------------------------------------------------------------------+
//| Trend.mqh – Step 1: Trend detection via EMA34 & EMA89            |
//|                                                                    |
//| Logic:                                                             |
//|   BULLISH:  EMA_fast > EMA_slow  AND  close > EMA_fast            |
//|   BEARISH:  EMA_fast < EMA_slow  AND  close < EMA_fast            |
//|   NEUTRAL:  otherwise (EMA crossing or price between EMAs)         |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_TREND_MQH__
#define __SIMPLE_FVG_TREND_MQH__

#include "Config.mqh"

//+------------------------------------------------------------------+
//| Module state                                                       |
//+------------------------------------------------------------------+
int    g_HandleEMAFast  = INVALID_HANDLE;
int    g_HandleEMASlow  = INVALID_HANDLE;
string g_NameEMAFast    = "";
string g_NameEMASlow    = "";

double g_EMAFastValue   = 0.0;
double g_EMASlowValue   = 0.0;
ENUM_TREND_DIRECTION g_CurrentTrend = TREND_NEUTRAL;

//+------------------------------------------------------------------+
//| Init: create EMA indicator handles and add to chart                |
//+------------------------------------------------------------------+
bool TrendInit()
{
   string symbol = GetTradeSymbol();

   g_HandleEMAFast = iMA(symbol, InpTimeframe, InpEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_HandleEMAFast == INVALID_HANDLE)
   {
      PrintFormat("[Trend] FAILED to create EMA%d handle", InpEMAFastPeriod);
      return false;
   }

   g_HandleEMASlow = iMA(symbol, InpTimeframe, InpEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_HandleEMASlow == INVALID_HANDLE)
   {
      PrintFormat("[Trend] FAILED to create EMA%d handle", InpEMASlowPeriod);
      return false;
   }

   ChartIndicatorAdd(0, 0, g_HandleEMAFast);
   int countAfterFast = ChartIndicatorsTotal(0, 0);
   if(countAfterFast > 0)
      g_NameEMAFast = ChartIndicatorName(0, 0, countAfterFast - 1);

   ChartIndicatorAdd(0, 0, g_HandleEMASlow);
   int countAfterSlow = ChartIndicatorsTotal(0, 0);
   if(countAfterSlow > 0)
      g_NameEMASlow = ChartIndicatorName(0, 0, countAfterSlow - 1);

   if(InpDebugLog)
      PrintFormat("[Trend] OK – EMA%d + EMA%d on %s %s",
                  InpEMAFastPeriod, InpEMASlowPeriod,
                  symbol, EnumToString(InpTimeframe));

   return true;
}

//+------------------------------------------------------------------+
//| Deinit: release handles and remove from chart                      |
//+------------------------------------------------------------------+
void TrendDeinit()
{
   if(g_NameEMAFast != "")
      ChartIndicatorDelete(0, 0, g_NameEMAFast);
   if(g_NameEMASlow != "")
      ChartIndicatorDelete(0, 0, g_NameEMASlow);

   if(g_HandleEMAFast != INVALID_HANDLE)
   {
      IndicatorRelease(g_HandleEMAFast);
      g_HandleEMAFast = INVALID_HANDLE;
   }
   if(g_HandleEMASlow != INVALID_HANDLE)
   {
      IndicatorRelease(g_HandleEMASlow);
      g_HandleEMASlow = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Read one EMA value at a given bar shift                            |
//+------------------------------------------------------------------+
double ReadEMA(int handle, int shift)
{
   double buffer[1];
   if(handle == INVALID_HANDLE) return 0.0;
   if(CopyBuffer(handle, 0, shift, 1, buffer) < 1) return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Update trend direction (call once per new bar)                     |
//+------------------------------------------------------------------+
ENUM_TREND_DIRECTION TrendUpdate()
{
   g_EMAFastValue = ReadEMA(g_HandleEMAFast, 1);
   g_EMASlowValue = ReadEMA(g_HandleEMASlow, 1);

   if(g_EMAFastValue == 0.0 || g_EMASlowValue == 0.0)
   {
      g_CurrentTrend = TREND_NEUTRAL;
      return g_CurrentTrend;
   }

   double closePrice = iClose(GetTradeSymbol(), InpTimeframe, 1);

   if(g_EMAFastValue > g_EMASlowValue && closePrice > g_EMAFastValue)
      g_CurrentTrend = TREND_BULLISH;
   else if(g_EMAFastValue < g_EMASlowValue && closePrice < g_EMAFastValue)
      g_CurrentTrend = TREND_BEARISH;
   else
      g_CurrentTrend = TREND_NEUTRAL;

   return g_CurrentTrend;
}

//+------------------------------------------------------------------+
//| Utility: convert trend enum to readable string                     |
//+------------------------------------------------------------------+
string TrendToString(ENUM_TREND_DIRECTION trend)
{
   switch(trend)
   {
      case TREND_BULLISH:  return "BULLISH";
      case TREND_BEARISH:  return "BEARISH";
      default:             return "NEUTRAL";
   }
}

color TrendToColor(ENUM_TREND_DIRECTION trend)
{
   switch(trend)
   {
      case TREND_BULLISH:  return clrLime;
      case TREND_BEARISH:  return clrTomato;
      default:             return clrGray;
   }
}

#endif
