#ifndef EA_ICT_CL__CONTEXTS_MQH
#define EA_ICT_CL__CONTEXTS_MQH

// Module: Contexts
// Context updaters extracted from EA_ICT_CL.mq5 (Section 2 – Context updaters).
// NOTE: These functions currently use EA globals (g_*) and existing structs.
//       Include this file AFTER structs + globals are declared in EA_ICT_CL.mq5.

inline HTFBias ResolveBias(double b1H, double b1L, double b1C, double b2H, double b2L)
{
  if (b1C > b2H)               return BIAS_UP;
  if (b1C < b2L)               return BIAS_DOWN;
  if (b1H > b2H && b1C < b2H)  return BIAS_DOWN;
  if (b1L < b2L && b1C > b2L)  return BIAS_UP;
  return BIAS_SIDEWAY;
}

inline void UpdateBiasContext()
{
  datetime t0 = iTime(_Symbol, InpBiasTF, 0);
  if (t0 == g_Bias.lastBarTime) return;
  g_Bias.lastBarTime = t0;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }

  double b1H = iHigh (_Symbol, InpBiasTF, 1);
  double b1L = iLow  (_Symbol, InpBiasTF, 1);
  double b1C = iClose(_Symbol, InpBiasTF, 1);
  double b2H = iHigh (_Symbol, InpBiasTF, 2);
  double b2L = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prev = g_Bias.bias;
  g_Bias.bias  = ResolveBias(b1H, b1L, b1C, b2H, b2L);
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2H : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2L : 0;

  if (InpDebugLog && g_Bias.bias != prev)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias), b1H, b1L, b1C, b2H, b2L);
}

inline void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime t0 = iTime(_Symbol, tf, 0);
  if (t0 == ctx.lastBarTime) return;
  ctx.lastBarTime = t0;

  double   bar1C = iClose(_Symbol, tf, 1);
  datetime bar1T = iTime (_Symbol, tf, 1);

  if (tf == InpTriggerTF
      && g_State == EA_WAIT_TRIGGER
      && ctx.h0 > 0 && ctx.l0 > 0
      && g_MiddleTrend.trend != DIR_NONE)
  {
    bool mssHit = false;
    MarketDir breakDir = DIR_NONE;
    double entryLevel = 0, slLevel = 0;

    if (g_MiddleTrend.trend == DIR_UP && bar1C > ctx.h0)
    {
      mssHit     = true;
      breakDir   = DIR_UP;
      entryLevel = ctx.h0;
      slLevel    = ctx.l0;
    }
    else if (g_MiddleTrend.trend == DIR_DOWN && bar1C < ctx.l0)
    {
      mssHit     = true;
      breakDir   = DIR_DOWN;
      entryLevel = ctx.l0;
      slLevel    = ctx.h0;
    }

    if (mssHit && bar1T != ctx.lastMssTime)
    {
      double swingDepth = MathAbs(ctx.h0 - ctx.l0) / _Point;
      if (swingDepth < InpMSSMinDepthPts)
      {
        if (InpDebugLog)
          PrintFormat("[M5 MSS SKIP] depth=%.0f pts < %d | H0=%.5f L0=%.5f | %s",
            swingDepth, InpMSSMinDepthPts, ctx.h0, ctx.l0, TimeToString(bar1T));
      }
      else
      {
        ctx.lastMssTime  = bar1T;
        ctx.lastMssLevel = entryLevel;
        ctx.lastMssBreak = breakDir;
        ctx.mssSLSwing   = slLevel;

        if (InpDebugLog)
          PrintFormat("[M5 MSS] %s | entry=%.5f SL=%.5f depth=%.0fpts | close=%.5f | H0=%.5f L0=%.5f | %s",
            (breakDir == DIR_UP) ? "▲ Bull" : "▼ Bear",
            entryLevel, slLevel, swingDepth, bar1C,
            ctx.h0, ctx.l0, TimeToString(bar1T));
      }
    }
  }

  double h0, h1, l0, l1;
  int idxH0, idxH1, idxL0, idxL1;
  if (!ScanSwingStructure(tf, lookback, h0, h1, idxH0, idxH1, l0, l1, idxL0, idxL1))
    { ctx.trend = DIR_NONE; return; }

  ctx.h0 = h0; ctx.idxH0 = idxH0;
  ctx.h1 = h1; ctx.idxH1 = idxH1;
  ctx.l0 = l0; ctx.idxL0 = idxL0;
  ctx.l1 = l1; ctx.idxL1 = idxL1;

  MarketDir prev = ctx.trend;
  ResolveTrendFromSwings(tf, h0, h1, l0, l1, ctx.trend, ctx.keyLevel);

  if (InpDebugLog && ctx.trend != prev)
    PrintFormat("[%s TREND] %s → %s | H0=%.5f H1=%.5f L0=%.5f L1=%.5f | KL=%.5f",
      EnumToString(tf), EnumToString(prev), EnumToString(ctx.trend),
      h0, h1, l0, l1, ctx.keyLevel);
}

inline void UpdateDailyRiskContext()
{
  datetime today = iTime(_Symbol, PERIOD_D1, 0);
  if (today != g_DailyRisk.dayStartTime)
  {
    g_DailyRisk.dayStartTime = today;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyRisk.limitHit     = false;
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                    / g_DailyRisk.startBalance * 100.0;
  if (lostPct >= InpMaxDailyLossPct)
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lostPct, g_DailyRisk.currentBalance);
  }
}

inline void UpdateAllContexts()
{
  UpdateDailyRiskContext();
  UpdateBiasContext();
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend);
}

#endif // EA_ICT_CL__CONTEXTS_MQH

