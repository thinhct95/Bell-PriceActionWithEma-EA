//+------------------------------------------------------------------+
//| DailyBias.mqh — Bias rõ (HH-HL/LH-LL) vs sớm (sau CHoCH)       |
//+------------------------------------------------------------------+
#ifndef ICT2026_DAILYBIAS_MQH
#define ICT2026_DAILYBIAS_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Swing.mqh>
#include <ICT2026/StructureCore.mqh>
#include <ICT2026/StructureTrend.mqh>

IctDailyBiasState g_ictDailyBias;
IctTrendResolveCtx g_ictDailyCtx;

ENUM_ICT_BIAS IctBiasFromTrend(const ENUM_ICT_TREND trend)
{
   if(trend == ICT_TREND_UP)
      return ICT_BIAS_BULL;
   if(trend == ICT_TREND_DOWN)
      return ICT_BIAS_BEAR;
   return ICT_BIAS_NONE;
}

void IctUpdateHTFBias(const string sym, const ENUM_TIMEFRAMES tf)
{
   IctHTFBiasState state = g_ictDailyBias.htf;
   const datetime tf0Time = iTime(sym, tf, 0);
   if(tf0Time == state.lastUpdateTime)
      return;

   state.lastUpdateTime = tf0Time;

   const double b1Close = iClose(sym, tf, 1);
   const double b1High  = iHigh(sym, tf, 1);
   const double b1Low   = iLow(sym, tf, 1);
   const double b2High  = iHigh(sym, tf, 2);
   const double b2Low   = iLow(sym, tf, 2);

   state.rangeHigh = 0.0;
   state.rangeLow  = 0.0;

   if(b1Close > b2High)
      state.bias = ICT_HTF_UP;
   else if(b1Close < b2Low)
      state.bias = ICT_HTF_DOWN;
   else if(b1High <= b2High && b1Low >= b2Low)
   {
      state.bias = ICT_HTF_SIDEWAY;
      state.rangeHigh = b2High;
      state.rangeLow  = b2Low;
   }
   else if(b1Close < b2High && b1Close > b2Low)
   {
      state.bias = ICT_HTF_SIDEWAY;
      state.rangeHigh = b1High;
      state.rangeLow  = b1Low;
   }
   else
      state.bias = ICT_HTF_NONE;

   g_ictDailyBias.htf = state;
}

ENUM_ICT_BIAS IctBiasFromHtf(IctHTFBiasState &htf)
{
   if(htf.bias == ICT_HTF_UP)
      return ICT_BIAS_BULL;
   if(htf.bias == ICT_HTF_DOWN)
      return ICT_BIAS_BEAR;
   if(htf.bias == ICT_HTF_SIDEWAY)
      return ICT_BIAS_RANGE;
   return ICT_BIAS_NONE;
}

string IctBiasText(const ENUM_ICT_BIAS bias)
{
   switch(bias)
   {
      case ICT_BIAS_BULL:  return "BULL";
      case ICT_BIAS_BEAR:  return "BEAR";
      case ICT_BIAS_RANGE: return "RANGE";
      default:             return "NONE";
   }
}

string IctStructText(const ENUM_ICT_STRUCT s)
{
   switch(s)
   {
      case ICT_STRUCT_BULL: return "BULL";
      case ICT_STRUCT_BEAR: return "BEAR";
      default:              return "NONE";
   }
}

string IctMsEventText(const ENUM_ICT_MS_EVENT ev)
{
   switch(ev)
   {
      case ICT_MS_BOS:   return "BOS (Continue)";
      case ICT_MS_CHOCH: return "CHoCH (Reversal)";
      default:           return "None";
   }
}

string IctHtfBiasText(const ENUM_ICT_HTF_BIAS bias)
{
   switch(bias)
   {
      case ICT_HTF_UP:      return "UP";
      case ICT_HTF_DOWN:    return "DOWN";
      case ICT_HTF_SIDEWAY: return "SIDEWAY";
      default:              return "NONE";
   }
}

string IctBiasDisplayShort(const ENUM_ICT_BIAS bias)
{
   if(bias == ICT_BIAS_BULL)
      return IctTrendPhaseDisplay(ICT_TREND_UP, g_ictDailyBias.biasPhase);
   if(bias == ICT_BIAS_BEAR)
      return IctTrendPhaseDisplay(ICT_TREND_DOWN, g_ictDailyBias.biasPhase);
   switch(bias)
   {
      case ICT_BIAS_RANGE: return "Range";
      default:             return "None";
   }
}

