//+------------------------------------------------------------------+
//| KeyLevels.mqh                                                    |
//| Key LV1/L2, vùng cung-cầu OB, phá level bằng body (§1.2)        |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • Bull Key LV1=L0, Key LV2=H0 (đỉnh cao nhất L0→H0 = H0)       |
//|  • Bear Key LV1=H0, Key LV2=L0                                   |
//|  • Vùng cung: L0 → high nến đỏ OB | Vùng cầu: H0 → low nến xanh |
//|  • Phá Key = body close (shift 1), không dùng wick                 |
//|  • Giá Pullback giữa L0–H0 / H0–L0 — PriceBetween                |
//| CHƯA: OB mitigation filter đầy đủ ICT                            |
//+------------------------------------------------------------------+
#ifndef HYPERICT_KEYLEVELS_MQH
#define HYPERICT_KEYLEVELS_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>

class CKeyLevels
{
public:
   //--- Thân nến (§: phá Key LV bằng body, không wick)
   static double BodyTop(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
   {
      return MathMax(iOpen(sym, tf, shift), iClose(sym, tf, shift));
   }

   static double BodyBottom(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
   {
      return MathMin(iOpen(sym, tf, shift), iClose(sym, tf, shift));
   }

   static bool IsBearCandle(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
   {
      return iClose(sym, tf, shift) < iOpen(sym, tf, shift);
   }

   static bool IsBullCandle(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
   {
      return iClose(sym, tf, shift) > iOpen(sym, tf, shift);
   }

   //--- §1.2.3 vùng cung @ L0: nến đỏ cuối cùng gần đáy Key LV1
   static bool FindSupplyOB(const string sym, const ENUM_TIMEFRAMES tf,
                            const SwingPoint &swingLow,
                            OrderBlockZone &out)
   {
      out.Clear();
      if(swingLow.shift < 1)
         return false;

      const int from = swingLow.shift + 8;
      const int to   = MathMax(1, swingLow.shift - 1);
      for(int sh = from; sh >= to; sh--)
      {
         if(!IsBearCandle(sym, tf, sh))
            continue;
         const double l = iLow(sym, tf, sh);
         if(l > swingLow.price + 20 * _Point)
            continue;
         out.valid = true;
         out.swingPrice = swingLow.price;
         out.obHigh = iHigh(sym, tf, sh);
         out.obLow  = iLow(sym, tf, sh);
         out.obTime = iTime(sym, tf, sh);
         out.obShift = sh;
         return true;
      }
      return false;
   }

   //--- §1.2.4 vùng cầu @ H0: nến xanh cuối cùng gần đỉnh Key LV2 (bull)
   static bool FindDemandOB(const string sym, const ENUM_TIMEFRAMES tf,
                            const SwingPoint &swingHigh,
                            OrderBlockZone &out)
   {
      out.Clear();
      if(swingHigh.shift < 1)
         return false;

      const int from = swingHigh.shift + 8;
      const int to   = MathMax(1, swingHigh.shift - 1);
      for(int sh = from; sh >= to; sh--)
      {
         if(!IsBullCandle(sym, tf, sh))
            continue;
         const double h = iHigh(sym, tf, sh);
         if(h < swingHigh.price - 20 * _Point)
            continue;
         out.valid = true;
         out.swingPrice = swingHigh.price;
         out.obHigh = iHigh(sym, tf, sh);
         out.obLow  = iLow(sym, tf, sh);
         out.obTime = iTime(sym, tf, sh);
         out.obShift = sh;
         return true;
      }
      return false;
   }

   //--- Gán Key LV1/L2 + zone OB theo bias bull/bear
   static void BuildKeyLevels(const string sym, const ENUM_TIMEFRAMES tf,
                              const ENUM_STRUCT_BIAS bias,
                              const SwingSet &sw,
                              KeyLevelPair &lv1, KeyLevelPair &lv2)
   {
      lv1.zone.Clear();
      lv2.zone.Clear();
      if(!sw.IsComplete())
         return;

      if(bias == STRUCT_BULL)
      {
         lv1.price = sw.l0.price;
         lv2.price = sw.h0.price;
         FindSupplyOB(sym, tf, sw.l0, lv1.zone);
         FindDemandOB(sym, tf, sw.h0, lv2.zone);
      }
      else if(bias == STRUCT_BEAR)
      {
         lv1.price = sw.h0.price;
         lv2.price = sw.l0.price;
         FindDemandOB(sym, tf, sw.h0, lv1.zone);   // Key LV1 bear = H0 (demand side OB at H0)
         FindSupplyOB(sym, tf, sw.l0, lv2.zone);
      }
   }

   static bool BodyBreakBelow(const string sym, const ENUM_TIMEFRAMES tf,
                              const int shift, const double level)
   {
      return BodyBottom(sym, tf, shift) < level - _Point;
   }

   static bool BodyBreakAbove(const string sym, const ENUM_TIMEFRAMES tf,
                              const int shift, const double level)
   {
      return BodyTop(sym, tf, shift) > level + _Point;
   }

   static bool PriceBetween(const double price, const double a, const double b)
   {
      const double lo = MathMin(a, b);
      const double hi = MathMax(a, b);
      return price >= lo - _Point && price <= hi + _Point;
   }

   static void ZoneRectBounds(const OrderBlockZone &z,
                              const bool supplyAtLow,
                              double &top, double &bottom)
   {
      if(!z.valid)
      {
         top = bottom = z.swingPrice;
         return;
      }
      if(supplyAtLow)
      {
         top = MathMax(z.swingPrice, z.obHigh);
         bottom = MathMin(z.swingPrice, z.obLow);
      }
      else
      {
         top = MathMax(z.swingPrice, z.obHigh);
         bottom = MathMin(z.swingPrice, z.obLow);
      }
   }
};

#endif // HYPERICT_KEYLEVELS_MQH
