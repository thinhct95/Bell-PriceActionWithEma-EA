//+------------------------------------------------------------------+
//| FibValidator.mqh — Fib 0.382 chỉ cho tiên quyết trend ban đầu     |
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

   // Sóng hồi H1→L0 >= ratio × sóng L1→H1 (bull & bear, chỉ lúc lock trend)
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