void IctDailyBias_SyncFromCtx(IctSwingSet &sw, const ENUM_ICT_STRUCT pivotStruct)
{
   g_ictDailyBias.bias               = IctBiasFromTrend(g_ictDailyCtx.trend);
   g_ictDailyBias.biasPhase          = g_ictDailyCtx.phase;
   g_ictDailyBias.lastEvent          = g_ictDailyCtx.lastEvent;
   g_ictDailyBias.lastClearStructural = g_ictDailyCtx.lastClearStructural;
   g_ictDailyBias.swings             = sw;
   g_ictDailyBias.structural         = pivotStruct;

   if(g_ictDailyBias.bias == ICT_BIAS_BULL || g_ictDailyBias.bias == ICT_BIAS_BEAR)
   {
      const ENUM_ICT_STRUCT keyStruct = (g_ictDailyBias.bias == ICT_BIAS_BULL)
                                        ? ICT_STRUCT_BULL : ICT_STRUCT_BEAR;
      if(sw.IsComplete())
         IctGetKeyLevels(keyStruct, sw, g_ictDailyBias.keyLv1, g_ictDailyBias.keyLv2);
   }
   else
   {
      g_ictDailyBias.keyLv1 = 0.0;
      g_ictDailyBias.keyLv2 = 0.0;
   }
}

void IctDailyBias_ApplyHtfFallback()
{
   IctHTFBiasState htfRef = g_ictDailyBias.htf;
   g_ictDailyBias.bias = IctBiasFromHtf(htfRef);
   g_ictDailyBias.biasPhase = ICT_TREND_PHASE_NONE;
   switch(g_ictDailyBias.htf.bias)
   {
      case ICT_HTF_UP:
         g_ictDailyBias.reason = "Fallback: outside day UP (close > prior high)";
         break;
      case ICT_HTF_DOWN:
         g_ictDailyBias.reason = "Fallback: outside day DOWN (close < prior low)";
         break;
      case ICT_HTF_SIDEWAY:
         g_ictDailyBias.reason = StringFormat("Fallback: range [%.5f .. %.5f]",
                                              g_ictDailyBias.htf.rangeLow,
                                              g_ictDailyBias.htf.rangeHigh);
         break;
      default:
         g_ictDailyBias.reason = "Fallback: không đủ structural + HTF indecision";
         break;
   }
}

string IctBuildDisplayReason(IctDailyBiasState &st,
                             const string sym, const ENUM_TIMEFRAMES tf)
{
   if(st.bias == ICT_BIAS_BULL || st.bias == ICT_BIAS_BEAR)
   {
      const ENUM_ICT_TREND trend = (st.bias == ICT_BIAS_BULL) ? ICT_TREND_UP : ICT_TREND_DOWN;
      string parts = IctBuildTrendDisplayReason(st.swings, st.structural,
                                                trend, st.biasPhase, st.lastEvent, "D");
      if(st.htf.bias == ICT_HTF_UP)
      {
         parts += ", D[1].close > D[2].High";
      }
      else if(st.htf.bias == ICT_HTF_DOWN)
      {
         parts += ", D[1].close < D[2].Low";
      }
      return parts;
   }

   string parts = IctStructPatternText(st.structural);
   if(st.htf.bias == ICT_HTF_UP)
   {
      if(parts != "")
         parts += ", ";
      parts += "D[1].close > D[2].High";
   }
   else if(st.htf.bias == ICT_HTF_DOWN)
   {
      if(parts != "")
         parts += ", ";
      parts += "D[1].close < D[2].Low";
   }
   else if(st.htf.bias == ICT_HTF_SIDEWAY)
   {
      const double b1High = iHigh(sym, tf, 1);
      const double b1Low  = iLow(sym, tf, 1);
      const double b2High = iHigh(sym, tf, 2);
      const double b2Low  = iLow(sym, tf, 2);
      if(parts != "")
         parts += ", ";
      if(b1High <= b2High && b1Low >= b2Low)
         parts += "Inside D[1] trong D[2]";
      else
         parts += "Indecision D[1] trong D[2]";
   }

   if(parts == "")
      parts = "Không xác định";

   return parts;
}

