//+------------------------------------------------------------------+
//| DailyBias.mqh — Daily Bias resolver (D1)                         |
//+------------------------------------------------------------------+
//| Trả lời câu hỏi: "Hôm nay nên ưu tiên BUY hay SELL?"             |
//|                                                                   |
//| Thứ tự ưu tiên (cao→thấp, v1.175):                                |
//|   1) D1/D2 pattern (IctDailyBias_ResolveD1D2):                    |
//|        - D[1].close > D[2].high            → BULL (breakout)      |
//|        - D[1].close < D[2].low             → BEAR (breakdown)     |
//|        - D[1] sweep D[2] high + close back → BEAR (sweep bear liq)|
//|        - D[1] sweep D[2] low  + close back → BULL (sweep bull liq)|
//|   2) Structural HH-HL / LH-LL (IctResolveTrend)                   |
//|   3) HTF fallback (IctUpdateHTFBias — Previous Day Model)         |
//|                                                                   |
//| Globals owned:                                                    |
//|   g_ictDailyBias        — IctDailyBiasState (kết quả + reason)    |
//|   g_ictDailyCtx         — IctTrendResolveCtx (input cho resolver) |
//|   g_ictBiasIntoBullTime — TS Bias chuyển vào BULL (v1.182)        |
//|   g_ictBiasIntoBearTime — TS Bias chuyển vào BEAR (v1.182)        |
//|     ⇒ làm cutoff cho IctMss_HasFreshFvgTouch (loại touch xảy ra   |
//|        trước khi bias xoay sang side hiện tại)                    |
//|                                                                   |
//| Public API:                                                       |
//|   bool IctDailyBias_Init(sym)                                     |
//|   bool IctDailyBias_Update(sym)  — true khi có nến D1 mới         |
//|   void IctDailyBias_Get(IctDailyBiasState &out)                   |
//|   bool IctDailyBias_IsBull/IsBear()                               |
//|   ENUM_ICT_BIAS ICT2026_GetDailyBias()                            |
//|                                                                   |
//| Internal:                                                         |
//|   IctDailyBias_TrackTransition() — gọi cuối Update để cập nhật    |
//|     g_ictBiasInto*Time khi bias xoay side                         |
//+------------------------------------------------------------------+
#ifndef ICT2026_DAILYBIAS_MQH
#define ICT2026_DAILYBIAS_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Swing.mqh>
#include <ICT2026/StructureCore.mqh>
#include <ICT2026/StructureTrend.mqh>

IctDailyBiasState g_ictDailyBias;
IctTrendResolveCtx g_ictDailyCtx;

// Thời điểm Bias chuyển vào mỗi side — dùng để gác "fresh touch":
//   FVG touch xảy ra TRƯỚC thời điểm Bias chuyển sang side đó ⇒ KHÔNG hợp lệ.
//   Tránh case: bias UP → bear FVG bị chạm (lúc EA bỏ qua) → bias xoay DOWN → EA
//   tưởng đã chạm POI từ quá khứ → vào lệnh limit luôn.
datetime g_ictBiasIntoBullTime = 0;
datetime g_ictBiasIntoBearTime = 0;

void IctDailyBias_TrackTransition()
{
   static ENUM_ICT_BIAS prev = ICT_BIAS_NONE;
   const ENUM_ICT_BIAS cur = g_ictDailyBias.bias;
   if(cur == prev)
      return;
   const datetime now = TimeCurrent();
   if(cur == ICT_BIAS_BULL && prev != ICT_BIAS_BULL)
      g_ictBiasIntoBullTime = now;
   else if(cur == ICT_BIAS_BEAR && prev != ICT_BIAS_BEAR)
      g_ictBiasIntoBearTime = now;
   prev = cur;
}

