//+------------------------------------------------------------------+
//| Swing.mqh — pivot & swing set H0–L1 (tham khảo HyperICT)         |
//+------------------------------------------------------------------+
#ifndef ICT2026_SWING_MQH
#define ICT2026_SWING_MQH

#include <ICT2026/Types.mqh>

bool IctIsSwingHigh(const string sym, const ENUM_TIMEFRAMES tf,
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

bool IctIsSwingLow(const string sym, const ENUM_TIMEFRAMES tf,
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

void IctSortSwingsByTime(IctSwingPoint &pts[], const int count)
{
   for(int i = 0; i < count - 1; i++)
      for(int j = i + 1; j < count; j++)
         if(pts[j].time < pts[i].time)
         {
            const IctSwingPoint t = pts[i];
            pts[i] = pts[j];
            pts[j] = t;
         }
}

void IctCollectSwings(const string sym, const ENUM_TIMEFRAMES tf,
                      const int range, const int lookback,
                      IctSwingPoint &highs[], IctSwingPoint &lows[])
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
      if(IctIsSwingHigh(sym, tf, sh, range))
      {
         ArrayResize(highs, nH + 1);
         highs[nH].price = iHigh(sym, tf, sh);
         highs[nH].time  = iTime(sym, tf, sh);
         highs[nH].shift = sh;
         nH++;
      }
      if(IctIsSwingLow(sym, tf, sh, range))
      {
         ArrayResize(lows, nL + 1);
         lows[nL].price = iLow(sym, tf, sh);
         lows[nL].time  = iTime(sym, tf, sh);
         lows[nL].shift = sh;
         nL++;
      }
   }
   IctSortSwingsByTime(highs, nH);
   IctSortSwingsByTime(lows, nL);
}

IctSwingPoint IctFindMostRecentOlder(IctSwingPoint &pts[], const int count,
                                     const int anchorShift)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift <= anchorShift)
         continue;
      if(best < 0 || pts[i].shift < pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

// Pivot mới hơn anchor (shift nhỏ hơn = gần hiện tại hơn)
IctSwingPoint IctFindMostRecentNewer(IctSwingPoint &pts[], const int count,
                                     const int anchorShift)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift >= anchorShift)
         continue;
      if(best < 0 || pts[i].shift < pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

// Pivot swing gần anchor nhất (shift nhỏ nhất trong các bar cũ hơn anchor)
IctSwingPoint IctFindNearestSwingHighBefore(IctSwingPoint &pts[], const int count,
                                            const int anchorShift, const double refUpper)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   const double minP = refUpper + _Point;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift <= anchorShift)
         continue;
      if(pts[i].price <= minP)
         continue;
      if(best < 0 || pts[i].shift < pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

IctSwingPoint IctFindNearestSwingLowBefore(IctSwingPoint &pts[], const int count,
                                           const int anchorShift, const double refLower)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   const double maxP = refLower - _Point;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift <= anchorShift)
         continue;
      if(pts[i].price >= maxP)
         continue;
      if(best < 0 || pts[i].shift < pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

IctSwingPoint IctFindFirstSwingLowAfterShift(IctSwingPoint &pts[], const int count,
                                             const int anchorShift)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift >= anchorShift)
         continue;
      if(best < 0 || pts[i].shift > pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

IctSwingPoint IctFindFirstSwingHighAfterShift(IctSwingPoint &pts[], const int count,
                                              const int anchorShift)
{
   IctSwingPoint empty;
   empty.Clear();
   int best = -1;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift >= anchorShift)
         continue;
      if(best < 0 || pts[i].shift > pts[best].shift)
         best = i;
   }
   if(best < 0)
      return empty;
   return pts[best];
}

