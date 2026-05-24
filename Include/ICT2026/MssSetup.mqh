//+------------------------------------------------------------------+
//| MssSetup.mqh — MSS: retest FVG H1 → M5 MSS (phá L0/H0) → M5 FVG → entry |
//+------------------------------------------------------------------+
#ifndef ICT2026_MSSSETUP_MQH
#define ICT2026_MSSSETUP_MQH

#include <ICT2026/ConfirmFvg.mqh>
#include <ICT2026/Journal.mqh>
#include <ICT2026/LowTfApi.mqh>
#include <ICT2026/StructureCore.mqh>
#include <ICT2026/Swing.mqh>

string IctMssPhaseText(const ENUM_ICT_MSS_PHASE ph)
{
   switch(ph)
   {
      case ICT_MSS_H1_TOUCH:    return "Retest FVG H1 OK";
      case ICT_MSS_CHOCH:       return "MSS OK";
      case ICT_MSS_M5_FVG:      return "M5 FVG";
      case ICT_MSS_ENTRY_FILL:  return "M5 fill entry";
      case ICT_MSS_READY:       return "READY entry";
      default:                  return "Idle";
   }
}

int IctMss_FindH1FvgById(const ulong id)
{
   for(int i = 0; i < g_ictFvgCount; i++)
      if(g_ictFvgZones[i].id == id)
         return i;
   return -1;
}

// POI H1: FVG chưa Used, gần giá nhất (không phải Premium cao nhất / Discount thấp nhất)
double IctMss_DistancePriceToFvg(const double price, const IctFvgZone &z)
{
   if(price >= z.lower - _Point && price <= z.upper + _Point)
      return 0.0;
   if(price > z.upper)
      return price - z.upper;
   return z.lower - price;
}

bool IctMss_IsH1PoiEligible(const IctFvgZone &z)
{
   if(!IctFvg_MatchesBias(z))
      return false;
   if(!IctFvg_IsEntryRepPd(z))
      return false;
   if(z.state == ICT_FVG_USED)
      return false;
   return true;
}

int IctMss_CountH1PoiEligible()
{
   int n = 0;
   for(int i = 0; i < g_ictFvgCount; i++)
      if(IctMss_IsH1PoiEligible(g_ictFvgZones[i]))
         n++;
   return n;
}

int IctMss_SelectNearestH1Poi(const string sym)
{
   const double px = SymbolInfoDouble(sym, SYMBOL_BID);
   int    bestIdx  = -1;
   double bestDist = DBL_MAX;

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(!IctMss_IsH1PoiEligible(g_ictFvgZones[i]))
         continue;

      const double d = IctMss_DistancePriceToFvg(px, g_ictFvgZones[i]);
      if(d < bestDist - _Point)
      {
         bestDist = d;
         bestIdx  = i;
      }
      else if(MathAbs(d - bestDist) <= _Point && bestIdx >= 0)
      {
         if(g_ictFvgZones[i].createdTime > g_ictFvgZones[bestIdx].createdTime)
            bestIdx = i;
      }
   }
   return bestIdx;
}

bool IctMss_PriceInsideFvg(const IctFvgZone &h1, const double price)
{
   return (price >= h1.lower - _Point && price <= h1.upper + _Point);
}

bool IctMss_BarOverlapsFvg(const IctFvgZone &h1, const double barHi, const double barLo)
{
   return (barHi >= h1.lower - _Point && barLo <= h1.upper + _Point);
}

bool IctMss_LivePriceTouchesFvg(const string sym, const IctFvgZone &h1)
{
   const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   return IctMss_PriceInsideFvg(h1, bid) || IctMss_PriceInsideFvg(h1, ask);
}

datetime IctMss_FirstM5TouchInFvg(const string sym, const IctFvgZone &h1)
{
   const ENUM_TIMEFRAMES tf = InpConfirmTf;
   const int lim = MathMin(InpMssConfirmLookback, iBars(sym, tf) - 2);
   datetime best = 0;
   for(int sh = lim; sh >= 1; sh--)
   {
      const datetime t = iTime(sym, tf, sh);
      if(t <= h1.createdTime)
         break;
      if(!IctMss_BarOverlapsFvg(h1, iHigh(sym, tf, sh), iLow(sym, tf, sh)))
         continue;
      if(best == 0 || t < best)
         best = t;
   }
   return best;
}