// Bias từ pattern D1 vs D2 (ưu tiên cao hơn structural HH-HL/LH-LL).
//
// Thứ tự ưu tiên:
//   1. Breakout/Breakdown rõ ràng:
//      - D[1].close > D[2].high → BULL
//      - D[1].close < D[2].low  → BEAR
//   2. Liquidity sweep (false breakout):
//      - D[1].high > D[2].high & D[1].close < D[2].high & close > D[2].low
//        → sweep bear liquidity (quét stop trên) → BEAR
//      - D[1].low  < D[2].low  & D[1].close > D[2].low  & close < D[2].high
//        → sweep bull liquidity (quét stop dưới) → BULL
//   3. Trường hợp đặc biệt: D1 sweep CẢ 2 phía + close kẹt trong range D2
//      ⇒ không xác định ⇒ rơi xuống fallback structural
//
// Return: true nếu match 1 trong các pattern (biasOut + reasonOut được set).
bool IctDailyBias_ResolveD1D2(const string sym, const ENUM_TIMEFRAMES tf,
                              ENUM_ICT_BIAS &biasOut, string &reasonOut)
{
   biasOut   = ICT_BIAS_NONE;
   reasonOut = "";

   const double b1H = iHigh(sym, tf, 1);
   const double b1L = iLow(sym, tf, 1);
   const double b1C = iClose(sym, tf, 1);
   const double b2H = iHigh(sym, tf, 2);
   const double b2L = iLow(sym, tf, 2);

   if(b2H <= 0.0 || b2L <= 0.0 || b1H <= 0.0)
      return false;

   // 1) Clear breakout / breakdown
   if(b1C > b2H)
   {
      biasOut   = ICT_BIAS_BULL;
      reasonOut = "D[1].close > D[2].high → Breakout BULL";
      return true;
   }
   if(b1C < b2L)
   {
      biasOut   = ICT_BIAS_BEAR;
      reasonOut = "D[1].close < D[2].low → Breakdown BEAR";
      return true;
   }

   // Đến đây: b2L ≤ b1C ≤ b2H (close kẹt trong range D2)
   const bool sweepHigh = (b1H > b2H);
   const bool sweepLow  = (b1L < b2L);

   // 2a) Cả 2 phía cùng sweep + close inside ⇒ không xác định
   if(sweepHigh && sweepLow)
      return false;

   // 2b) Sweep bear liquidity
   if(sweepHigh)
   {
      biasOut   = ICT_BIAS_BEAR;
      reasonOut = "D[1].high > D[2].high & close < D[2].high → sweep bear liq → BEAR";
      return true;
   }

   // 2c) Sweep bull liquidity
   if(sweepLow)
   {
      biasOut   = ICT_BIAS_BULL;
      reasonOut = "D[1].low < D[2].low & close > D[2].low → sweep bull liq → BULL";
      return true;
   }

   // Inside day hoặc trùng range — không match D1/D2 pattern
   return false;
}

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

   // ƯU TIÊN 1: D1/D2 pattern (4 cases: breakout, breakdown, 2 sweeps).
   //   D1/D2 thắng cả structural — override bias nếu match.
   ENUM_ICT_BIAS d1d2Bias = ICT_BIAS_NONE;
   string d1d2Reason     = "";
   if(IctDailyBias_ResolveD1D2(sym, tf, d1d2Bias, d1d2Reason))
   {
      g_ictDailyBias.bias      = d1d2Bias;
      g_ictDailyBias.biasPhase = ICT_TREND_PHASE_CLEAR;
      g_ictDailyBias.reason    = d1d2Reason;
      g_ictDailyBias.keyLv1    = 0.0;
      g_ictDailyBias.keyLv2    = 0.0;
      if(sw.IsComplete())
      {
         const ENUM_ICT_STRUCT keyStruct = (d1d2Bias == ICT_BIAS_BULL)
                                           ? ICT_STRUCT_BULL : ICT_STRUCT_BEAR;
         IctGetKeyLevels(keyStruct, sw, g_ictDailyBias.keyLv1, g_ictDailyBias.keyLv2);
      }
      g_ictDailyBias.displayReason = d1d2Reason;
   }
   // ƯU TIÊN 2: Structural HH-HL/LH-LL (đã set ở SyncFromCtx ở trên).
   else if(g_ictDailyBias.bias == ICT_BIAS_BULL || g_ictDailyBias.bias == ICT_BIAS_BEAR)
   {
      g_ictDailyBias.reason = StringFormat("Structural: %s",
                                           IctBiasText(g_ictDailyBias.bias));
      g_ictDailyBias.displayReason = IctBuildDisplayReason(g_ictDailyBias, sym, tf);
   }
   // ƯU TIÊN 3: HTF fallback (outside day / range).
   else
   {
      IctDailyBias_ApplyHtfFallback();
      g_ictDailyBias.displayReason = IctBuildDisplayReason(g_ictDailyBias, sym, tf);
   }

   // Cập nhật timestamp Bias chuyển side (để gác fresh touch sau Bias flip)
   IctDailyBias_TrackTransition();

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