void IctDailyBias_Reset()
{
   g_ictDailyCtx.Reset();
   g_ictDailyBias.bias = ICT_BIAS_NONE;
   g_ictDailyBias.biasPhase = ICT_TREND_PHASE_NONE;
   g_ictDailyBias.structural = ICT_STRUCT_NONE;
   g_ictDailyBias.lastEvent = ICT_MS_NONE;
   g_ictDailyBias.fibOk = false;
   g_ictDailyBias.swings.Clear();
   g_ictDailyBias.keyLv1 = 0.0;
   g_ictDailyBias.keyLv2 = 0.0;
   g_ictDailyBias.lastClearStructural = ICT_STRUCT_NONE;
   g_ictDailyBias.pdh = 0.0;
   g_ictDailyBias.pdl = 0.0;
   g_ictDailyBias.pdc = 0.0;
   g_ictDailyBias.eq  = 0.0;
   g_ictDailyBias.htf.bias = ICT_HTF_NONE;
   g_ictDailyBias.htf.rangeHigh = 0.0;
   g_ictDailyBias.htf.rangeLow  = 0.0;
   g_ictDailyBias.htf.lastUpdateTime = 0;
   g_ictDailyBias.lastBarTime = 0;
   g_ictDailyBias.reason = "";
   g_ictDailyBias.displayReason = "";
}

bool IctDailyBias_Init(const string sym)
{
   IctDailyBias_Reset();
   if(Bars(sym, InpBiasTf) < 10)
      return false;

   g_ictDailyBias.htf.lastUpdateTime = 0;
   IctDailyBias_Update(sym, true);
   return true;
}

bool IctDailyBias_Update(const string sym, const bool force = false)
{
   const ENUM_TIMEFRAMES tf = InpBiasTf;
   const datetime bar0 = iTime(sym, tf, 0);
   if(!force && bar0 == g_ictDailyBias.lastBarTime)
      return false;

   g_ictDailyBias.lastBarTime = bar0;

   g_ictDailyBias.pdh = iHigh(sym, tf, 1);
   g_ictDailyBias.pdl = iLow(sym, tf, 1);
   g_ictDailyBias.pdc = iClose(sym, tf, 1);
   g_ictDailyBias.eq  = (g_ictDailyBias.pdh + g_ictDailyBias.pdl) * 0.5;

   IctUpdateHTFBias(sym, tf);

   IctSwingSet sw;
   ENUM_ICT_STRUCT pivotStruct = ICT_STRUCT_NONE;
   sw = IctBuildSwingSet(sym, tf, InpSwingRange, InpSwingLookback, pivotStruct);
   g_ictDailyBias.fibOk = sw.IsComplete() && IctIsPullbackValid(sw, InpFibMinRatio);
   if(InpRequireFib && !g_ictDailyBias.fibOk)
   {
      sw.Clear();
      pivotStruct = ICT_STRUCT_NONE;
   }

   IctResolveTrend(sym, tf, sw, pivotStruct, g_ictDailyCtx, 1);
   IctDailyBias_SyncFromCtx(sw, pivotStruct);

   if(g_ictDailyBias.bias == ICT_BIAS_NONE)
      IctDailyBias_ApplyHtfFallback();
   else
      g_ictDailyBias.reason = StringFormat("Structural: %s",
                                           IctBiasText(g_ictDailyBias.bias));

   g_ictDailyBias.displayReason = IctBuildDisplayReason(g_ictDailyBias, sym, tf);

   if(InpDebug)
   {
      PrintFormat("[ICT2026/DailyBias] %s %s | Bias=%s | Phase=%d | Struct=%s | Event=%s | HTF=%s",
                  sym, EnumToString(tf),
                  IctBiasDisplayShort(g_ictDailyBias.bias),
                  g_ictDailyBias.biasPhase,
                  IctStructText(g_ictDailyBias.structural),
                  IctMsEventText(g_ictDailyBias.lastEvent),
                  IctHtfBiasText(g_ictDailyBias.htf.bias));
      if(g_ictDailyBias.swings.IsComplete())
         PrintFormat("  H0=%.5f H1=%.5f L0=%.5f L1=%.5f | Key1=%.5f Key2=%.5f | %s",
                     g_ictDailyBias.swings.h0.price, g_ictDailyBias.swings.h1.price,
                     g_ictDailyBias.swings.l0.price, g_ictDailyBias.swings.l1.price,
                     g_ictDailyBias.keyLv1, g_ictDailyBias.keyLv2,
                     g_ictDailyBias.reason);
   }
   return true;
}

void IctDailyBias_Get(IctDailyBiasState &out) { out = g_ictDailyBias; }

bool IctDailyBias_IsBull() { return g_ictDailyBias.bias == ICT_BIAS_BULL; }
bool IctDailyBias_IsBear() { return g_ictDailyBias.bias == ICT_BIAS_BEAR; }

#endif
