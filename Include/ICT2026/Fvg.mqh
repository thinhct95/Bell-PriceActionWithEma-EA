//+------------------------------------------------------------------+
//| Fvg.mqh — iTF Fair Value Gap (Available / Used)                    |
//+------------------------------------------------------------------+
#ifndef ICT2026_FVG_MQH
#define ICT2026_FVG_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/IntradayStructure.mqh>
#include <ICT2026/Swing.mqh>

IctFvgZone   g_ictFvgZones[];
int          g_ictFvgCount = 0;
static ulong g_ictFvgNextId = 1;

ENUM_ICT_FVG_SIDE IctFvgSideFromBias(const ENUM_ICT_BIAS bias)
{
   if(bias == ICT_BIAS_BULL)
      return ICT_FVG_BULL;
   if(bias == ICT_BIAS_BEAR)
      return ICT_FVG_BEAR;
   return ICT_FVG_NONE;
}

string IctFvgSideText(const ENUM_ICT_FVG_SIDE side)
{
   switch(side)
   {
      case ICT_FVG_BULL: return "Bull";
      case ICT_FVG_BEAR: return "Bear";
      default:           return "None";
   }
}

string IctFvgStateText(const ENUM_ICT_FVG_STATE state)
{
   return (state == ICT_FVG_USED) ? "Used" : "Available";
}

string IctPdZoneText(const ENUM_ICT_PD_ZONE zone)
{
   switch(zone)
   {
      case ICT_PD_PREMIUM:     return "Premium";
      case ICT_PD_DISCOUNT:    return "Discount";
      case ICT_PD_EQUILIBRIUM: return "EQ";
      default:                 return "";
   }
}

bool IctFvg_UseGapSizeFilter(const ENUM_TIMEFRAMES tf)
{
   return (tf == InpFvgTf);
}

double IctFvg_MinRequiredGapHeight(const string sym, const ENUM_TIMEFRAMES tf, const int shiftC)
{
   double minH = 0.0;

   if(!IctFvg_UseGapSizeFilter(tf))
      return 0.0;

   if(InpFvgMinGapPoints > 0.0)
      minH = MathMax(minH, InpFvgMinGapPoints);

   if(InpFvgMinGapATRPct > 0.0)
   {
      const int hAtr = iATR(sym, tf, InpFvgAtrPeriod);
      if(hAtr != INVALID_HANDLE)
      {
         double atr[];
         ArraySetAsSeries(atr, true);
         if(CopyBuffer(hAtr, 0, shiftC, 1, atr) == 1 && atr[0] > 0.0)
            minH = MathMax(minH, atr[0] * InpFvgMinGapATRPct / 100.0);
         IndicatorRelease(hAtr);
      }
   }

   return minH;
}

bool IctFvg_IsValidGapSize(const string sym, const ENUM_TIMEFRAMES tf, const int shiftC,
                           const double upper, const double lower)
{
   const double height = upper - lower;
   if(height <= _Point)
      return false;

   if(!IctFvg_UseGapSizeFilter(tf))
      return true;

   const double minH = IctFvg_MinRequiredGapHeight(sym, tf, shiftC);
   if(minH > 0.0 && height + _Point * 0.5 < minH)
      return false;

   if(InpFvgMinGapVsBarPct > 0.0)
   {
      const int shiftB = shiftC + 1;
      const double barRange = iHigh(sym, tf, shiftB) - iLow(sym, tf, shiftB);
      if(barRange > _Point && height < barRange * InpFvgMinGapVsBarPct / 100.0)
         return false;
   }

   return true;
}

bool IctFvg_IsDuplicate(const datetime createdTime, const double upper, const double lower)
{
   const double tol = _Point * 2.0;
   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(g_ictFvgZones[i].createdTime != createdTime)
         continue;
      if(MathAbs(g_ictFvgZones[i].upper - upper) <= tol &&
         MathAbs(g_ictFvgZones[i].lower - lower) <= tol)
         return true;
   }
   return false;
}

