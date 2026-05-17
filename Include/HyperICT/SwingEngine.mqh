//+------------------------------------------------------------------+
//| SwingEngine.mqh — pivot, H0–L1, snapshot khóa                    |
//+------------------------------------------------------------------+
#ifndef HYPERICT_SWINGENGINE_MQH
#define HYPERICT_SWINGENGINE_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>

//+------------------------------------------------------------------+
class CSwingEngine
{
public:
   static bool IsSwingHigh(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const int range)
   {
      const int str = MathMax(1, range);
      const double h = iHigh(sym, tf, shift);
      for(int k = 1; k <= str; k++)
      {
         if(shift + k >= Bars(sym, tf) || shift - k < 0)
            return false;
         if(h <= iHigh(sym, tf, shift + k) || h <= iHigh(sym, tf, shift - k))
            return false;
      }
      return true;
   }

   static bool IsSwingLow(const string sym, const ENUM_TIMEFRAMES tf,
                          const int shift, const int range)
   {
      const int str = MathMax(1, range);
      const double l = iLow(sym, tf, shift);
      for(int k = 1; k <= str; k++)
      {
         if(shift + k >= Bars(sym, tf) || shift - k < 0)
            return false;
         if(l >= iLow(sym, tf, shift + k) || l >= iLow(sym, tf, shift - k))
            return false;
      }
      return true;
   }

   static int MinConfirmShift(const int range)
   {
      return MathMax(1, range) + 1;
   }

   static bool CanConfirmPivot(const int pivotShift, const int range)
   {
      return pivotShift >= MinConfirmShift(range);
   }

   static void FillSwingHigh(const string sym, const ENUM_TIMEFRAMES tf,
                             const int shift, SwingPoint &out)
   {
      out.price = iHigh(sym, tf, shift);
      out.time  = iTime(sym, tf, shift);
      out.shift = shift;
   }

   static void FillSwingLow(const string sym, const ENUM_TIMEFRAMES tf,
                            const int shift, SwingPoint &out)
   {
      out.price = iLow(sym, tf, shift);
      out.time  = iTime(sym, tf, shift);
      out.shift = shift;
   }

   static bool IsConfirmedSwingHigh(const string sym, const ENUM_TIMEFRAMES tf,
                                    const SwingPoint &pt, const int range)
   {
      if(!pt.Valid() || !CanConfirmPivot(pt.shift, range))
         return false;
      return IsSwingHigh(sym, tf, pt.shift, range);
   }

   static bool IsConfirmedSwingLow(const string sym, const ENUM_TIMEFRAMES tf,
                                   const SwingPoint &pt, const int range)
   {
      if(!pt.Valid() || !CanConfirmPivot(pt.shift, range))
         return false;
      return IsSwingLow(sym, tf, pt.shift, range);
   }

   static void SortByTime(SwingPoint &pts[], const int count)
   {
      for(int i = 0; i < count - 1; i++)
         for(int j = i + 1; j < count; j++)
            if(pts[j].time < pts[i].time)
            {
               const SwingPoint t = pts[i];
               pts[i] = pts[j];
               pts[j] = t;
            }
   }

   static void CollectSwings(const string sym, const ENUM_TIMEFRAMES tf,
                             const int range, const int lookback,
                             SwingPoint &highs[], SwingPoint &lows[])
   {
      ArrayResize(highs, 0);
      ArrayResize(lows, 0);
      const int str = MathMax(1, range);
      const int bars = Bars(sym, tf);
      const int last = MathMin(lookback, bars - str - 1);
      if(last < str + 5)
         return;

      int nH = 0, nL = 0;
      for(int sh = last; sh >= 1; sh--)
      {
         if(IsSwingHigh(sym, tf, sh, range))
         {
            ArrayResize(highs, nH + 1);
            highs[nH].price = iHigh(sym, tf, sh);
            highs[nH].time  = iTime(sym, tf, sh);
            highs[nH].shift = sh;
            nH++;
         }
         if(IsSwingLow(sym, tf, sh, range))
         {
            ArrayResize(lows, nL + 1);
            lows[nL].price = iLow(sym, tf, sh);
            lows[nL].time  = iTime(sym, tf, sh);
            lows[nL].shift = sh;
            nL++;
         }
      }
      SortByTime(highs, nH);
      SortByTime(lows, nL);
   }

