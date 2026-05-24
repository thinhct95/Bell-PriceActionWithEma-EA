//+------------------------------------------------------------------+
//| StructureTrend.mqh — trend rõ (HH-HL/LH-LL) vs sớm (sau CHoCH)   |
//+------------------------------------------------------------------+
#ifndef ICT2026_STRUCTURETREND_MQH
#define ICT2026_STRUCTURETREND_MQH

#include <ICT2026/Types.mqh>
#include <ICT2026/Swing.mqh>
#include <ICT2026/StructureCore.mqh>

struct IctTrendResolveCtx
{
   ENUM_ICT_TREND        trend;
   ENUM_ICT_TREND_PHASE  phase;
   ENUM_ICT_STRUCT       lastClearStructural;
   ENUM_ICT_MS_EVENT     lastEvent;

   void Reset()
   {
      trend               = ICT_TREND_NONE;
      phase               = ICT_TREND_PHASE_NONE;
      lastClearStructural = ICT_STRUCT_NONE;
      lastEvent           = ICT_MS_NONE;
   }
};

ENUM_ICT_STRUCT IctPickDetectStructural(const ENUM_ICT_STRUCT pivotStruct,
                                        const IctTrendResolveCtx &ctx)
{
   if(pivotStruct != ICT_STRUCT_NONE)
      return pivotStruct;
   if(ctx.phase == ICT_TREND_PHASE_EARLY)
   {
      if(ctx.trend == ICT_TREND_UP)
         return ICT_STRUCT_BULL;
      if(ctx.trend == ICT_TREND_DOWN)
         return ICT_STRUCT_BEAR;
   }
   return ctx.lastClearStructural;
}

void IctResolveTrend(const string sym, const ENUM_TIMEFRAMES tf,
                     IctSwingSet &sw,
                     const ENUM_ICT_STRUCT pivotStruct,
                     IctTrendResolveCtx &ctx,
                     const int shift = 1)
{
   ctx.lastEvent = ICT_MS_NONE;

   if(!sw.IsComplete())
   {
      if(ctx.phase == ICT_TREND_PHASE_EARLY && ctx.trend != ICT_TREND_NONE)
         return;
      ctx.trend = ICT_TREND_NONE;
      ctx.phase = ICT_TREND_PHASE_NONE;
      return;
   }

   const ENUM_ICT_STRUCT detectStruct = IctPickDetectStructural(pivotStruct, ctx);
   ENUM_ICT_MS_EVENT ev = ICT_MS_NONE;
   if(detectStruct != ICT_STRUCT_NONE)
   {
      double k1 = 0.0, k2 = 0.0;
      IctGetKeyLevels(detectStruct, sw, k1, k2);
      ev = IctDetectStructureEvent(sym, tf, detectStruct, k1, k2, shift);
   }
   ctx.lastEvent = ev;

   // CHoCH ưu tiên trước HH-HL/LH-LL — pivot vẫn LH-LL nhưng phá H0 → Bull sớm
   if(ev == ICT_MS_CHOCH)
   {
      if(detectStruct == ICT_STRUCT_BEAR)
      {
         ctx.trend               = ICT_TREND_UP;
         ctx.phase               = ICT_TREND_PHASE_EARLY;
         ctx.lastClearStructural = ICT_STRUCT_NONE;
         return;
      }
      if(detectStruct == ICT_STRUCT_BULL)
      {
         ctx.trend               = ICT_TREND_DOWN;
         ctx.phase               = ICT_TREND_PHASE_EARLY;
         ctx.lastClearStructural = ICT_STRUCT_NONE;
         return;
      }
   }

   if(pivotStruct == ICT_STRUCT_BULL)
   {
      ctx.trend               = ICT_TREND_UP;
      ctx.phase               = ICT_TREND_PHASE_CLEAR;
      ctx.lastClearStructural = ICT_STRUCT_BULL;
      return;
   }
   if(pivotStruct == ICT_STRUCT_BEAR)
   {
      ctx.trend               = ICT_TREND_DOWN;
      ctx.phase               = ICT_TREND_PHASE_CLEAR;
      ctx.lastClearStructural = ICT_STRUCT_BEAR;
      return;
   }

   if(ev == ICT_MS_BOS)
   {
      if(detectStruct == ICT_STRUCT_BEAR)
      {
         ctx.trend = ICT_TREND_DOWN;
         ctx.phase = ICT_TREND_PHASE_EARLY;
         return;
      }
      if(detectStruct == ICT_STRUCT_BULL)
      {
         ctx.trend = ICT_TREND_UP;
         ctx.phase = ICT_TREND_PHASE_EARLY;
         return;
      }
   }

   if(ctx.phase == ICT_TREND_PHASE_EARLY && ctx.trend != ICT_TREND_NONE)
      return;

   ctx.trend = ICT_TREND_NONE;
   ctx.phase = ICT_TREND_PHASE_NONE;
}

string IctTrendPhaseDisplay(const ENUM_ICT_TREND trend, const ENUM_ICT_TREND_PHASE phase)
{
   if(trend == ICT_TREND_UP)
      return (phase == ICT_TREND_PHASE_EARLY) ? "Bull sớm" : "Up";
   if(trend == ICT_TREND_DOWN)
      return (phase == ICT_TREND_PHASE_EARLY) ? "Bear sớm" : "Down";
   return "None";
}

string IctStructPatternText(const ENUM_ICT_STRUCT structural)
{
   switch(structural)
   {
      case ICT_STRUCT_BULL: return "HH-HL";
      case ICT_STRUCT_BEAR: return "LH-LL";
      default:              return "";
   }
}

string IctBuildTrendDisplayReason(const IctSwingSet &sw,
                                  const ENUM_ICT_STRUCT pivotStruct,
                                  const ENUM_ICT_TREND trend,
                                  const ENUM_ICT_TREND_PHASE phase,
                                  const ENUM_ICT_MS_EVENT ev,
                                  const string barTag)
{
   string parts = "";

   if(phase == ICT_TREND_PHASE_CLEAR)
      parts = IctStructPatternText(pivotStruct);
   else if(phase == ICT_TREND_PHASE_EARLY)
   {
      if(trend == ICT_TREND_UP)
         parts = "Bull sớm";
      else if(trend == ICT_TREND_DOWN)
         parts = "Bear sớm";
   }

   if(ev == ICT_MS_CHOCH && sw.IsComplete())
   {
      if(parts != "")
         parts += ", ";
      if(trend == ICT_TREND_UP || pivotStruct == ICT_STRUCT_BEAR)
         parts += StringFormat("CHoCH %s[1].close > H0(%.2f)", barTag, sw.h0.price);
      else if(trend == ICT_TREND_DOWN || pivotStruct == ICT_STRUCT_BULL)
         parts += StringFormat("CHoCH %s[1].close < L0(%.2f)", barTag, sw.l0.price);
      else
         parts += StringFormat("CHoCH %s[1]", barTag);
   }
   else if(ev == ICT_MS_BOS && sw.IsComplete())
   {
      if(parts != "")
         parts += ", ";
      if(trend == ICT_TREND_UP || pivotStruct == ICT_STRUCT_BULL)
         parts += StringFormat("BOS %s[1].close > H0(%.2f)", barTag, sw.h0.price);
      else if(trend == ICT_TREND_DOWN || pivotStruct == ICT_STRUCT_BEAR)
         parts += StringFormat("BOS %s[1].close < L0(%.2f)", barTag, sw.l0.price);
      else
         parts += StringFormat("BOS %s[1]", barTag);
   }

   if(parts == "")
      parts = "Không xác định cấu trúc";

   return parts;
}

#endif
