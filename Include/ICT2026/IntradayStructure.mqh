//+------------------------------------------------------------------+
//| IntradayStructure.mqh — trend rõ (HH-HL/LH-LL) vs sớm (CHoCH)  |
//+------------------------------------------------------------------+
#ifndef ICT2026_INTRADAYSTRUCTURE_MQH
#define ICT2026_INTRADAYSTRUCTURE_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Swing.mqh>
#include <ICT2026/StructureCore.mqh>
#include <ICT2026/StructureTrend.mqh>
#include <ICT2026/DailyBias.mqh>

IctIntradayState g_ictIntraday;
IctTrendResolveCtx g_ictIntradayCtx;

string IctTfBarPrefix(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M5:   return "M5";
      case PERIOD_M15:  return "M15";
      case PERIOD_M30:  return "M30";
      case PERIOD_H1:   return "H";
      case PERIOD_H4:   return "H4";
      case PERIOD_D1:   return "D";
      case PERIOD_W1:   return "W";
      case PERIOD_MN1:  return "MN";
      default:          return "T";
   }
}

string IctTrendDisplayShort(const ENUM_ICT_TREND trend)
{
   return IctTrendPhaseDisplay(trend, g_ictIntraday.trendPhase);
}

ENUM_ICT_STRUCT IctStructFromTrend(const ENUM_ICT_TREND trend)
{
   if(trend == ICT_TREND_UP)
      return ICT_STRUCT_BULL;
   if(trend == ICT_TREND_DOWN)
      return ICT_STRUCT_BEAR;
   return ICT_STRUCT_NONE;
}

void IctIntraday_SyncFromCtx(IctSwingSet &sw, const ENUM_ICT_STRUCT pivotStruct)
{
   g_ictIntraday.trend               = g_ictIntradayCtx.trend;
   g_ictIntraday.trendPhase          = g_ictIntradayCtx.phase;
   g_ictIntraday.lastEvent           = g_ictIntradayCtx.lastEvent;
   g_ictIntraday.lastClearStructural = g_ictIntradayCtx.lastClearStructural;
   g_ictIntraday.swings              = sw;
   g_ictIntraday.structural          = pivotStruct;

   const ENUM_ICT_STRUCT keyStruct = IctStructFromTrend(g_ictIntraday.trend);
   if(keyStruct != ICT_STRUCT_NONE && sw.IsComplete())
      IctGetKeyLevels(keyStruct, sw, g_ictIntraday.keyLv1, g_ictIntraday.keyLv2);
   else
   {
      g_ictIntraday.keyLv1 = 0.0;
      g_ictIntraday.keyLv2 = 0.0;
   }
}

// Bias làm chủ đạo: AllowTrade chỉ block khi Intraday CONFIRMED NGƯỢC chiều Bias.
// Intraday NONE (đang transition / chưa rõ) → vẫn allow theo Bias.
//   BULL bias + UP   trend → allow ✓
//   BULL bias + NONE trend → allow ✓ (transition, không ngược)
//   BULL bias + DOWN trend → BLOCK ✗ (ngược chiều rõ ràng)
//   BEAR bias + DOWN trend → allow ✓
//   BEAR bias + NONE trend → allow ✓
//   BEAR bias + UP   trend → BLOCK ✗
//   NONE bias              → BLOCK ✗ (không có direction)
bool IctIntraday_TrendAlignsWithBias(const ENUM_ICT_BIAS bias,
                                     const ENUM_ICT_TREND trend)
{
   if(bias == ICT_BIAS_NONE)
      return false;
   if(bias == ICT_BIAS_BULL && trend == ICT_TREND_DOWN)
      return false;
   if(bias == ICT_BIAS_BEAR && trend == ICT_TREND_UP)
      return false;
   return true;
}

void IctIntraday_UpdateAllowTrade()
{
   g_ictIntraday.isAllowTrade = IctIntraday_TrendAlignsWithBias(g_ictDailyBias.bias,
                                                                g_ictIntraday.trend);
}

void IctIntraday_Reset()
{
   g_ictIntradayCtx.Reset();
   g_ictIntraday.trend = ICT_TREND_NONE;
   g_ictIntraday.trendPhase = ICT_TREND_PHASE_NONE;
   g_ictIntraday.structural = ICT_STRUCT_NONE;
   g_ictIntraday.lastEvent = ICT_MS_NONE;
   g_ictIntraday.swings.Clear();
   g_ictIntraday.keyLv1 = 0.0;
   g_ictIntraday.keyLv2 = 0.0;
   g_ictIntraday.lastClearStructural = ICT_STRUCT_NONE;
   g_ictIntraday.lastBarTime = 0;
   g_ictIntraday.displayReason = "";
   g_ictIntraday.isAllowTrade = false;
}

bool IctIntraday_Init(const string sym)
{
   IctIntraday_Reset();
   if(Bars(sym, InpIntradayTf) < 10)
      return false;

   IctIntraday_Update(sym, true);
   return true;
}

bool IctIntraday_Update(const string sym, const bool force = false)
{
   const ENUM_TIMEFRAMES tf = InpIntradayTf;
   const datetime bar0 = iTime(sym, tf, 0);
   if(!force && bar0 == g_ictIntraday.lastBarTime)
      return false;

   g_ictIntraday.lastBarTime = bar0;

   IctSwingSet sw;
   ENUM_ICT_STRUCT pivotStruct = ICT_STRUCT_NONE;
   if(!IctBuildSwingSetRecentPivots(sym, tf,
                                   InpIntradaySwingRange,
                                   InpIntradaySwingLookback,
                                   InpIntradayRecentBars,
                                   sw, pivotStruct))
      sw.Clear();

   IctResolveTrend(sym, tf, sw, pivotStruct, g_ictIntradayCtx, 1);
   IctIntraday_SyncFromCtx(sw, pivotStruct);

   g_ictIntraday.displayReason = IctBuildTrendDisplayReason(sw, pivotStruct,
                                                            g_ictIntraday.trend,
                                                            g_ictIntraday.trendPhase,
                                                            g_ictIntraday.lastEvent,
                                                            IctTfBarPrefix(tf));
   IctIntraday_UpdateAllowTrade();

   if(InpDebug)
   {
      PrintFormat("[ICT2026/Intraday] %s %s | Trend=%s | Phase=%d | Struct=%s | Event=%s | Allow=%s",
                  sym, EnumToString(tf),
                  IctTrendPhaseDisplay(g_ictIntraday.trend, g_ictIntraday.trendPhase),
                  g_ictIntraday.trendPhase,
                  IctStructText(g_ictIntraday.structural),
                  IctMsEventText(g_ictIntraday.lastEvent),
                  g_ictIntraday.isAllowTrade ? "YES" : "NO");
      if(g_ictIntraday.swings.IsComplete())
         PrintFormat("  H0=%.2f H1=%.2f L0=%.2f L1=%.2f | Key1=%.2f Key2=%.2f",
                     g_ictIntraday.swings.h0.price, g_ictIntraday.swings.h1.price,
                     g_ictIntraday.swings.l0.price, g_ictIntraday.swings.l1.price,
                     g_ictIntraday.keyLv1, g_ictIntraday.keyLv2);
      PrintFormat("  %s", g_ictIntraday.displayReason);
   }

   return true;
}

void IctIntraday_Get(IctIntradayState &out) { out = g_ictIntraday; }

bool IctIntraday_IsAllowTrade() { return g_ictIntraday.isAllowTrade; }

#endif
