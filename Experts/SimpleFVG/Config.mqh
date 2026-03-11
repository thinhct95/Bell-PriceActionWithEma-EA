//+------------------------------------------------------------------+
//| Config.mqh – Step 0: Inputs, Enums, Constants                    |
//| Cho phép cấu hình symbol, timeframe, EMA, FVG, drawing           |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_CONFIG_MQH__
#define __SIMPLE_FVG_CONFIG_MQH__

//--- Step 0: Asset & Timeframe ---
input string          InpSymbol            = "";
input ENUM_TIMEFRAMES InpTimeframe         = PERIOD_H1;

//--- Step 1: Trend (EMA) ---
input int             InpEMAFastPeriod     = 34;
input int             InpEMASlowPeriod     = 89;

//--- Step 2: FVG Detection ---
input int             InpFVGLookbackBars   = 100;
input int             InpFVGMaxAgeBars     = 50;
input double          InpFVGMinBodyPct     = 50.0;
input double          InpFVGMinSizePoints      = 0;
input double          InpFVGTouchedPercent     = 33.0;
input double          InpFVGMinGapVsImpulsePct = 30.0;
input double          InpFVGMaxOuterBarRatio   = 2.0;

//--- Step 3: Trading ---
input bool            InpTradeEnabled        = true;
input double          InpRiskPercentPerR     = 1.0;
input double          InpRRRatio             = 2.2;
input int             InpMaxLimitOrders      = 3;
input int             InpLimitMaxAgeBars     = 24;
input long            InpEAMagic             = 123456;

//--- Step 4: Drawing ---
input color           InpColorBullFVG      = C'30,80,140';
input color           InpColorBearFVG      = C'140,30,20';
input color           InpColorMitigatedFVG = C'60,60,60';
input color           InpColorEMAFast      = clrDodgerBlue;
input color           InpColorEMASlow      = clrOrangeRed;
input bool            InpShowPanel         = true;
input bool            InpShowFVGLabels     = true;

//--- Debug ---
input bool            InpDebugLog          = true;

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

enum ENUM_FVG_STATUS
{
   ACTIVE    = 0,  // Giá chưa quay lại test
   TOUCHED   = 1,  // Giá đã retest >= threshold %
   MITIGATED = 2,  // Giá đâm xuyên qua vùng
   EXPIRED   = 3   // Hết hạn, không còn vẽ/đếm
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

//+------------------------------------------------------------------+
//| Low TF dùng để xác nhận khi giá chạm FVG: H1->M5, H4->M15, M15->M2 |
//| Trả về low TF hoặc chính highTF nếu không có mapping (không dùng confirm) |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetConfirmationTimeframe(ENUM_TIMEFRAMES highTF)
{
   if(highTF == PERIOD_H1)  return PERIOD_M5;
   if(highTF == PERIOD_H4)  return PERIOD_M15;
   if(highTF == PERIOD_M15) return PERIOD_M2;
   return highTF;
}

#endif