datetime IctMss_GetFvgTouchTime(const string sym, IctFvgZone &h1)
{
   IctFvg_UpdateZoneState(sym, InpFvgTf, h1);

   datetime t = h1.firstTouchTime;
   const datetime tM5 = IctMss_FirstM5TouchInFvg(sym, h1);
   if(tM5 > 0 && (t <= 0 || tM5 < t))
      t = tM5;

   if(t <= 0 && IctMss_LivePriceTouchesFvg(sym, h1))
      t = iTime(sym, InpConfirmTf, 0);

   return t;
}

// Retest = giá chạm FVG (H1/M5/bid-ask). Râu H1 xuyên FVG vẫn OK; chỉ hủy khi H1 body đóng xuyên.
bool IctMss_HasFvgPriceTouch(const string sym, IctFvgZone &h1)
{
   return (IctMss_GetFvgTouchTime(sym, h1) > 0);
}

bool IctMss_HasH1FvgRetest(const string sym, IctFvgZone &h1)
{
   return IctMss_HasFvgPriceTouch(sym, h1);
}

double IctMss_H1Atr(const string sym)
{
   const int h = iATR(sym, InpFvgTf, InpFvgAtrPeriod);
   if(h == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, 1, 1, buf) != 1)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   IndicatorRelease(h);
   return buf[0];
}

double IctMss_H1ZoneBuffer(const IctFvgZone &h1, const string sym)
{
   const double gapH = h1.upper - h1.lower;
   double buf = (gapH > _Point && InpMssMaxDistGapPct > 0.0) ?
                gapH * InpMssMaxDistGapPct / 100.0 : 0.0;
   const double atr = IctMss_H1Atr(sym);
   if(atr > 0.0 && InpMssMaxDistAtrMult > 0.0)
      buf = MathMax(buf, atr * InpMssMaxDistAtrMult);
   if(buf <= 0.0)
      buf = MathMax(gapH * 0.5, 20.0 * _Point);
   return buf;
}

void IctMss_GetH1ProximityBounds(const IctFvgZone &h1, const string sym,
                                 const ENUM_ICT_BIAS bias,
                                 double &outLo, double &outHi)
{
   const double gapH = h1.upper - h1.lower;
   const double buf  = IctMss_H1ZoneBuffer(h1, sym);
   outLo = h1.lower - buf;
   outHi = h1.upper + buf;

   if(gapH <= _Point)
      return;

   if(bias == ICT_BIAS_BEAR && InpMssExtraBelowGapPct > 0.0)
      outLo -= gapH * InpMssExtraBelowGapPct / 100.0;
   if(bias == ICT_BIAS_BULL && InpMssExtraAboveGapPct > 0.0)
      outHi += gapH * InpMssExtraAboveGapPct / 100.0;
}

bool IctMss_PriceNearH1Fvg(const IctFvgZone &h1, const string sym,
                           const double price, const ENUM_ICT_BIAS bias)
{
   if(price <= 0.0 || h1.upper <= h1.lower)
      return false;
   double lo = 0.0, hi = 0.0;
   IctMss_GetH1ProximityBounds(h1, sym, bias, lo, hi);
   return (price >= lo - _Point && price <= hi + _Point);
}

bool IctMss_ChochWithinTouchWindow(const IctFvgZone &h1, const datetime chochTime)
{
   const datetime tTouch = (h1.firstTouchTime > 0) ? h1.firstTouchTime : h1.createdTime;
   if(chochTime > 0 && chochTime < tTouch)
      return false;

   if(InpMssMaxM5BarsAfterTouch > 0 && chochTime > 0)
   {
      const int sec = (int)PeriodSeconds(InpConfirmTf);
      const datetime tMax = tTouch + (datetime)(InpMssMaxM5BarsAfterTouch * sec);
      if(chochTime > tMax)
         return false;
   }
   return true;
}

int IctMss_MaxSwingShift(const IctSwingSet &sw)
{
   int m = 1;
   if(sw.hasH0)
      m = MathMax(m, sw.h0.shift);
   if(sw.hasL0)
      m = MathMax(m, sw.l0.shift);
   if(sw.hasH1)
      m = MathMax(m, sw.h1.shift);
   if(sw.hasL1)
      m = MathMax(m, sw.l1.shift);
   return m + 2;
}

