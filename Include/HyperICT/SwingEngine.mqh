//+------------------------------------------------------------------+
//| SwingEngine.mqh                                                  |
//| Pivot HTF, H0–L1, khóa snapshot, roll swing §1.4                 |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • H0–L1 ghép theo leg (Key LV1 tạo Key LV2), không 2H+2L tách rời |
//|  • Bear: L0=KeyLV2, H0=đỉnh trước L1 (tạo đáy L0); đỉnh sau L0→newH0 |
//|  • Bull: H0=KeyLV2, L0=đáy trước H1 (tạo đỉnh H0)               |
//|  • HH-HL / LH-LL — ClassifyStructure                             |
//|  • Khóa swing lúc bot chạy — LockInitialSnapshot (không đổi mỗi nến) |
//|  • §1.4 roll: Continue, CHoCH case1 (L1 giữ), CHoCH case2 bear   |
//|  • Xác nhận pivot sau phá Key — IsConfirmedSwingHigh/Low + range   |
//| CHƯA TỐI ƯU: quét OB chất lượng ICT (mitigation)                 |
//+------------------------------------------------------------------+
#ifndef HYPERICT_SWINGENGINE_MQH
#define HYPERICT_SWINGENGINE_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>

class CSwingEngine
{
public:
   //--- Pivot chuẩn: `range` nến mỗi phía (dùng cho §1.4 confirm đỉnh/đáy)
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

   // Pivot cũ hơn anchor (shift > anchor) và GẦN anchor nhất (shift nhỏ nhất trong các ứng viên)
   static bool FindMostRecentOlder(const SwingPoint &pts[], const int count,
                                   const int anchorShift,
                                   SwingPoint &out)
   {
      int best = -1;
      for(int i = 0; i < count; i++)
      {
         if(pts[i].shift <= anchorShift)
            continue;
         if(best < 0 || pts[i].shift < pts[best].shift)
            best = i;
      }
      if(best < 0)
         return false;
      out = pts[best];
      return true;
   }

   // Thứ tự thời gian (cũ → mới): Bear H1→L1→H0→L0 | Bull L1→H1→L0→H0
   static bool ValidateSwingChronology(const SwingSet &sw, const ENUM_STRUCT_BIAS bias)
   {
      if(!sw.IsComplete())
         return false;
      if(bias == STRUCT_BEAR)
         return sw.h1.shift > sw.l1.shift &&
                sw.l1.shift > sw.h0.shift &&
                sw.h0.shift > sw.l0.shift;
      if(bias == STRUCT_BULL)
         return sw.l1.shift > sw.h1.shift &&
                sw.h1.shift > sw.l0.shift &&
                sw.l0.shift > sw.h0.shift;
      return false;
   }

   //--- Bear: L0=KeyLV2, H0=KeyLV1 | Chuỗi: H1 → L1 → H0 → L0
   static bool PickStructuralBear(const SwingPoint &highs[], const int nH,
                                  const SwingPoint &lows[], const int nL,
                                  SwingSet &out)
   {
      out.Clear();
      if(nH < 2 || nL < 2)
         return false;

      out.l0 = lows[nL - 1];
      out.hasL0 = true;

      if(!FindMostRecentOlder(lows, nL, out.l0.shift, out.l1))
         return false;
      out.hasL1 = true;

      if(!FindMostRecentOlder(highs, nH, out.l1.shift, out.h0))
         return false;
      out.hasH0 = true;

      if(!FindMostRecentOlder(highs, nH, out.h0.shift, out.h1))
         return false;
      out.hasH1 = true;

      return true;
   }

   //--- Bull: H0=KeyLV2, L0=KeyLV1 | Chuỗi: L1 → H1 → L0 → H0
   static bool PickStructuralBull(const SwingPoint &highs[], const int nH,
                                  const SwingPoint &lows[], const int nL,
                                  SwingSet &out)
   {
      out.Clear();
      if(nH < 2 || nL < 2)
         return false;

      out.h0 = highs[nH - 1];
      out.hasH0 = true;

      if(!FindMostRecentOlder(lows, nL, out.h0.shift, out.l0))
         return false;
      out.hasL0 = true;

      if(!FindMostRecentOlder(highs, nH, out.l0.shift, out.h1))
         return false;
      out.hasH1 = true;

      if(!FindMostRecentOlder(lows, nL, out.h1.shift, out.l1))
         return false;
      out.hasL1 = true;

      return true;
   }

   //--- §1.1 tiên quyết đặc điểm 1: HH-HL hoặc LH-LL
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
      const int nH = ArraySize(highs);
      const int nL = ArraySize(lows);

      SwingSet bear, bull;
      const bool hasBear = PickStructuralBear(highs, nH, lows, nL, bear);
      const bool hasBull = PickStructuralBull(highs, nH, lows, nL, bull);

      const ENUM_STRUCT_BIAS biasBear = hasBear ? ClassifyStructure(bear) : STRUCT_NONE;
      const ENUM_STRUCT_BIAS biasBull = hasBull ? ClassifyStructure(bull) : STRUCT_NONE;

      ENUM_STRUCT_BIAS chosen = STRUCT_NONE;
      if(biasBear == STRUCT_BEAR)
      {
         out = bear;
         chosen = STRUCT_BEAR;
      }
      else if(biasBull == STRUCT_BULL)
      {
         out = bull;
         chosen = STRUCT_BULL;
      }
      else if(hasBear)
      {
         out = bear;
         chosen = ClassifyStructure(bear);
      }
      else if(hasBull)
      {
         out = bull;
         chosen = ClassifyStructure(bull);
      }
      else
         return false;

      if(InpDebug && chosen != STRUCT_NONE && !ValidateSwingChronology(out, chosen))
         Print("[HyperICT/Swing] Cảnh báo: thứ tự H/L không khớp chuỗi chuẩn");

      return out.IsComplete();
   }

   //--- § chú ý: snapshot HTF cố định từ khi bot chạy (chỉ đổi qua UpdateEngine)
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

   //--- §1.4a Bull Continue P2: H0→H1, L0→L1, newH0→H0, newL0→L0
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

   //--- §1.4b Bull CHoCH P3 case1: H0→H1, L1 giữ, newL0→L0, newH0→H0
   static void RollBullChochCase1(SwingSet &sw, const SwingPoint &newH0, const SwingPoint &newL0)
   {
      sw.h1 = sw.h0;
      sw.hasH1 = sw.hasH0;
      // L1 giữ nguyên theo spec
      sw.l0 = newL0;
      sw.hasL0 = true;
      sw.h0 = newH0;
      sw.hasH0 = true;
   }

   //--- §1.4b Bull CHoCH P3 case2: confirm bear — H0→H1, newH0→H0, newL0→L1, newL02→L0
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

   //--- §1.4c Bear Continue (đối xứng bull continue)
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