bool IctFvg_TryDetectAtShift(const string sym, const ENUM_TIMEFRAMES tf, const int shiftC,
                             ENUM_ICT_FVG_SIDE wantSide,
                             ENUM_ICT_FVG_SIDE &sideOut,
                             double &upperOut, double &lowerOut,
                             datetime &timeAOut, datetime &timeCOut)
{
   sideOut = ICT_FVG_NONE;
   upperOut = 0.0;
   lowerOut = 0.0;
   timeAOut = 0;
   timeCOut = 0;

   const int shiftA = shiftC + 2;
   const int shiftB = shiftC + 1;
   if(shiftA >= Bars(sym, tf))
      return false;

   const double aHi = iHigh(sym, tf, shiftA);
   const double aLo = iLow(sym, tf, shiftA);
   const double cHi = iHigh(sym, tf, shiftC);
   const double cLo = iLow(sym, tf, shiftC);

   if(wantSide == ICT_FVG_BULL)
   {
      if(aHi >= cLo)
         return false;
      const double upper = cLo;
      const double lower = aHi;
      if(!IctFvg_IsValidGapSize(sym, tf, shiftC, upper, lower))
         return false;
      sideOut   = ICT_FVG_BULL;
      upperOut  = upper;
      lowerOut  = lower;
      timeAOut  = iTime(sym, tf, shiftA);
      timeCOut  = iTime(sym, tf, shiftC);
      return true;
   }

   if(wantSide == ICT_FVG_BEAR)
   {
      if(aLo <= cHi)
         return false;
      const double upper = aLo;
      const double lower = cHi;
      if(!IctFvg_IsValidGapSize(sym, tf, shiftC, upper, lower))
         return false;
      sideOut   = ICT_FVG_BEAR;
      upperOut  = upper;
      lowerOut  = lower;
      timeAOut  = iTime(sym, tf, shiftA);
      timeCOut  = iTime(sym, tf, shiftC);
      return true;
   }

   return false;
}

ENUM_ICT_PD_ZONE IctFvg_ClassifyPd(const ENUM_ICT_FVG_SIDE side,
                                     const double fvgMid,
                                     const double pdEq,
                                     const double pdHigh,
                                     const double pdLow)
{
   if(pdHigh <= pdLow || pdEq <= 0.0)
      return ICT_PD_NONE;

   const double tol = (pdHigh - pdLow) * 0.02;
   if(MathAbs(fvgMid - pdEq) <= tol)
      return ICT_PD_EQUILIBRIUM;

   if(side == ICT_FVG_BULL)
      return (fvgMid < pdEq) ? ICT_PD_DISCOUNT : ICT_PD_PREMIUM;

   if(side == ICT_FVG_BEAR)
      return (fvgMid > pdEq) ? ICT_PD_PREMIUM : ICT_PD_DISCOUNT;

   return ICT_PD_NONE;
}

bool IctFvg_OverlapsPremium(const IctFvgZone &zone)
{
   if(zone.pdEq <= 0.0 || zone.pdHigh <= zone.pdLow + _Point)
      return false;
   return (zone.upper > zone.pdEq + _Point && zone.lower < zone.pdHigh + _Point);
}

bool IctFvg_OverlapsDiscount(const IctFvgZone &zone)
{
   if(zone.pdEq <= 0.0 || zone.pdHigh <= zone.pdLow + _Point)
      return false;
   return (zone.lower < zone.pdEq - _Point && zone.upper > zone.pdLow - _Point);
}

// % chiều cao FVG nằm trên equilibrium (Premium portion)
double IctFvg_PremiumOverlapPct(const IctFvgZone &zone)
{
   const double h = zone.upper - zone.lower;
   if(h <= _Point || zone.pdEq <= 0.0)
      return 0.0;
   const double premLo  = MathMax(zone.lower, zone.pdEq);
   const double portion = MathMax(0.0, zone.upper - premLo);
   return 100.0 * portion / h;
}

// % chiều cao FVG nằm dưới equilibrium (Discount portion)
double IctFvg_DiscountOverlapPct(const IctFvgZone &zone)
{
   const double h = zone.upper - zone.lower;
   if(h <= _Point || zone.pdEq <= 0.0)
      return 0.0;
   const double discHi  = MathMin(zone.upper, zone.pdEq);
   const double portion = MathMax(0.0, discHi - zone.lower);
   return 100.0 * portion / h;
}

ENUM_ICT_PD_ZONE IctFvg_ComputeRepPd(const IctFvgZone &zone)
{
   if(zone.pdEq <= 0.0)
      return ICT_PD_NONE;

   const bool inPrem = IctFvg_OverlapsPremium(zone);
   const bool inDisc = IctFvg_OverlapsDiscount(zone);

   if(inPrem && !inDisc)
      return ICT_PD_PREMIUM;
   if(inDisc && !inPrem)
      return ICT_PD_DISCOUNT;
   if(inPrem && inDisc)
   {
      if(zone.side == ICT_FVG_BEAR)
         return ICT_PD_PREMIUM;
      if(zone.side == ICT_FVG_BULL)
         return ICT_PD_DISCOUNT;
   }
   return ICT_PD_NONE;
}

