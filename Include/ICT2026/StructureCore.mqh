//+------------------------------------------------------------------+
//| StructureCore.mqh — body break & BOS/CHoCH detect (dùng chung)   |
//+------------------------------------------------------------------+
#ifndef ICT2026_STRUCTURECORE_MQH
#define ICT2026_STRUCTURECORE_MQH

#include <ICT2026/Config.mqh>

double IctBodyTop(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   return MathMax(iOpen(sym, tf, shift), iClose(sym, tf, shift));
}

double IctBodyBottom(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   return MathMin(iOpen(sym, tf, shift), iClose(sym, tf, shift));
}

bool IctBodyBreakAbove(const string sym, const ENUM_TIMEFRAMES tf,
                       const int shift, const double level)
{
   return IctBodyTop(sym, tf, shift) > level + _Point;
}

bool IctBodyBreakBelow(const string sym, const ENUM_TIMEFRAMES tf,
                       const int shift, const double level)
{
   return IctBodyBottom(sym, tf, shift) < level - _Point;
}

// BOS = Continue (Key LV2) | CHoCH = Reversal (Key LV1)
ENUM_ICT_MS_EVENT IctDetectStructureEvent(const string sym, const ENUM_TIMEFRAMES tf,
                                          const ENUM_ICT_STRUCT structural,
                                          const double keyLv1, const double keyLv2,
                                          const int shift = 1)
{
   if(structural == ICT_STRUCT_NONE || keyLv1 <= 0.0 || keyLv2 <= 0.0)
      return ICT_MS_NONE;

   if(structural == ICT_STRUCT_BULL)
   {
      if(IctBodyBreakBelow(sym, tf, shift, keyLv1))
         return ICT_MS_CHOCH;
      if(IctBodyBreakAbove(sym, tf, shift, keyLv2))
         return ICT_MS_BOS;
   }
   else if(structural == ICT_STRUCT_BEAR)
   {
      if(IctBodyBreakAbove(sym, tf, shift, keyLv1))
         return ICT_MS_CHOCH;
      if(IctBodyBreakBelow(sym, tf, shift, keyLv2))
         return ICT_MS_BOS;
   }

   return ICT_MS_NONE;
}

// BOS/CHoCH trên swing cũ H1/L1 theo trend hiện tại (body close shift=1)
// UP:   BOS = phá H1 | CHoCH = phá L1
// DOWN: BOS = phá L1 | CHoCH = phá H1
ENUM_ICT_MS_EVENT IctDetectTrendSwingEvent(const string sym, const ENUM_TIMEFRAMES tf,
                                           const ENUM_ICT_TREND trend,
                                           const double swingHighH1,
                                           const double swingLowL1,
                                           const int shift = 1)
{
   if(trend == ICT_TREND_NONE || swingHighH1 <= 0.0 || swingLowL1 <= 0.0)
      return ICT_MS_NONE;

   if(trend == ICT_TREND_UP)
   {
      if(IctBodyBreakBelow(sym, tf, shift, swingLowL1))
         return ICT_MS_CHOCH;
      if(IctBodyBreakAbove(sym, tf, shift, swingHighH1))
         return ICT_MS_BOS;
   }
   else if(trend == ICT_TREND_DOWN)
   {
      if(IctBodyBreakAbove(sym, tf, shift, swingHighH1))
         return ICT_MS_CHOCH;
      if(IctBodyBreakBelow(sym, tf, shift, swingLowL1))
         return ICT_MS_BOS;
   }

   return ICT_MS_NONE;
}

#endif
