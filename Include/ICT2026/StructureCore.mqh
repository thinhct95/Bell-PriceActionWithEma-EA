//+------------------------------------------------------------------+
//| StructureCore.mqh — body break primitives + BOS/CHoCH detector   |
//+------------------------------------------------------------------+
//| Helpers cho cả Daily + Intraday — phá level dùng THÂN NẾN (body), |
//| không dùng wick.                                                  |
//|                                                                   |
//|   IctBodyTop / IctBodyBot      — body top/bot của nến shift       |
//|   IctBodyBreakBuffer(sym)      — N × spread (≥ _Point)            |
//|   IctBodyBreakAbove(level)     — body close > level + buffer      |
//|   IctBodyBreakBelow(level)     — body close < level − buffer      |
//|                                                                   |
//| Buffer (v1.186): siết chặt — thân nến phải đóng vượt level ≥      |
//|   InpBodyBreakSpreadMult × (Ask−Bid) (mặc định 10 spread).        |
//|   Áp dụng cho mọi callsite: BOS/CHoCH (Daily, Intraday), MSS      |
//|   confirm, H1 FVG body-invalidate.                                |
//|                                                                   |
//| BOS vs CHoCH (cùng rule, khác bản chất):                          |
//|   BOS  = phá Key tiếp diễn xu hướng                              |
//|   CHoCH= phá Key NGƯỢC xu hướng (đảo chiều)                      |
//|                                                                   |
//|   Bear (LH-LL): Key1=H0, Key2=L0                                  |
//|     - Phá H0 ⇒ CHoCH (chuyển sang Bull sớm)                       |
//|     - Phá L0 ⇒ BOS                                                |
//|   Bull (HH-HL): Key1=L0, Key2=H0                                  |
//|     - Phá L0 ⇒ CHoCH (chuyển sang Bear sớm)                       |
//|     - Phá H0 ⇒ BOS                                                |
//|                                                                   |
//| Detection: trên bar đã đóng (shift=1) — KHÔNG dùng bar đang chạy. |
//|                                                                   |
//| Public API:                                                       |
//|   double IctBodyTop/Bot(sym, tf, shift)                          |
//|   bool   IctBodyBreakAbove/Below(sym, tf, shift, level)          |
//|   ENUM_ICT_MS_EVENT IctDetectStructureEvent(sym, tf, &set,       |
//|                                              structural, shift)  |
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

// Buffer xác nhận phá level: N × spread hiện tại (fallback _Point khi spread = 0).
//   Siết chặt body-break để loại các close-through "sát mép" do biến động nhỏ/spike.
//   N = InpBodyBreakSpreadMult (mặc định 10).
double IctBodyBreakBuffer(const string sym)
{
   const double sp = MathMax(0.0,
                       SymbolInfoDouble(sym, SYMBOL_ASK) -
                       SymbolInfoDouble(sym, SYMBOL_BID));
   const double unit = (sp > 0.0) ? sp : _Point;
   const double mult = MathMax(0.0, (double)InpBodyBreakSpreadMult);
   return MathMax(_Point, unit * mult);
}

bool IctBodyBreakAbove(const string sym, const ENUM_TIMEFRAMES tf,
                       const int shift, const double level)
{
   return IctBodyTop(sym, tf, shift) > level + IctBodyBreakBuffer(sym);
}

bool IctBodyBreakBelow(const string sym, const ENUM_TIMEFRAMES tf,
                       const int shift, const double level)
{
   return IctBodyBottom(sym, tf, shift) < level - IctBodyBreakBuffer(sym);
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