double IctFvg_BarExtremeSince(const string sym, const ENUM_TIMEFRAMES tf,
                              const datetime fromTime, const bool wantLow)
{
   double v = wantLow ? DBL_MAX : -DBL_MAX;
   bool   ok = false;

   for(int sh = 0; sh < Bars(sym, tf); sh++)
   {
      const datetime t = iTime(sym, tf, sh);
      if(t < fromTime)
         break;

      const double px = wantLow ? iLow(sym, tf, sh) : iHigh(sym, tf, sh);
      if(wantLow)
         v = MathMin(v, px);
      else
         v = MathMax(v, px);
      ok = true;
   }
   return ok ? v : 0.0;
}

bool IctFvg_IsConfirmedPivot(const string sym, const ENUM_TIMEFRAMES tf,
                             const IctSwingPoint &pt, const bool isHigh)
{
   if(!pt.Valid() || pt.shift < 1)
      return false;
   const int str = MathMax(1, InpIntradaySwingRange);
   if(pt.shift < str + 1)
      return false;
   if(isHigh)
      return IctIsSwingHigh(sym, tf, pt.shift, str);
   return IctIsSwingLow(sym, tf, pt.shift, str);
}

// Đỉnh PD bear = pivot swing high gần FVG nhất (theo bar shift), trên upper — không dùng wick nến
bool IctFvg_ResolvePdHighBear(const string sym, const IctFvgZone &zone, double &outHigh)
{
   outHigh = 0.0;

   const ENUM_TIMEFRAMES pdTf = InpIntradayTf;
   int fvgShift = iBarShift(sym, pdTf, zone.createdTime, true);
   if(fvgShift < 0)
      fvgShift = iBarShift(sym, pdTf, zone.createdTime, false);
   if(fvgShift < 0)
      return false;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, pdTf, InpIntradaySwingRange, InpIntradaySwingLookback, highs, lows);
   const int nH = ArraySize(highs);

   IctSwingPoint pt = IctFindNearestSwingHighBefore(highs, nH, fvgShift, zone.upper);
   if(!pt.Valid())
      return false;

   outHigh = pt.price;
   return true;
}

// Đáy PD bull = pivot swing low gần FVG nhất (theo bar shift), dưới lower
bool IctFvg_ResolvePdLowBull(const string sym, const IctFvgZone &zone, double &outLow)
{
   outLow = 0.0;

   const ENUM_TIMEFRAMES pdTf = InpIntradayTf;
   int fvgShift = iBarShift(sym, pdTf, zone.createdTime, true);
   if(fvgShift < 0)
      fvgShift = iBarShift(sym, pdTf, zone.createdTime, false);
   if(fvgShift < 0)
      return false;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, pdTf, InpIntradaySwingRange, InpIntradaySwingLookback, highs, lows);
   const int nL = ArraySize(lows);

   IctSwingPoint pt = IctFindNearestSwingLowBefore(lows, nL, fvgShift, zone.lower);
   if(!pt.Valid())
      return false;

   outLow = pt.price;
   return true;
}

bool IctFvg_NearestLowBelow(const string sym, const double refLower,
                            const datetime beforeTime, double &outLow)
{
   outLow = 0.0;
   double best = -DBL_MAX;
   bool   found = false;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, InpIntradayTf, InpIntradaySwingRange, InpIntradaySwingLookback,
                    highs, lows);
   const int nL = ArraySize(lows);

   for(int i = 0; i < nL; i++)
   {
      if(lows[i].price >= refLower - _Point)
         continue;
      if(lows[i].time > beforeTime)
         continue;
      if(lows[i].price > best)
      {
         best  = lows[i].price;
         found = true;
      }
   }

   IctSwingSet sw = g_ictIntraday.swings;
   if(sw.hasL0 && sw.l0.price < refLower - _Point && sw.l0.time <= beforeTime &&
      sw.l0.price > best)
   {
      best  = sw.l0.price;
      found = true;
   }
   if(sw.hasL1 && sw.l1.price < refLower - _Point && sw.l1.time <= beforeTime &&
      sw.l1.price > best)
   {
      best  = sw.l1.price;
      found = true;
   }

   if(!found)
   {
      const int maxBars = MathMax(InpIntradayRecentBars, 30);
      for(int sh = 0; sh < maxBars && sh < Bars(sym, InpIntradayTf); sh++)
      {
         const datetime t = iTime(sym, InpIntradayTf, sh);
         if(t > beforeTime)
            continue;
         const double l = iLow(sym, InpIntradayTf, sh);
         if(l < refLower - _Point && l > best)
         {
            best  = l;
            found = true;
         }
      }
   }

   if(!found)
      return false;

   outLow = best;
   return true;
}