IctSwingSet IctPickStructuralBear(IctSwingPoint &highs[], const int nH,
                                  IctSwingPoint &lows[], const int nL)
{
   IctSwingSet out;
   out.Clear();
   if(nH < 2 || nL < 2)
      return out;

   out.l0 = lows[nL - 1];
   out.hasL0 = true;

   out.l1 = IctFindMostRecentOlder(lows, nL, out.l0.shift);
   if(!out.l1.Valid())
      return out;
   out.hasL1 = true;

   out.h0 = IctFindMostRecentOlder(highs, nH, out.l1.shift);
   if(!out.h0.Valid())
      return out;
   out.hasH0 = true;

   out.h1 = IctFindMostRecentOlder(highs, nH, out.h0.shift);
   if(!out.h1.Valid())
      return out;
   out.hasH1 = true;

   return out;
}

IctSwingSet IctPickStructuralBull(IctSwingPoint &highs[], const int nH,
                                  IctSwingPoint &lows[], const int nL)
{
   IctSwingSet out;
   out.Clear();
   if(nH < 2 || nL < 2)
      return out;

   out.h0 = highs[nH - 1];
   out.hasH0 = true;

   out.l0 = IctFindMostRecentOlder(lows, nL, out.h0.shift);
   if(!out.l0.Valid())
      return out;
   out.hasL0 = true;

   out.h1 = IctFindMostRecentOlder(highs, nH, out.l0.shift);
   if(!out.h1.Valid())
      return out;
   out.hasH1 = true;

   out.l1 = IctFindMostRecentOlder(lows, nL, out.h1.shift);
   if(!out.l1.Valid())
      return out;
   out.hasL1 = true;

   return out;
}

ENUM_ICT_STRUCT IctClassifyStructure(IctSwingSet &sw)
{
   if(!sw.IsComplete())
      return ICT_STRUCT_NONE;
   if(sw.h0.price > sw.h1.price && sw.l0.price > sw.l1.price)
      return ICT_STRUCT_BULL;
   if(sw.h0.price < sw.h1.price && sw.l0.price < sw.l1.price)
      return ICT_STRUCT_BEAR;
   return ICT_STRUCT_NONE;
}

bool IctIsPullbackValid(IctSwingSet &sw, const double ratio)
{
   if(!sw.IsComplete() || ratio <= 0.0)
      return true;
   const double impulse  = MathAbs(sw.h1.price - sw.l1.price);
   const double pullback = MathAbs(sw.h1.price - sw.l0.price);
   if(impulse <= 0.0)
      return false;
   return pullback >= impulse * ratio;
}

IctSwingSet IctBuildSwingSet(const string sym, const ENUM_TIMEFRAMES tf,
                             const int range, const int lookback,
                             ENUM_ICT_STRUCT &biasOut)
{
   IctSwingSet out;
   out.Clear();
   biasOut = ICT_STRUCT_NONE;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, tf, range, lookback, highs, lows);
   const int nH = ArraySize(highs);
   const int nL = ArraySize(lows);

   IctSwingSet bear = IctPickStructuralBear(highs, nH, lows, nL);
   IctSwingSet bull = IctPickStructuralBull(highs, nH, lows, nL);
   const bool hasBear = bear.IsComplete();
   const bool hasBull = bull.IsComplete();

   const ENUM_ICT_STRUCT biasBear = hasBear ? IctClassifyStructure(bear) : ICT_STRUCT_NONE;
   const ENUM_ICT_STRUCT biasBull = hasBull ? IctClassifyStructure(bull) : ICT_STRUCT_NONE;

   if(biasBear == ICT_STRUCT_BEAR)
   {
      out = bear;
      biasOut = ICT_STRUCT_BEAR;
   }
   else if(biasBull == ICT_STRUCT_BULL)
   {
      out = bull;
      biasOut = ICT_STRUCT_BULL;
   }
   else if(hasBear)
   {
      out = bear;
      biasOut = IctClassifyStructure(bear);
   }
   else if(hasBull)
   {
      out = bull;
      biasOut = IctClassifyStructure(bull);
   }

   return out;
}