   static void PickLastTwo(const SwingPoint &pts[], const int count,
                           SwingPoint &s0, SwingPoint &s1,
                           bool &has0, bool &has1)
   {
      has0 = has1 = false;
      if(count < 1) return;
      s0 = pts[count - 1];
      has0 = true;
      if(count < 2) return;
      s1 = pts[count - 2];
      has1 = true;
   }

   static ENUM_STRUCT_BIAS ClassifyStructure(const SwingSet &sw)
   {
      if(!sw.IsComplete())
         return STRUCT_NONE;
      if(sw.h0.price > sw.h1.price && sw.l0.price > sw.l1.price)
         return STRUCT_BULL;
      if(sw.h0.price < sw.h1.price && sw.l0.price < sw.l1.price)
         return STRUCT_BEAR;
      return STRUCT_NONE;
   }

   static bool BuildSwingSet(const string sym, const ENUM_TIMEFRAMES tf,
                             const int range, const int lookback,
                             SwingSet &out)
   {
      out.Clear();
      SwingPoint highs[], lows[];
      CollectSwings(sym, tf, range, lookback, highs, lows);
      PickLastTwo(highs, ArraySize(highs), out.h0, out.h1, out.hasH0, out.hasH1);
      PickLastTwo(lows, ArraySize(lows), out.l0, out.l1, out.hasL0, out.hasL1);
      return out.IsComplete();
   }

   static bool LockInitialSnapshot(HtfContext &ctx)
   {
      ctx.swings.Clear();
      if(!BuildSwingSet(ctx.symbol, ctx.htf, InpSwingRange, InpSwingLookback, ctx.swings))
         return false;
      ctx.structBias = ClassifyStructure(ctx.swings);
      ctx.lockedAt = TimeCurrent();
      ctx.snapshotReady = true;
      return true;
   }

   static void RollBullContinue(SwingSet &sw, const SwingPoint &newH0, const SwingPoint &newL0)
   {
      sw.h1 = sw.h0;
      sw.hasH1 = sw.hasH0;
      sw.l1 = sw.l0;
      sw.hasL1 = sw.hasL0;
      sw.h0 = newH0;
      sw.hasH0 = true;
      sw.l0 = newL0;
      sw.hasL0 = true;
   }

   static void RollBullChochCase1(SwingSet &sw, const SwingPoint &newH0, const SwingPoint &newL0)
   {
      sw.h1 = sw.h0;
      sw.hasH1 = sw.hasH0;
      // L1 giữ nguyên (spec)
      sw.l0 = newL0;
      sw.hasL0 = true;
      sw.h0 = newH0;
      sw.hasH0 = true;
   }

   static void RollBullChochCase2(SwingSet &sw,
                                  const SwingPoint &newH0,
                                  const SwingPoint &newL0,
                                  const SwingPoint &newL02)
   {
      sw.h1 = sw.h0;
      sw.hasH1 = sw.hasH0;
      sw.h0 = newH0;
      sw.hasH0 = true;
      sw.l1 = newL0;
      sw.hasL1 = true;
      sw.l0 = newL02;
      sw.hasL0 = true;
   }

   static void RollBearContinue(SwingSet &sw, const SwingPoint &newH0, const SwingPoint &newL0)
   {
      sw.l1 = sw.l0;
      sw.hasL1 = sw.hasL0;
      sw.h1 = sw.h0;
      sw.hasH1 = sw.hasH0;
      sw.l0 = newL0;
      sw.hasL0 = true;
      sw.h0 = newH0;
      sw.hasH0 = true;
   }

   static void RollBearChochCase1(SwingSet &sw, const SwingPoint &newH0, const SwingPoint &newL0)
   {
      sw.l1 = sw.l0;
      sw.hasL1 = sw.hasL0;
      sw.h0 = newH0;
      sw.hasH0 = true;
      sw.l0 = newL0;
      sw.hasL0 = true;
   }

   static void RollBearChochCase2(SwingSet &sw,
                                  const SwingPoint &newH0,
                                  const SwingPoint &newL0,
                                  const SwingPoint &newH02)
   {
      sw.l1 = sw.l0;
      sw.hasL1 = sw.hasL0;
      sw.l0 = newL0;
      sw.hasL0 = true;
      sw.h0 = newH02;
      sw.hasH0 = true;
      sw.h1 = newH0;
      sw.hasH1 = true;
   }
};

#endif // HYPERICT_SWINGENGINE_MQH