bool IctMss_BodyBrokeLevelSince(const string sym, const ENUM_TIMEFRAMES tf,
                                const int maxShift, const double level,
                                const bool wantBelow)
{
   const int lim = MathMax(1, MathMin(maxShift, InpMssConfirmLookback));
   for(int sh = 1; sh <= lim; sh++)
   {
      if(wantBelow && IctBodyBreakBelow(sym, tf, sh, level))
         return true;
      if(!wantBelow && IctBodyBreakAbove(sym, tf, sh, level))
         return true;
   }
   return false;
}

bool IctMss_HasM5BarInH1Fvg(const string sym, const IctFvgZone &h1,
                            const datetime since)
{
   const ENUM_TIMEFRAMES tf = InpConfirmTf;
   const int lim = MathMin(InpMssConfirmLookback, iBars(sym, tf) - 2);
   for(int sh = 1; sh <= lim; sh++)
   {
      if(since > 0 && iTime(sym, tf, sh) < since)
         break;
      if(IctMss_BarOverlapsFvg(h1, iHigh(sym, tf, sh), iLow(sym, tf, sh)))
         return true;
   }
   return false;
}

bool IctMss_UpdateLiveM5Swings(const string sym, const ENUM_ICT_BIAS bias,
                               const datetime tTouch)
{
   g_ictLowTf.mss.liveL0Price = 0.0;
   g_ictLowTf.mss.liveH0Price = 0.0;
   g_ictLowTf.mss.liveL0Time  = 0;
   g_ictLowTf.mss.liveH0Time  = 0;

   IctSwingSet sw;
   ENUM_ICT_STRUCT st = ICT_STRUCT_NONE;
   if(!IctBuildConfirmSwingSet(sym, sw, st))
      return false;

   if(bias == ICT_BIAS_BEAR)
   {
      if(!sw.hasL0 || !sw.hasH0)
         return false;
      if(sw.l0.time < tTouch && sw.h0.time < tTouch)
         return false;
      g_ictLowTf.mss.liveL0Price = sw.l0.price;
      g_ictLowTf.mss.liveL0Time  = sw.l0.time;
      g_ictLowTf.mss.liveH0Price = sw.h0.price;
      g_ictLowTf.mss.liveH0Time  = sw.h0.time;
      return true;
   }

   if(bias == ICT_BIAS_BULL)
   {
      if(!sw.hasL0 || !sw.hasH0)
         return false;
      if(sw.l0.time < tTouch && sw.h0.time < tTouch)
         return false;
      g_ictLowTf.mss.liveL0Price = sw.l0.price;
      g_ictLowTf.mss.liveL0Time  = sw.l0.time;
      g_ictLowTf.mss.liveH0Price = sw.h0.price;
      g_ictLowTf.mss.liveH0Time  = sw.h0.time;
      return true;
   }

   return false;
}

// Hủy setup: H1 đóng (shift=1) — thân xuyên FVG (không giữ giá). Râu xuyên vẫn tiếp tục MSS.
bool IctMss_H1BodyInvalidatedSetup(const string sym, const IctFvgZone &h1,
                                   const ENUM_ICT_BIAS bias)
{
   if(h1.upper <= h1.lower)
      return false;

   const double cls = iClose(sym, InpFvgTf, 1);
   if(bias == ICT_BIAS_BEAR)
      return (cls > h1.upper + _Point);
   if(bias == ICT_BIAS_BULL)
      return (cls < h1.lower - _Point);
   return false;
}

bool IctMss_CheckH1InvalidationOnNewBar(const string sym, const IctFvgZone &h1,
                                         const ENUM_ICT_BIAS bias)
{
   const datetime h1Bar1 = iTime(sym, InpFvgTf, 1);
   if(h1Bar1 <= 0)
      return false;

   if(h1Bar1 == g_ictLowTf.mss.h1LastInvalidBarTime)
      return false;

   g_ictLowTf.mss.h1LastInvalidBarTime = h1Bar1;
   return IctMss_H1BodyInvalidatedSetup(sym, h1, bias);
}