bool IctFvg_FindFirstSwingLowAfter(const IctSwingPoint &lows[], const int nL,
                                  const datetime afterTime, IctSwingPoint &out)
{
   out.Clear();
   for(int i = 0; i < nL; i++)
   {
      if(lows[i].time >= afterTime)
      {
         out = lows[i];
         return true;
      }
   }
   return false;
}

bool IctFvg_FindFirstSwingHighAfter(const IctSwingPoint &highs[], const int nH,
                                    const datetime afterTime, IctSwingPoint &out)
{
   out.Clear();
   for(int i = 0; i < nH; i++)
   {
      if(highs[i].time >= afterTime)
      {
         out = highs[i];
         return true;
      }
   }
   return false;
}

bool IctFvg_MatchesBias(const IctFvgZone &zone)
{
   const ENUM_ICT_FVG_SIDE want = IctFvgSideFromBias(g_ictDailyBias.bias);
   return (want != ICT_FVG_NONE && zone.side == want);
}

void IctFvg_FinalizePdMetrics(IctFvgZone &zone)
{
   if(zone.pdHigh <= zone.pdLow + _Point)
      return;

   zone.pdEq = (zone.pdHigh + zone.pdLow) * 0.5;
   const double mid = (zone.upper + zone.lower) * 0.5;
   zone.pdZone = IctFvg_ClassifyPd(zone.side, mid, zone.pdEq, zone.pdHigh, zone.pdLow);
   zone.repPd  = IctFvg_ComputeRepPd(zone);
}

ENUM_ICT_PD_ZONE IctFvg_GetRepPd(const IctFvgZone &zone)
{
   if(zone.repPd != ICT_PD_NONE)
      return zone.repPd;
   return zone.pdZone;
}

bool IctFvg_IsEntryRepPd(const IctFvgZone &zone)
{
   if(zone.pdEq <= 0.0)
      return false;
   const double minPct = MathMax(0.0, MathMin(100.0, InpFvgPdMinOverlapPct));
   double pct = 0.0;
   if(g_ictDailyBias.bias == ICT_BIAS_BEAR)
      pct = IctFvg_PremiumOverlapPct(zone);
   else if(g_ictDailyBias.bias == ICT_BIAS_BULL)
      pct = IctFvg_DiscountOverlapPct(zone);
   else
      return false;

   // minPct = 0 → chấp nhận bất kỳ overlap > 0
   if(minPct <= 0.0)
      return pct > 1e-9;
   return pct >= minPct - 1e-9;
}

// Touch threshold cho POI:
//  - FVG nằm hẳn trong Premium (bear) / Discount (bull) → 25%
//  - FVG straddle equilibrium (mixed) → 50%
//  - Trả về 100 nếu FVG sai vùng (không thể là POI)
double IctFvg_RequiredTouchFillPct(const IctFvgZone &zone)
{
   if(zone.pdEq <= 0.0)
      return 100.0;
   double pct = 0.0;
   if(g_ictDailyBias.bias == ICT_BIAS_BEAR)
      pct = IctFvg_PremiumOverlapPct(zone);
   else if(g_ictDailyBias.bias == ICT_BIAS_BULL)
      pct = IctFvg_DiscountOverlapPct(zone);
   else
      return 100.0;

   if(pct >= 100.0 - 1e-6)
      return InpFvgTouchFillPure;   // 100% trong vùng đúng → threshold thấp
   if(pct > 1e-9)
      return InpFvgTouchFillMixed;  // Mixed → threshold cao
   return 100.0;                     // 0% trong vùng đúng → không qualify
}

bool IctFvg_HasFillAtLeast(const IctFvgZone &zone, const double pct)
{
   if(pct <= 0.0)
      return true;
   return (zone.maxFillRatio >= pct / 100.0 - 1e-9);
}

