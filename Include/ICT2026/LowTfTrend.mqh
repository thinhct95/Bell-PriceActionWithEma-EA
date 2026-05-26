//+------------------------------------------------------------------+
//| LowTfTrend.mqh — Low TF layer: iTF FVG khi IsAllowTrade            |
//+------------------------------------------------------------------+
#ifndef ICT2026_LOWTFTREND_MQH
#define ICT2026_LOWTFTREND_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Fvg.mqh>
#include <ICT2026/LowTfApi.mqh>
#include <ICT2026/MssSetup.mqh>
#include <ICT2026/MssEntry.mqh>
#include <ICT2026/FvgDraw.mqh>
#include <ICT2026/MssDraw.mqh>
#include <ICT2026/EaState.mqh>

void IctLowTfTrend_Reset()
{
   g_ictLowTf.lastBarTime         = 0;
   g_ictLowTf.lastConfirmBarTime  = 0;
   g_ictLowTf.activeCount         = 0;
   g_ictLowTf.availableCount      = 0;
   g_ictLowTf.confirmFvgCount     = 0;
   g_ictLowTf.displayReason       = "";
   g_ictLowTf.mss.Clear();
   IctFvg_Reset();
   IctConfirmFvg_Reset();
}

bool IctLowTfTrend_Init(const string sym)
{
   IctLowTfTrend_Reset();
   IctMssEntry_Init();
   if(Bars(sym, InpFvgTf) < 10)
      return false;
   IctLowTfTrend_Update(sym, true);
   return true;
}

bool IctLowTfTrend_Update(const string sym, const bool force = false)
{
   const ENUM_TIMEFRAMES tf = InpFvgTf;
   const datetime bar0 = iTime(sym, tf, 0);
   const bool newBar = (force || bar0 != g_ictLowTf.lastBarTime);
   if(!newBar)
      return false;

   g_ictLowTf.lastBarTime = bar0;

   IctIntraday_UpdateAllowTrade();
   IctFvg_UpdateAll(sym, tf);

   // Pipeline gate = Bias rõ ràng (không gate theo Intraday trend).
   //   → POI scan + MSS pipeline chạy liên tục trong giai đoạn intraday transition
   //   → Entry vẫn bị chặn bởi isAllowTrade trong IctMssEntry_Update
   static bool s_prevBiasOk = false;
   const bool biasOk = (g_ictDailyBias.bias != ICT_BIAS_NONE);
   const bool biasJustOn = (biasOk && !s_prevBiasOk);
   s_prevBiasOk = biasOk;

   if(biasOk)
   {
      const ENUM_ICT_FVG_SIDE side = IctFvgSideFromBias(g_ictDailyBias.bias);
      IctFvg_ScanNew(sym, tf, side, force || biasJustOn);
      const string allowTag = g_ictIntraday.isAllowTrade ? "" : " | AllowEntry=NO";
      g_ictLowTf.displayReason = StringFormat("H1 POI %d avail / %d FVG | scan %s%s",
                                              IctMss_CountH1PoiEligible(), g_ictFvgCount,
                                              IctFvgSideText(side), allowTag);
   }
   else
   {
      g_ictLowTf.displayReason = "Bias none — giữ FVG đã khóa";
   }

   g_ictLowTf.activeCount    = g_ictFvgCount;
   g_ictLowTf.availableCount = IctFvg_CountAvailable();

   const datetime cBar0 = iTime(sym, InpConfirmTf, 0);
   const bool confirmNewBar = (force || cBar0 != g_ictLowTf.lastConfirmBarTime);
   if(confirmNewBar)
   {
      g_ictLowTf.lastConfirmBarTime = cBar0;
      IctConfirmFvg_UpdateAll(sym, InpConfirmTf);
      IctMss_Update(sym);
      IctMssEntry_Update(sym);
      IctEaState_Refresh(sym);
      g_ictLowTf.confirmFvgCount = g_ictConfirmFvgCount;
   }

   if(InpDebug && (force || g_ictIntraday.isAllowTrade))
      PrintFormat("[ICT2026/LowTF] %s | Allow=%s | FVG avail=%d total=%d | %s",
                  sym,
                  g_ictIntraday.isAllowTrade ? "YES" : "NO",
                  g_ictLowTf.availableCount, g_ictLowTf.activeCount,
                  g_ictLowTf.displayReason);

   IctFvgDraw_Render(sym);
   IctMssDraw_Render(sym);
   return true;
}

void IctLowTfTrend_TickRefresh(const string sym)
{
   if(!InpDrawFvgZones || g_ictFvgCount == 0)
      return;

   bool dirty = false;
   double oldPdHi[], oldPdLo[];
   ArrayResize(oldPdHi, g_ictFvgCount);
   ArrayResize(oldPdLo, g_ictFvgCount);

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      oldPdHi[i] = g_ictFvgZones[i].pdHigh;
      oldPdLo[i] = g_ictFvgZones[i].pdLow;

      const datetime oldTouch = g_ictFvgZones[i].firstTouchTime;
      const datetime oldEnd   = g_ictFvgZones[i].timeEnd;
      IctFvg_UpdateZoneState(sym, InpFvgTf, g_ictFvgZones[i]);
      if(g_ictFvgZones[i].firstTouchTime != oldTouch || g_ictFvgZones[i].timeEnd != oldEnd)
         dirty = true;
   }

   IctFvg_UpdateAllPd(sym);

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(MathAbs(g_ictFvgZones[i].pdHigh - oldPdHi[i]) > _Point ||
         MathAbs(g_ictFvgZones[i].pdLow - oldPdLo[i]) > _Point)
         dirty = true;
   }
   if(g_ictDailyBias.bias != ICT_BIAS_NONE)
   {
      const ENUM_ICT_MSS_PHASE prevMss = g_ictLowTf.mss.phase;
      IctMss_Update(sym);
      IctMssEntry_Update(sym);
      IctEaState_Refresh(sym);
      if(prevMss != g_ictLowTf.mss.phase)
         dirty = true;
   }
   else if(g_ictLowTf.mss.pendingTicket > 0)
   {
      IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
      g_ictLowTf.mss.pendingTicket = 0;
   }

   if(dirty)
      IctFvgDraw_Render(sym);

   if(g_ictLowTf.mss.phase >= ICT_MSS_H1_TOUCH)
      IctMssDraw_Render(sym);
   else if(!InpDrawMssChoch)
      IctMssDraw_DeleteAll();
}

void IctLowTfTrend_Get(IctLowTfState &out) { out = g_ictLowTf; }

#endif