bool IctMss_FindMssBreakBar(const string sym, const ENUM_TIMEFRAMES tf,
                            const double keyLevel, const datetime keyTime,
                            const bool wantBreakBelow,
                            datetime &breakTimeOut)
{
   breakTimeOut = 0;
   if(keyLevel <= 0.0 || keyTime <= 0)
      return false;

   const int lim = MathMin(InpMssConfirmLookback, iBars(sym, tf) - 2);
   for(int sh = 1; sh <= lim; sh++)
   {
      if(iTime(sym, tf, sh) < keyTime)
         break;
      const bool broke = wantBreakBelow ?
                         IctBodyBreakBelow(sym, tf, sh, keyLevel) :
                         IctBodyBreakAbove(sym, tf, sh, keyLevel);
      if(!broke)
         continue;
      breakTimeOut = iTime(sym, tf, sh);
      return true;
   }
   return false;
}

bool IctMss_TryLockMss(const string sym, const ENUM_TIMEFRAMES tf,
                       const IctFvgZone &h1, const ENUM_ICT_BIAS bias)
{
   if(g_ictLowTf.mss.chochLocked && g_ictLowTf.mss.chochKeyLevel > 0.0)
      return true;

   const datetime tTouch = (g_ictLowTf.mss.h1TouchTime > 0) ?
                           g_ictLowTf.mss.h1TouchTime : h1.firstTouchTime;
   if(tTouch <= 0)
      return false;

   if(!IctMss_UpdateLiveM5Swings(sym, bias, tTouch))
      return false;

   if(g_ictLowTf.mss.liveL0Time < tTouch && g_ictLowTf.mss.liveH0Time < tTouch)
      return false;

   datetime breakT = 0;

   if(bias == ICT_BIAS_BEAR)
   {
      if(!IctMss_FindMssBreakBar(sym, tf, g_ictLowTf.mss.liveL0Price,
                                 g_ictLowTf.mss.liveL0Time, true, breakT))
         return false;
      if(breakT < tTouch)
         return false;

      g_ictLowTf.mss.chochKeyLevel = g_ictLowTf.mss.liveL0Price;
      g_ictLowTf.mss.chochKeyTime  = g_ictLowTf.mss.liveL0Time;
      g_ictLowTf.mss.slSwingPrice  = g_ictLowTf.mss.liveH0Price;
   }
   else if(bias == ICT_BIAS_BULL)
   {
      if(!IctMss_FindMssBreakBar(sym, tf, g_ictLowTf.mss.liveH0Price,
                                 g_ictLowTf.mss.liveH0Time, false, breakT))
         return false;
      if(breakT < tTouch)
         return false;

      g_ictLowTf.mss.chochKeyLevel = g_ictLowTf.mss.liveH0Price;
      g_ictLowTf.mss.chochKeyTime  = g_ictLowTf.mss.liveH0Time;
      g_ictLowTf.mss.slSwingPrice  = g_ictLowTf.mss.liveL0Price;
   }
   else
      return false;

   g_ictLowTf.mss.chochTime   = breakT;
   g_ictLowTf.mss.chochLocked = true;
   return true;
}

bool IctMss_ZonesOverlapH1(const IctFvgZone &h1, const string sym,
                           const ENUM_ICT_BIAS bias,
                           const double zoneLo, const double zoneHi)
{
   if(zoneHi <= zoneLo)
      return false;
   double hLo = 0.0, hHi = 0.0;
   IctMss_GetH1ProximityBounds(h1, sym, bias, hLo, hHi);
   return !(zoneHi < hLo - _Point || zoneLo > hHi + _Point);
}

bool IctMss_IsChochNearH1Fvg(const string sym, const IctFvgZone &h1,
                             const ENUM_ICT_BIAS bias,
                             const double keyLevel, const double anchorPrice,
                             const datetime chochTime)
{
   const bool nearAnchor = (anchorPrice > 0.0 &&
                            IctMss_PriceNearH1Fvg(h1, sym, anchorPrice, bias));
   const bool nearKey    = (keyLevel > 0.0 &&
                            IctMss_PriceNearH1Fvg(h1, sym, keyLevel, bias));

   if(!nearAnchor && !nearKey)
      return false;

   return IctMss_ChochWithinTouchWindow(h1, chochTime);
}

