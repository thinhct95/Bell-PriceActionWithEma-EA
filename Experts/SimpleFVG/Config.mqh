//+------------------------------------------------------------------+
//| Config.mqh – Step 0: Inputs, Enums, Constants                    |
//| Cho phép cấu hình symbol, timeframe, EMA, FVG, drawing           |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_CONFIG_MQH__
#define __SIMPLE_FVG_CONFIG_MQH__

//--- Step 0: Asset & Timeframe ---
input string          InpSymbol            = "";            // Symbol (empty = current chart)
input ENUM_TIMEFRAMES InpTimeframe         = PERIOD_H1;     // Analysis Timeframe

//--- Step 1: Trend (EMA) ---
input int             InpEMAFastPeriod     = 34;            // EMA Fast Period
input int             InpEMASlowPeriod     = 89;            // EMA Slow Period

//--- Step 2: FVG Detection ---
input int             InpFVGLookbackBars   = 100;           // FVG: Lookback range (bars)
input int             InpFVGMaxAgeBars     = 50;            // FVG: Max age before expiry (bars)
input double          InpFVGMinBodyPct     = 50.0;          // FVG: Min body % of impulse candle
input double          InpFVGMinSizePoints  = 0;             // FVG: Min gap size (points, 0=any)

//--- Step 4: Drawing ---
input color           InpColorBullFVG      = C'30,80,140';  // Color: Bullish FVG zone
input color           InpColorBearFVG      = C'140,30,20';  // Color: Bearish FVG zone
input color           InpColorMitigatedFVG = C'60,60,60';   // Color: Mitigated FVG zone
input color           InpColorEMAFast      = clrDodgerBlue;  // Color: EMA Fast line
input color           InpColorEMASlow      = clrOrangeRed;   // Color: EMA Slow line
input bool            InpShowPanel         = true;           // Draw: Show info panel
input bool            InpShowFVGLabels     = true;           // Draw: Show FVG labels

//--- Debug ---
input bool            InpDebugLog          = true;           // Debug: Enable logging

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_TREND_DIRECTION
{
   TREND_BULLISH  =  1,
   TREND_BEARISH  = -1,
   TREND_NEUTRAL  =  0
};

enum ENUM_FVG_TYPE
{
   FVG_BULLISH =  1,
   FVG_BEARISH = -1
};

//+------------------------------------------------------------------+
//| Constants                                                         |
//+------------------------------------------------------------------+
const string  EA_PREFIX       = "SFVG_";
const int     MAX_FVG_SLOTS   = 50;

//+------------------------------------------------------------------+
//| Resolved symbol (cached)                                          |
//+------------------------------------------------------------------+
string g_ResolvedSymbol = "";

string GetTradeSymbol()
{
   if(g_ResolvedSymbol != "")
      return g_ResolvedSymbol;

   g_ResolvedSymbol = (InpSymbol == "" || InpSymbol == "current")
                      ? _Symbol
                      : InpSymbol;
   return g_ResolvedSymbol;
}

//+------------------------------------------------------------------+
//| New-bar detector                                                  |
//+------------------------------------------------------------------+
datetime g_PreviousBarTime = 0;

bool IsNewBar()
{
   datetime currentBarTime = iTime(GetTradeSymbol(), InpTimeframe, 0);
   if(currentBarTime == g_PreviousBarTime)
      return false;
   g_PreviousBarTime = currentBarTime;
   return true;
}

#endif
