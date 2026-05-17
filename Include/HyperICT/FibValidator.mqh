//+------------------------------------------------------------------+
//| FibValidator.mqh                                                 |
//| Điều kiện tiên quyết Fibonacci (§ đầu spec)                      |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • Bull HH-HL & Bear LH-LL: kiểm tra ở SwingEngine.Classify      |
//|  • Sóng hồi H1→L0 >= 0.382 × sóng L1→H1 (bull & bear cùng công thức) |
//|  • Fib fail → HTF_BULL/BEAR_INCOMPLETE (không Neutral)           |
//| KHÔNG DÙNG FIB TRONG:                                            |
//|  • §1.4 CHoCH / Continue — xác nhận đỉnh/đáy = InpSwingRange     |
//+------------------------------------------------------------------+
#ifndef HYPERICT_FIBVALIDATOR_MQH
#define HYPERICT_FIBVALIDATOR_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>

class CFibValidator
{
public:
   static double LegSize(const double from, const double to)
   {
      return MathAbs(to - from);
   }

   // § tiên quyết: pullback H1→L0 đủ sâu so với impulse L1→H1
   static bool IsPullbackValid(const SwingSet &sw, const double ratio)
   {
      if(!sw.IsComplete())
         return false;
      const double impulse = LegSize(sw.l1.price, sw.h1.price);
      const double pullback = LegSize(sw.h1.price, sw.l0.price);
      if(impulse <= 0.0)
         return false;
      return pullback >= impulse * ratio;
   }
};

#endif // HYPERICT_FIBVALIDATOR_MQH