bool IctMss_GetConfirmMssSwing(const string sym, const ENUM_ICT_BIAS bias, double &swingOut)
{
   swingOut = 0.0;

   IctSwingSet sw;
   ENUM_ICT_STRUCT structural = ICT_STRUCT_NONE;
   if(IctBuildConfirmSwingSet(sym, sw, structural))
   {
      if(bias == ICT_BIAS_BEAR && sw.hasH0)
      {
         swingOut = sw.h0.price;
         return true;
      }
      if(bias == ICT_BIAS_BULL && sw.hasL0)
      {
         swingOut = sw.l0.price;
         return true;
      }
   }

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, InpConfirmTf, InpConfirmSwingRange, InpConfirmSwingLookback,
                    highs, lows);
   const int nH = ArraySize(highs);
   const int nL = ArraySize(lows);
   if(bias == ICT_BIAS_BEAR && nH > 0)
   {
      swingOut = highs[nH - 1].price;
      return true;
   }
   if(bias == ICT_BIAS_BULL && nL > 0)
   {
      swingOut = lows[nL - 1].price;
      return true;
   }
   return false;
}

bool IctMss_FindExtremePivot(const IctSwingPoint &pts[], const int n,
                             const int maxShift, const bool wantHighest,
                             IctSwingPoint &out)
{
   out.Clear();
   int best = -1;
   for(int i = 0; i < n; i++)
   {
      if(pts[i].shift > maxShift || pts[i].shift < 3)
         continue;
      if(best < 0)
         best = i;
      else if(wantHighest)
      {
         if(pts[i].price > pts[best].price)
            best = i;
      }
      else
      {
         if(pts[i].price < pts[best].price)
            best = i;
      }
   }
   if(best < 0)
      return false;
   out = pts[best];
   return true;
}

bool IctMss_DetectChoch(const string sym, const ENUM_TIMEFRAMES tf,
                        const ENUM_ICT_BIAS bias,
                        double &keyLevelOut, datetime &keyTimeOut,
                        double &slSwingOut)
{
   keyLevelOut = 0.0;
   keyTimeOut  = 0;
   slSwingOut  = 0.0;

   IctSwingPoint highs[], lows[];
   IctCollectSwings(sym, tf, InpConfirmSwingRange, InpConfirmSwingLookback,
                    highs, lows);
   const int nH = ArraySize(highs);
   const int nL = ArraySize(lows);
   const int maxSh = InpMssConfirmLookback;

   if(bias == ICT_BIAS_BULL)
   {
      IctSwingPoint extremeLo;
      if(!IctMss_FindExtremePivot(lows, nL, maxSh, false, extremeLo))
         return false;

      IctSwingPoint keyHi = IctFindMostRecentOlder(highs, nH, extremeLo.shift);
      if(!keyHi.Valid())
         return false;

      keyLevelOut = keyHi.price;
      keyTimeOut  = keyHi.time;
      slSwingOut  = extremeLo.price;
      return IctBodyBreakAbove(sym, tf, 1, keyLevelOut);
   }

   if(bias == ICT_BIAS_BEAR)
   {
      IctSwingPoint extremeHi;
      if(!IctMss_FindExtremePivot(highs, nH, maxSh, true, extremeHi))
         return false;

      IctSwingPoint keyLo = IctFindMostRecentOlder(lows, nL, extremeHi.shift);
      if(!keyLo.Valid())
         return false;

      keyLevelOut = keyLo.price;
      keyTimeOut  = keyLo.time;
      slSwingOut  = extremeHi.price;
      return IctBodyBreakBelow(sym, tf, 1, keyLevelOut);
   }

   return false;
}

bool IctMss_PriceInEntryZone(const string sym, const ENUM_TIMEFRAMES tf,
                             const IctFvgZone &zone)
{
   if(!IctFvg_HasFillAtLeast(zone, InpMssEntryFillPct))
      return false;

   const double fillPx = IctFvg_PriceAtFillPct(zone, InpMssEntryFillPct);
   const double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   const double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   const double mid    = (bid + ask) * 0.5;

   if(zone.side == ICT_FVG_BULL)
      return (mid <= fillPx + _Point && mid >= zone.lower - _Point);
   if(zone.side == ICT_FVG_BEAR)
      return (mid >= fillPx - _Point && mid <= zone.upper + _Point);
   return false;
}

void IctMss_MarkFvgUsed(IctFvgZone &zone, const string sym)
{
   if(zone.id == 0)
      return;

   zone.state = ICT_FVG_USED;
   if(zone.fvgUsedTime == 0)
      zone.fvgUsedTime = iTime(sym, InpFvgTf, 0);
   zone.timeEnd = IctFvg_GetFvgDrawTimeEnd(sym, InpFvgTf, zone);
}