double IctFvg_PriceAtFillPct(const IctFvgZone &zone, const double pct)
{
   const double h = zone.upper - zone.lower;
   if(h <= _Point)
      return 0.0;
   const double r = MathMax(0.0, MathMin(100.0, pct)) / 100.0;
   if(zone.side == ICT_FVG_BULL)
      return zone.upper - h * r;
   if(zone.side == ICT_FVG_BEAR)
      return zone.lower + h * r;
   return 0.0;
}

void IctFvg_UpdatePdForZone(const string sym, IctFvgZone &zone)
{
   if(zone.pdComplete)
      return;

   zone.pdRangeStart = zone.createdTime;

   const ENUM_TIMEFRAMES pdTf = InpIntradayTf;
   const int pdPeriod         = (int)PeriodSeconds(pdTf);
   datetime nowEnd            = iTime(sym, pdTf, 0) + pdPeriod;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, pdTf, InpIntradaySwingRange, InpIntradaySwingLookback, highs, lows);
   const int nL = ArraySize(lows);
   const int nH = ArraySize(highs);

   int fvgShift = iBarShift(sym, pdTf, zone.createdTime, true);
   if(fvgShift < 0)
      fvgShift = iBarShift(sym, pdTf, zone.createdTime, false);

   if(zone.side == ICT_FVG_BEAR)
   {
      if(!zone.pdSwing1Set)
      {
         if(!IctFvg_ResolvePdHighBear(sym, zone, zone.pdHigh))
            return;
         zone.pdSwing1Set = true;
      }

      IctSwingPoint swingLow;
      if(fvgShift >= 0)
         swingLow = IctFindFirstSwingLowAfterShift(lows, nL, fvgShift);
      else
         IctFvg_FindFirstSwingLowAfter(lows, nL, zone.createdTime, swingLow);

      if(swingLow.Valid() &&
         IctFvg_IsConfirmedPivot(sym, pdTf, swingLow, false))
      {
         zone.pdLow        = swingLow.price;
         zone.pdRangeEnd   = swingLow.time + pdPeriod;
         zone.pdComplete   = true;
      }
      else
      {
         const double runLo = IctFvg_BarExtremeSince(sym, pdTf, zone.createdTime, true);
         if(runLo <= 0.0)
            return;
         zone.pdLow      = runLo;
         zone.pdRangeEnd = nowEnd;
      }
   }
   else if(zone.side == ICT_FVG_BULL)
   {
      if(!zone.pdSwing1Set)
      {
         if(!IctFvg_ResolvePdLowBull(sym, zone, zone.pdLow))
            return;
         zone.pdSwing1Set = true;
      }

      IctSwingPoint swingHigh;
      if(fvgShift >= 0)
         swingHigh = IctFindFirstSwingHighAfterShift(highs, nH, fvgShift);
      else
         IctFvg_FindFirstSwingHighAfter(highs, nH, zone.createdTime, swingHigh);

      if(swingHigh.Valid() &&
         IctFvg_IsConfirmedPivot(sym, pdTf, swingHigh, true))
      {
         zone.pdHigh       = swingHigh.price;
         zone.pdRangeEnd   = swingHigh.time + pdPeriod;
         zone.pdComplete   = true;
      }
      else
      {
         const double runHi = IctFvg_BarExtremeSince(sym, pdTf, zone.createdTime, false);
         if(runHi <= 0.0)
            return;
         zone.pdHigh     = runHi;
         zone.pdRangeEnd = nowEnd;
      }
   }
   else
      return;

   IctFvg_FinalizePdMetrics(zone);
}

void IctFvg_UpdateAllPd(const string sym)
{
   for(int i = 0; i < g_ictFvgCount; i++)
      IctFvg_UpdatePdForZone(sym, g_ictFvgZones[i]);
}

void IctFvg_AddZone(const IctFvgZone &zone)
{
   if(g_ictFvgCount >= InpFvgMaxZones)
   {
      for(int i = 0; i < g_ictFvgCount - 1; i++)
         g_ictFvgZones[i] = g_ictFvgZones[i + 1];
      g_ictFvgCount--;
   }

   ArrayResize(g_ictFvgZones, g_ictFvgCount + 1);
   g_ictFvgZones[g_ictFvgCount] = zone;
   g_ictFvgCount++;
}

