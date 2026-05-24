//+------------------------------------------------------------------+
//| MssSetup.mqh — MSS: retest FVG H1 (POI) → CHoCH M5 → M5 FVG → entry |
//+------------------------------------------------------------------+
#ifndef ICT2026_MSSSETUP_MQH
#define ICT2026_MSSSETUP_MQH

#include <ICT2026/ConfirmFvg.mqh>
#include <ICT2026/Journal.mqh>
#include <ICT2026/LowTfApi.mqh>

string IctMssPhaseText(const ENUM_ICT_MSS_PHASE ph)
{
   switch(ph)
   {
      case ICT_MSS_H1_TOUCH:    return "Retest FVG H1 OK";
      case ICT_MSS_CHOCH:       return "CHoCH OK";
      case ICT_MSS_M5_FVG:      return "M5 FVG";
      case ICT_MSS_ENTRY_FILL:  return "M5 fill 38.2%";
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

// H1 FVG mục tiêu: Bear → Premium cao nhất; Bull → Discount thấp nhất (chờ hồi chạm, chưa cần fill)
int IctMss_SelectTargetH1Fvg()
{
   int    bestIdx = -1;

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(!IctFvg_MatchesBias(g_ictFvgZones[i]))
         continue;
      if(!IctFvg_IsEntryRepPd(g_ictFvgZones[i]))
         continue;
      if(g_ictFvgZones[i].state == ICT_FVG_USED && g_ictFvgZones[i].maxFillRatio < 0.01)
         continue;

      if(g_ictDailyBias.bias == ICT_BIAS_BEAR)
      {
         if(bestIdx < 0 || g_ictFvgZones[i].upper > g_ictFvgZones[bestIdx].upper)
            bestIdx = i;
      }
      else if(g_ictDailyBias.bias == ICT_BIAS_BULL)
      {
         if(bestIdx < 0 || g_ictFvgZones[i].lower < g_ictFvgZones[bestIdx].lower)
            bestIdx = i;
      }
   }
   return bestIdx;
}

// Retest FVG H1 (POI): giá chạm gap H1 + lấp ≥ InpMssH1MinFillPct (đo trên InpFvgTf, không phải M5)
bool IctMss_HasH1FvgRetest(const string sym, IctFvgZone &h1)
{
   IctFvg_UpdateZoneState(sym, InpFvgTf, h1);
   if(h1.firstTouchTime <= 0)
      return false;
   if(!IctFvg_HasFillAtLeast(h1, InpMssH1MinFillPct))
      return false;
   h1.mssH1Touch382 = true;
   return true;
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

// MSS confirm: cùng swing set M5 như chart (H0/H1/L0/L1) + body phá swing thuận bias
bool IctMss_DetectChochFromM5Swings(const string sym, const ENUM_TIMEFRAMES tf,
                                    const datetime tTouch, const ENUM_ICT_BIAS bias,
                                    double &keyLevelOut, datetime &keyTimeOut,
                                    double &slSwingOut)
{
   keyLevelOut = 0.0;
   keyTimeOut  = 0;
   slSwingOut  = 0.0;

   IctSwingSet sw;
   ENUM_ICT_STRUCT structural = ICT_STRUCT_NONE;
   if(!IctBuildConfirmSwingSet(sym, sw, structural))
      return false;

   const int maxSh = IctMss_MaxSwingShift(sw);

   if(bias == ICT_BIAS_BEAR)
   {
      if(sw.hasH0 && sw.hasL0 && sw.h0.time >= tTouch && sw.l0.time >= sw.h0.time)
      {
         if(IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.l0.price, true))
         {
            keyLevelOut = sw.l0.price;
            keyTimeOut  = sw.l0.time;
            slSwingOut  = sw.h0.price;
            return true;
         }
      }

      if(sw.IsComplete() && structural == ICT_STRUCT_BULL && sw.l1.time >= tTouch)
      {
         const ENUM_ICT_MS_EVENT ev =
            IctDetectStructureEvent(sym, tf, structural, sw.h1.price, sw.l1.price, 1);
         if(ev == ICT_MS_CHOCH ||
            IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.l1.price, true))
         {
            keyLevelOut = sw.l1.price;
            keyTimeOut  = sw.l1.time;
            slSwingOut  = sw.hasH0 ? sw.h0.price : sw.h1.price;
            return true;
         }
      }

      if(sw.IsComplete() && structural == ICT_STRUCT_BEAR && sw.l1.time >= tTouch)
      {
         if(IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.l1.price, true))
         {
            keyLevelOut = sw.l1.price;
            keyTimeOut  = sw.l1.time;
            slSwingOut  = sw.hasH0 ? sw.h0.price : sw.h1.price;
            return true;
         }
      }
   }

   if(bias == ICT_BIAS_BULL)
   {
      if(sw.hasL0 && sw.hasH0 && sw.l0.time >= tTouch && sw.h0.time >= sw.l0.time)
      {
         if(IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.h0.price, false))
         {
            keyLevelOut = sw.h0.price;
            keyTimeOut  = sw.h0.time;
            slSwingOut  = sw.l0.price;
            return true;
         }
      }

      if(sw.IsComplete() && structural == ICT_STRUCT_BEAR && sw.h1.time >= tTouch)
      {
         const ENUM_ICT_MS_EVENT ev =
            IctDetectStructureEvent(sym, tf, structural, sw.h1.price, sw.l1.price, 1);
         if(ev == ICT_MS_CHOCH ||
            IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.h1.price, false))
         {
            keyLevelOut = sw.h1.price;
            keyTimeOut  = sw.h1.time;
            slSwingOut  = sw.hasL0 ? sw.l0.price : sw.l1.price;
            return true;
         }
      }

      if(sw.IsComplete() && structural == ICT_STRUCT_BULL && sw.h1.time >= tTouch)
      {
         if(IctMss_BodyBrokeLevelSince(sym, tf, maxSh, sw.h1.price, false))
         {
            keyLevelOut = sw.h1.price;
            keyTimeOut  = sw.h1.time;
            slSwingOut  = sw.hasL0 ? sw.l0.price : sw.l1.price;
            return true;
         }
      }
   }

   return false;
}