void IctMss_MarkFvgUsedOnMssSuccess(const string sym, const ulong fvgId)
{
   if(fvgId == 0)
      return;

   const int idx = IctMss_FindH1FvgById(fvgId);
   if(idx < 0)
      return;

   const bool fresh = (g_ictFvgZones[idx].state != ICT_FVG_USED);
   if(fresh)
      IctMss_MarkFvgUsed(g_ictFvgZones[idx], sym);

   if(g_ictLowTf.mss.h1WatchFvgId == fvgId)
      g_ictLowTf.mss.h1WatchFvgId = 0;

   if(fresh && InpMssLogJournal)
      PrintFormat("[ICT2026/MSS] FVG #%I64u → Used (giữ giá + MSS M5 OK)", fvgId);
}

void IctMss_FailFvgH1Body(const string sym, const ulong fvgId, const string reason)
{
   if(fvgId > 0)
   {
      const int idx = IctMss_FindH1FvgById(fvgId);
      if(idx >= 0)
         IctMss_MarkFvgUsed(g_ictFvgZones[idx], sym);
   }

   IctMss_ResetState();
   g_ictLowTf.mss.displayReason = reason;

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/MSS] FVG #%I64u → Used (H1 body xuyên) | %s", fvgId, reason);
   g_ictMssJournalLast = "";
}

void IctMss_ResetPipelineKeepWatch()
{
   const ulong watch  = g_ictLowTf.mss.h1WatchFvgId;
   const datetime inv = g_ictLowTf.mss.h1LastInvalidBarTime;
   g_ictLowTf.mss.Clear();
   g_ictLowTf.mss.h1WatchFvgId         = watch;
   g_ictLowTf.mss.h1LastInvalidBarTime = inv;
   IctMss_JournalReset();
}

void IctMss_CheckH1WatchInvalidation(const string sym)
{
   const ulong watchId = g_ictLowTf.mss.h1WatchFvgId;
   if(watchId == 0)
      return;

   const int idx = IctMss_FindH1FvgById(watchId);
   if(idx < 0)
   {
      g_ictLowTf.mss.h1WatchFvgId = 0;
      return;
   }

   if(g_ictFvgZones[idx].state == ICT_FVG_USED)
   {
      g_ictLowTf.mss.h1WatchFvgId = 0;
      return;
   }

   const ENUM_ICT_BIAS bias = g_ictDailyBias.bias;
   if(bias != ICT_BIAS_BEAR && bias != ICT_BIAS_BULL)
      return;

   if(!IctMss_CheckH1InvalidationOnNewBar(sym, g_ictFvgZones[idx], bias))
      return;

   IctMss_FailFvgH1Body(sym, watchId,
      (bias == ICT_BIAS_BEAR) ?
      "FVG Used: H1 đóng thân trên Premium — không giữ giá" :
      "FVG Used: H1 đóng thân dưới Discount — không giữ giá");
}

void IctMss_ResetState()
{
   g_ictLowTf.mss.Clear();
   IctMss_JournalReset();
}