bool IctFvg_BarTouchesZone(const ENUM_ICT_FVG_SIDE side,
                           const double barHigh, const double barLow,
                           const double upper, const double lower)
{
   if(barHigh < barLow)
      return false;
   if(barHigh < lower - _Point || barLow > upper + _Point)
      return false;

   if(side == ICT_FVG_BULL)
      return (barLow <= upper + _Point);
   if(side == ICT_FVG_BEAR)
      return (barHigh >= lower - _Point);
   return false;
}

void IctFvg_RegisterTouch(IctFvgZone &zone, const datetime barTime)
{
   if(barTime <= zone.createdTime)
      return;
   if(zone.firstTouchTime == 0 || barTime < zone.firstTouchTime)
      zone.firstTouchTime = barTime;
}

void IctFvg_UpdateTouchAndFill(const string sym, const ENUM_TIMEFRAMES tf, IctFvgZone &zone)
{
   zone.maxFillRatio    = 0.0;
   zone.firstTouchTime  = 0;

   const double height = zone.upper - zone.lower;
   if(height <= _Point)
      return;

   double deepest = zone.upper;

   for(int sh = 1; sh < Bars(sym, tf); sh++)
   {
      const datetime t = iTime(sym, tf, sh);
      if(t <= zone.createdTime)
         break;

      const double barHi = iHigh(sym, tf, sh);
      const double barLo = iLow(sym, tf, sh);

      if(IctFvg_BarTouchesZone(zone.side, barHi, barLo, zone.upper, zone.lower))
         IctFvg_RegisterTouch(zone, t);

      if(zone.side == ICT_FVG_BULL)
      {
         if(barLo >= zone.upper)
            continue;
         if(barLo <= zone.lower)
            zone.maxFillRatio = 1.0;
         else
            deepest = MathMin(deepest, barLo);
      }
      else if(zone.side == ICT_FVG_BEAR)
      {
         if(barHi <= zone.lower)
            continue;
         if(barHi >= zone.upper)
            zone.maxFillRatio = 1.0;
         else
            deepest = MathMax(deepest, barHi);
      }
   }

   const datetime t0 = iTime(sym, tf, 0);
   if(t0 > zone.createdTime)
   {
      const double barHi0 = iHigh(sym, tf, 0);
      const double barLo0 = iLow(sym, tf, 0);
      if(IctFvg_BarTouchesZone(zone.side, barHi0, barLo0, zone.upper, zone.lower))
         IctFvg_RegisterTouch(zone, t0);

      if(zone.side == ICT_FVG_BULL && barLo0 < zone.upper)
      {
         if(barLo0 <= zone.lower)
            zone.maxFillRatio = 1.0;
         else
            deepest = MathMin(deepest, barLo0);
      }
      else if(zone.side == ICT_FVG_BEAR && barHi0 > zone.lower)
      {
         if(barHi0 >= zone.upper)
            zone.maxFillRatio = 1.0;
         else
            deepest = MathMax(deepest, barHi0);
      }
   }

   if(zone.maxFillRatio < 1.0)
   {
      if(zone.side == ICT_FVG_BULL)
         zone.maxFillRatio = (zone.upper - deepest) / height;
      else if(zone.side == ICT_FVG_BEAR)
         zone.maxFillRatio = (deepest - zone.lower) / height;
   }
}

datetime IctFvg_GetFvgDrawTimeEnd(const string sym, const ENUM_TIMEFRAMES tf,
                                  const IctFvgZone &zone)
{
   const int periodSec = (int)PeriodSeconds(tf);

   if(zone.state == ICT_FVG_USED)
   {
      if(zone.fvgUsedTime > 0)
         return zone.fvgUsedTime + periodSec;
      return zone.createdTime + periodSec;
   }

   const datetime barEnd = iTime(sym, tf, 0) + periodSec;
   if(zone.expireTime > 0 && barEnd > zone.expireTime)
      return zone.expireTime;
   return barEnd;
}

datetime IctFvg_GetPdDrawTimeEnd(const IctFvgZone &zone)
{
   if(zone.pdRangeEnd > zone.pdRangeStart)
      return zone.pdRangeEnd;
   return zone.createdTime + (datetime)PeriodSeconds(InpIntradayTf);
}