// Sau retest FVG H1: MSS = phá swing M5 (confirm TF)
bool IctMss_DetectChochAfterH1FvgRetest(const string sym, const ENUM_TIMEFRAMES tf,
                                    const IctFvgZone &h1, const ENUM_ICT_BIAS bias,
                                    double &keyLevelOut, datetime &keyTimeOut,
                                    double &slSwingOut)
{
   const datetime tTouch = h1.firstTouchTime;
   if(tTouch <= 0)
      return false;

   return IctMss_DetectChochFromM5Swings(sym, tf, tTouch, bias,
                                         keyLevelOut, keyTimeOut, slSwingOut);
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

void IctMss_ResetState()
{
   g_ictLowTf.mss.Clear();
   IctMss_JournalReset();
}

void IctMss_Update(const string sym)
{
   g_ictLowTf.mss.displayReason = IctMssPhaseText(g_ictLowTf.mss.phase);

   if(!g_ictIntraday.isAllowTrade)
   {
      if(g_ictLowTf.mss.phase != ICT_MSS_IDLE)
         IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "AllowTrade=false";
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

   if(g_ictLowTf.mss.phase == ICT_MSS_IDLE || g_ictLowTf.mss.h1FvgId == 0)
   {
      const int hIdx = IctMss_SelectTargetH1Fvg();
      if(hIdx < 0)
      {
         g_ictLowTf.mss.displayReason = StringFormat("Chờ H1 %s FVG",
                                         (wantSide == ICT_FVG_BEAR) ? "Premium" : "Discount");
         return;
      }

      g_ictLowTf.mss.h1FvgId = g_ictFvgZones[hIdx].id;

      if(!IctMss_HasH1FvgRetest(sym, g_ictFvgZones[hIdx]))
      {
         g_ictLowTf.mss.displayReason = StringFormat(
            "Chờ retest FVG H1 %s [%.0f–%.0f] (%.0f%% lấp trên H1)",
            IctPdZoneText(IctFvg_GetRepPd(g_ictFvgZones[hIdx])),
            g_ictFvgZones[hIdx].lower, g_ictFvgZones[hIdx].upper,
            InpMssH1MinFillPct);
         return;
      }

      g_ictLowTf.mss.phase       = ICT_MSS_H1_TOUCH;
      g_ictLowTf.mss.h1TouchTime = g_ictFvgZones[hIdx].firstTouchTime;
      g_ictLowTf.mss.displayReason = StringFormat("Retest FVG H1 OK | lấp %.0f%% (H1)",
                                      g_ictFvgZones[hIdx].maxFillRatio * 100.0);
   }

   const int h1Idx = IctMss_FindH1FvgById(g_ictLowTf.mss.h1FvgId);
   if(h1Idx < 0)
   {
      IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "H1 FVG mất";
      return;
   }

   if(g_ictLowTf.mss.phase >= ICT_MSS_H1_TOUCH &&
      !IctMss_HasH1FvgRetest(sym, g_ictFvgZones[h1Idx]))
   {
      IctMss_ResetState();
      g_ictLowTf.mss.displayReason = "FVG H1 chưa retest đủ % — reset MSS";
      return;
   }

   if(g_ictLowTf.mss.phase >= ICT_MSS_H1_TOUCH && g_ictLowTf.mss.h1TouchTime <= 0)
      g_ictLowTf.mss.h1TouchTime = g_ictFvgZones[h1Idx].firstTouchTime;

   if(g_ictLowTf.mss.phase == ICT_MSS_H1_TOUCH)
   {
      double keyLv = 0.0;
      datetime keyT = 0;
      double slSwing = 0.0;
      if(!IctMss_DetectChochAfterH1FvgRetest(sym, cTf, g_ictFvgZones[h1Idx],
                                            g_ictDailyBias.bias, keyLv, keyT, slSwing))
      {
         g_ictLowTf.mss.displayReason = (g_ictDailyBias.bias == ICT_BIAS_BEAR) ?
                                        "Retest FVG H1 OK — chờ MSS↓ phá L0 M5" :
                                        "Retest FVG H1 OK — chờ MSS↑ phá H0 M5";
         return;
      }

      g_ictLowTf.mss.chochKeyLevel = keyLv;
      g_ictLowTf.mss.chochKeyTime  = keyT;
      g_ictLowTf.mss.slSwingPrice  = slSwing;

      datetime chochT = iTime(sym, cTf, 1);
      if(chochT == 0)
         chochT = keyT;

      if(!IctMss_IsChochNearH1Fvg(sym, g_ictFvgZones[h1Idx], g_ictDailyBias.bias,
                                  keyLv, slSwing, chochT))
      {
         g_ictLowTf.mss.displayReason = "CHoCH xa vùng gần H1 FVG — chờ MSS gần hơn";
         return;
      }

      g_ictLowTf.mss.phase         = ICT_MSS_CHOCH;
      g_ictLowTf.mss.chochKeyLevel = keyLv;
      g_ictLowTf.mss.chochKeyTime  = keyT;
      g_ictLowTf.mss.slSwingPrice  = slSwing;
      double mssH0 = 0.0;
      if(IctMss_GetConfirmMssSwing(sym, g_ictDailyBias.bias, mssH0))
         g_ictLowTf.mss.slSwingPrice = mssH0;
      g_ictLowTf.mss.chochTime     = chochT;

      IctConfirmFvg_ScanNew(sym, cTf, wantSide, g_ictLowTf.mss.chochTime, true);
      g_ictLowTf.mss.displayReason = StringFormat("CHoCH @ %.2f — quét M5 FVG", keyLv);
   }

   if(g_ictLowTf.mss.phase == ICT_MSS_CHOCH)
   {
      IctConfirmFvg_ScanNew(sym, cTf, wantSide, g_ictLowTf.mss.chochTime, false);

      const int mIdx = IctConfirmFvg_FindLatestAfter(g_ictLowTf.mss.chochTime, wantSide);
      if(mIdx < 0)
      {
         g_ictLowTf.mss.displayReason = "CHoCH OK — chờ M5 FVG";
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