void IctMss_Update(const string sym)
{
   g_ictLowTf.mss.displayReason = IctMssPhaseText(g_ictLowTf.mss.phase);

   IctMss_CheckH1WatchInvalidation(sym);

   if(!g_ictIntraday.isAllowTrade)
   {
      if(g_ictLowTf.mss.phase != ICT_MSS_IDLE)
      {
         if(g_ictLowTf.mss.h1WatchFvgId == 0 && g_ictLowTf.mss.h1FvgId > 0)
            g_ictLowTf.mss.h1WatchFvgId = g_ictLowTf.mss.h1FvgId;
         IctMss_ResetPipelineKeepWatch();
      }
      if(StringFind(g_ictLowTf.mss.displayReason, "FVG Used") != 0)
         g_ictLowTf.mss.displayReason = "AllowTrade=false (H1 lệch Bias — MSS tạm dừng)";
      return;
   }

   const ENUM_TIMEFRAMES cTf = InpConfirmTf;
   const ENUM_ICT_FVG_SIDE wantSide = IctFvgSideFromBias(g_ictDailyBias.bias);
   if(wantSide == ICT_FVG_NONE)
   {
      IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "Bias none";
      return;
   }

   if(g_ictLowTf.mss.phase == ICT_MSS_IDLE)
   {
      const int hIdx = IctMss_SelectNearestH1Poi(sym);
      if(hIdx < 0)
      {
         g_ictLowTf.mss.h1FvgId = 0;
         g_ictLowTf.mss.displayReason = StringFormat(
            "Chờ H1 %s FVG gần giá (%d POI / %d FVG)",
            (wantSide == ICT_FVG_BEAR) ? "Premium" : "Discount",
            IctMss_CountH1PoiEligible(), g_ictFvgCount);
         return;
      }

      g_ictLowTf.mss.h1FvgId = g_ictFvgZones[hIdx].id;

      if(!IctMss_HasFvgPriceTouch(sym, g_ictFvgZones[hIdx]))
      {
         const double px = SymbolInfoDouble(sym, SYMBOL_BID);
         const double dist = IctMss_DistancePriceToFvg(px, g_ictFvgZones[hIdx]);
         g_ictLowTf.mss.displayReason = StringFormat(
            "POI #%I64u [%.0f–%.0f] dist %.0f pts — chờ chạm",
            g_ictFvgZones[hIdx].id,
            g_ictFvgZones[hIdx].lower, g_ictFvgZones[hIdx].upper, dist / _Point);
         return;
      }

      const datetime tTouch = IctMss_GetFvgTouchTime(sym, g_ictFvgZones[hIdx]);
      g_ictLowTf.mss.phase       = ICT_MSS_H1_TOUCH;
      g_ictLowTf.mss.h1FvgId     = g_ictFvgZones[hIdx].id;
      g_ictLowTf.mss.h1WatchFvgId = g_ictFvgZones[hIdx].id;
      g_ictLowTf.mss.h1TouchTime = tTouch;
      g_ictLowTf.mss.h1LastInvalidBarTime = 0;
      g_ictLowTf.mss.displayReason = StringFormat(
         "Giá đã chạm FVG — theo dõi MSS M5 [%.0f–%.0f]",
         g_ictFvgZones[hIdx].lower, g_ictFvgZones[hIdx].upper);
   }

   const int h1Idx = IctMss_FindH1FvgById(g_ictLowTf.mss.h1FvgId);
   if(h1Idx < 0)
   {
      IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "H1 FVG mất";
      return;
   }

   if(g_ictFvgZones[h1Idx].state == ICT_FVG_USED &&
      g_ictLowTf.mss.phase <= ICT_MSS_H1_TOUCH &&
      !g_ictLowTf.mss.chochLocked)
   {
      IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "FVG POI Used — chọn FVG gần giá tiếp theo";
      return;
   }

   if(g_ictLowTf.mss.phase >= ICT_MSS_H1_TOUCH && g_ictLowTf.mss.h1TouchTime <= 0)
   {
      const datetime t = IctMss_GetFvgTouchTime(sym, g_ictFvgZones[h1Idx]);
      if(t > 0)
         g_ictLowTf.mss.h1TouchTime = t;
   }

   if(g_ictLowTf.mss.phase == ICT_MSS_H1_TOUCH && !g_ictLowTf.mss.chochLocked)
   {
      const datetime tTouch = g_ictLowTf.mss.h1TouchTime;
      if(IctMss_UpdateLiveM5Swings(sym, g_ictDailyBias.bias, tTouch))
      {
         if(g_ictDailyBias.bias == ICT_BIAS_BEAR)
            g_ictLowTf.mss.displayReason = StringFormat(
               "Chờ MSS↓ phá L0=%.2f | H0=%.2f (M5 bull)",
               g_ictLowTf.mss.liveL0Price, g_ictLowTf.mss.liveH0Price);
         else
            g_ictLowTf.mss.displayReason = StringFormat(
               "Chờ MSS↑ phá H0=%.2f | L0=%.2f (M5 bear)",
               g_ictLowTf.mss.liveH0Price, g_ictLowTf.mss.liveL0Price);
      }
      else
         g_ictLowTf.mss.displayReason = "M5 trong FVG — chờ pivot L0/H0";

      if(!IctMss_TryLockMss(sym, cTf, g_ictFvgZones[h1Idx], g_ictDailyBias.bias))
         return;

      IctMss_MarkFvgUsedOnMssSuccess(sym, g_ictLowTf.mss.h1FvgId);

      const double keyLv   = g_ictLowTf.mss.chochKeyLevel;
      const double slSwing = g_ictLowTf.mss.slSwingPrice;

      g_ictLowTf.mss.phase = ICT_MSS_CHOCH;
      IctConfirmFvg_ScanNew(sym, cTf, wantSide, g_ictLowTf.mss.chochTime, true);
      g_ictLowTf.mss.displayReason = (g_ictDailyBias.bias == ICT_BIAS_BEAR) ?
         StringFormat("MSS↓ @ L0=%.2f | SL H0=%.2f — quét M5 FVG", keyLv, slSwing) :
         StringFormat("MSS↑ @ H0=%.2f | SL L0=%.2f — quét M5 FVG", keyLv, slSwing);
   }

   if(g_ictLowTf.mss.phase == ICT_MSS_CHOCH)
   {
      IctConfirmFvg_ScanNew(sym, cTf, wantSide, g_ictLowTf.mss.chochTime, false);

      const int mIdx = IctConfirmFvg_FindLatestAfter(g_ictLowTf.mss.chochTime, wantSide);
      if(mIdx < 0)
      {
         g_ictLowTf.mss.displayReason = "MSS OK — chờ M5 FVG";
         return;
      }

      if(!IctMss_ZonesOverlapH1(g_ictFvgZones[h1Idx], sym, g_ictDailyBias.bias,
                                g_ictConfirmFvgZones[mIdx].lower,
                                g_ictConfirmFvgZones[mIdx].upper))
      {
         g_ictLowTf.mss.displayReason = "M5 FVG xa H1 FVG — chờ FVG gần hơn";
         return;
      }

      g_ictLowTf.mss.phase     = ICT_MSS_M5_FVG;
      g_ictLowTf.mss.m5FvgId   = g_ictConfirmFvgZones[mIdx].id;
      g_ictLowTf.mss.m5FvgTime = g_ictConfirmFvgZones[mIdx].createdTime;
      g_ictLowTf.mss.displayReason = StringFormat("M5 FVG #%I64u [%.2f–%.2f]",
                                      g_ictLowTf.mss.m5FvgId,
                                      g_ictConfirmFvgZones[mIdx].lower,
                                      g_ictConfirmFvgZones[mIdx].upper);
   }

   if(g_ictLowTf.mss.phase >= ICT_MSS_M5_FVG && g_ictLowTf.mss.m5FvgId > 0)
   {
      const int mIdx = IctConfirmFvg_FindById(g_ictLowTf.mss.m5FvgId);
      if(mIdx < 0)
      {
         g_ictLowTf.mss.phase = ICT_MSS_CHOCH;
         g_ictLowTf.mss.m5FvgId = 0;
         g_ictLowTf.mss.displayReason = "M5 FVG mất — quét lại";
         return;
      }

      IctFvg_UpdateZoneState(sym, cTf, g_ictConfirmFvgZones[mIdx]);

      if(IctMss_PriceInEntryZone(sym, cTf, g_ictConfirmFvgZones[mIdx]))
      {
         g_ictLowTf.mss.phase = ICT_MSS_READY;
         g_ictLowTf.mss.displayReason = StringFormat("READY | M5 fill %.0f%% | %s %s",
                                         g_ictConfirmFvgZones[mIdx].maxFillRatio * 100.0,
                                         IctFvgSideText(wantSide),
                                         IctPdZoneText(IctFvg_GetRepPd(g_ictFvgZones[h1Idx])));
      }
      else if(IctFvg_HasFillAtLeast(g_ictConfirmFvgZones[mIdx], InpMssEntryFillPct))
      {
         g_ictLowTf.mss.phase = ICT_MSS_ENTRY_FILL;
         g_ictLowTf.mss.displayReason = StringFormat("M5 chạm %.0f%% — canh entry",
                                       InpMssEntryFillPct);
      }
      else
      {
         g_ictLowTf.mss.phase = ICT_MSS_M5_FVG;
         g_ictLowTf.mss.displayReason = StringFormat("Chờ hồi M5 FVG %.0f%% (fill %.0f%%)",
                                         InpMssEntryFillPct,
                                         g_ictConfirmFvgZones[mIdx].maxFillRatio * 100.0);
      }
   }

   IctMss_JournalPipeline(g_ictLowTf.mss.displayReason);
}

#endif