// Intraday: 2 đỉnh + 2 đáy gần nhất (mới hơn = phần tử cuối sau sort time)
bool IctTakeLastTwoSwings(IctSwingPoint &pts[], const int count,
                          IctSwingPoint &older, IctSwingPoint &newer)
{
   older.Clear();
   newer.Clear();
   if(count < 2)
      return false;
   older = pts[count - 2];
   newer = pts[count - 1];
   return older.Valid() && newer.Valid();
}

int IctFilterSwingsByMaxShift(IctSwingPoint &pts[], const int count, const int maxShift)
{
   if(maxShift <= 0 || count < 1)
      return count;

   int w = 0;
   for(int i = 0; i < count; i++)
   {
      if(pts[i].shift > maxShift)
         continue;
      if(w != i)
         pts[w] = pts[i];
      w++;
   }
   if(w < count)
      ArrayResize(pts, w);
   return w;
}

// Phân loại HH-HL / LH-LL từ pivot gần nhất — tránh ghép leg 4 swing cũ (sai trên H1)
bool IctBuildSwingSetRecentPivots(const string sym, const ENUM_TIMEFRAMES tf,
                                  const int range, const int lookback,
                                  const int maxRecentShift,
                                  IctSwingSet &out, ENUM_ICT_STRUCT &biasOut)
{
   out.Clear();
   biasOut = ICT_STRUCT_NONE;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, tf, range, lookback, highs, lows);
   int nH = ArraySize(highs);
   int nL = ArraySize(lows);
   if(maxRecentShift > 0)
   {
      nH = IctFilterSwingsByMaxShift(highs, nH, maxRecentShift);
      nL = IctFilterSwingsByMaxShift(lows, nL, maxRecentShift);
   }

   IctSwingPoint hOld, hNew, lOld, lNew;
   if(!IctTakeLastTwoSwings(highs, nH, hOld, hNew))
      return false;
   if(!IctTakeLastTwoSwings(lows, nL, lOld, lNew))
      return false;

   out.h0 = hNew;
   out.hasH0 = true;
   out.h1 = hOld;
   out.hasH1 = true;
   out.l0 = lNew;
   out.hasL0 = true;
   out.l1 = lOld;
   out.hasL1 = true;

   const bool hh = hNew.price > hOld.price + _Point;
   const bool hl = lNew.price > lOld.price + _Point;
   const bool lh = hNew.price < hOld.price - _Point;
   const bool ll = lNew.price < lOld.price - _Point;

   if(hh && hl)
      biasOut = ICT_STRUCT_BULL;
   else if(lh && ll)
      biasOut = ICT_STRUCT_BEAR;
   else
      biasOut = ICT_STRUCT_NONE;

   return out.IsComplete();
}

// M5 confirm: cùng pivot/H0–L1 như label chart (InpConfirmTf)
bool IctBuildConfirmSwingSet(const string sym, IctSwingSet &sw,
                             ENUM_ICT_STRUCT &structuralOut)
{
   sw.Clear();
   structuralOut = ICT_STRUCT_NONE;
   return IctBuildSwingSetRecentPivots(sym, InpConfirmTf,
                                       InpConfirmSwingRange,
                                       InpConfirmSwingLookback,
                                       InpConfirmRecentBars,
                                       sw, structuralOut);
}

void IctGetKeyLevels(const ENUM_ICT_STRUCT bias, IctSwingSet &sw,
                     double &keyLv1, double &keyLv2)
{
   keyLv1 = 0.0;
   keyLv2 = 0.0;
   if(!sw.IsComplete())
      return;

   if(bias == ICT_STRUCT_BULL)
   {
      keyLv1 = sw.l0.price;
      keyLv2 = sw.h0.price;
   }
   else if(bias == ICT_STRUCT_BEAR)
   {
      keyLv1 = sw.h0.price;
      keyLv2 = sw.l0.price;
   }
}

#endif