void IctFvg_UpdateZoneState(const string sym, const ENUM_TIMEFRAMES tf, IctFvgZone &zone)
{
   const ENUM_ICT_FVG_STATE prevState = zone.state;

   IctFvg_UpdateTouchAndFill(sym, tf, zone);

   if(tf != InpFvgTf)
   {
      const double usedPct = InpFvgUsedFillPct / 100.0;
      if(zone.maxFillRatio >= usedPct || zone.maxFillRatio >= 0.999)
         zone.state = ICT_FVG_USED;
   }

   if(zone.state == ICT_FVG_USED && prevState == ICT_FVG_AVAILABLE && zone.fvgUsedTime == 0)
      zone.fvgUsedTime = iTime(sym, tf, 0);

   zone.timeEnd = IctFvg_GetFvgDrawTimeEnd(sym, tf, zone);
}

void IctFvg_RemoveAt(const int index)
{
   if(index < 0 || index >= g_ictFvgCount)
      return;
   for(int i = index; i < g_ictFvgCount - 1; i++)
      g_ictFvgZones[i] = g_ictFvgZones[i + 1];
   g_ictFvgCount--;
   ArrayResize(g_ictFvgZones, g_ictFvgCount);
}

void IctFvg_PurgeExpired()
{
   const datetime now = TimeCurrent();
   for(int i = g_ictFvgCount - 1; i >= 0; i--)
   {
      if(!IctFvg_MatchesBias(g_ictFvgZones[i]) &&
         g_ictFvgZones[i].state == ICT_FVG_AVAILABLE)
      {
         IctFvg_RemoveAt(i);
         continue;
      }
      if(g_ictFvgZones[i].state == ICT_FVG_AVAILABLE &&
         g_ictFvgZones[i].expireTime > 0 &&
         now >= g_ictFvgZones[i].expireTime)
         IctFvg_RemoveAt(i);
   }
}

void IctFvg_ScanNew(const string sym, const ENUM_TIMEFRAMES tf,
                    const ENUM_ICT_FVG_SIDE wantSide,
                    const bool fullLookback = false)
{
   if(wantSide == ICT_FVG_NONE)
      return;

   const int maxShift = MathMin(InpFvgLookbackBars, Bars(sym, tf) - 3);
   if(maxShift < 1)
      return;

   int fromSh = 1;
   if(fullLookback)
      fromSh = maxShift;
   else
   {
      const int scanN = MathMax(1, InpFvgScanBarsPerUpdate);
      fromSh = MathMin(maxShift, scanN);
   }
   for(int sh = fromSh; sh >= 1; sh--)
   {
      ENUM_ICT_FVG_SIDE side = ICT_FVG_NONE;
      double upper = 0.0, lower = 0.0;
      datetime timeA = 0, timeC = 0;

      if(!IctFvg_TryDetectAtShift(sym, tf, sh, wantSide, side, upper, lower, timeA, timeC))
         continue;
      if(IctFvg_IsDuplicate(timeC, upper, lower))
         continue;

      IctFvgZone zone;
      zone.Clear();
      zone.id          = g_ictFvgNextId++;
      zone.side        = side;
      zone.state       = ICT_FVG_AVAILABLE;
      zone.upper       = upper;
      zone.lower       = lower;
      zone.createdTime = timeC;
      zone.timeStart   = timeA;
      zone.expireTime  = timeC + (datetime)(InpFvgExpireDays * 86400);
      zone.locked      = true;
      IctFvg_UpdateZoneState(sym, tf, zone);

      IctFvg_AddZone(zone);

      if(InpDebug)
         PrintFormat("[ICT2026/FVG] New %s %s [%.2f – %.2f] | %s | fill=%.1f%%",
                     IctFvgSideText(zone.side), IctFvgStateText(zone.state),
                     zone.lower, zone.upper, IctPdZoneText(zone.pdZone),
                     zone.maxFillRatio * 100.0);
   }

   IctFvg_UpdateAllPd(sym);
}

void IctFvg_UpdateAll(const string sym, const ENUM_TIMEFRAMES tf)
{
   for(int i = 0; i < g_ictFvgCount; i++)
      IctFvg_UpdateZoneState(sym, tf, g_ictFvgZones[i]);
   IctFvg_UpdateAllPd(sym);
   IctFvg_PurgeExpired();
}

void IctFvg_Reset()
{
   g_ictFvgCount = 0;
   ArrayResize(g_ictFvgZones, 0);
}

int IctFvg_CountAvailable()
{
   int n = 0;
   for(int i = 0; i < g_ictFvgCount; i++)
      if(g_ictFvgZones[i].state == ICT_FVG_AVAILABLE)
         n++;
   return n;
}

#endif
