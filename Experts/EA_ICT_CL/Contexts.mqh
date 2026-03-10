#ifndef EA_ICT_CL__CONTEXTS_MQH
#define EA_ICT_CL__CONTEXTS_MQH

/** Updates TF trend context (swing + trend + MSS detection when on trigger TF). */
inline void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime currentTfBarTime = iTime(_Symbol, tf, 0);
  if (currentTfBarTime == ctx.lastBarTime) return;
  ctx.lastBarTime = currentTfBarTime;

  double   lastBarClose = iClose(_Symbol, tf, 1);
  datetime lastBarTime  = iTime (_Symbol, tf, 1);

  if (tf == InpTriggerTF
      && g_State == EA_WAIT_TRIGGER
      && ctx.h0 > 0 && ctx.l0 > 0
      && g_MiddleTrend.trend != DIR_NONE)
  {
    bool      isMssTriggered   = false;
    MarketDir mssBreakDirection = DIR_NONE;
    double    entryLevel       = 0;
    double    slLevel          = 0;

    if (g_MiddleTrend.trend == DIR_UP && lastBarClose > ctx.h0)
    {
      isMssTriggered   = true;
      mssBreakDirection = DIR_UP;
      entryLevel       = ctx.h0;
      slLevel          = ctx.l0;
    }
    else if (g_MiddleTrend.trend == DIR_DOWN && lastBarClose < ctx.l0)
    {
      isMssTriggered   = true;
      mssBreakDirection = DIR_DOWN;
      entryLevel       = ctx.l0;
      slLevel          = ctx.h0;
    }

    if (isMssTriggered && lastBarTime != ctx.lastMssTime)
    {
      double mssSwingDepthPoints = MathAbs(ctx.h0 - ctx.l0) / _Point;
      if (mssSwingDepthPoints < InpMSSMinDepthPts)
      {
        if (InpDebugLog)
          PrintFormat("[M5 MSS SKIP] depth=%.0f pts < %d | H0=%.5f L0=%.5f | %s",
            mssSwingDepthPoints, InpMSSMinDepthPts, ctx.h0, ctx.l0, TimeToString(lastBarTime));
      }
      else
      {
        ctx.lastMssTime  = lastBarTime;
        ctx.lastMssLevel = entryLevel;
        ctx.lastMssBreak = mssBreakDirection;
        ctx.mssSLSwing   = slLevel;

        if (InpDebugLog)
          PrintFormat("[M5 MSS] %s | entry=%.5f SL=%.5f depth=%.0fpts | close=%.5f | H0=%.5f L0=%.5f | %s",
            (mssBreakDirection == DIR_UP) ? "▲ Bull" : "▼ Bear",
            entryLevel, slLevel, mssSwingDepthPoints, lastBarClose,
            ctx.h0, ctx.l0, TimeToString(lastBarTime));
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

/** Updates daily risk context (day start balance, current balance, limit-hit flag). */
inline void UpdateDailyRiskContext()
{
  datetime currentDayTime = iTime(_Symbol, PERIOD_D1, 0);
  if (currentDayTime != g_DailyRisk.dayStartTime)
  {
    g_DailyRisk.dayStartTime = currentDayTime;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyRisk.limitHit     = false;
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lossPercentToday = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                            / g_DailyRisk.startBalance * 100.0;
  if (lossPercentToday >= InpMaxDailyLossPct)
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lossPercentToday, g_DailyRisk.currentBalance);
  }
}

/** Updates all contexts: daily risk, middle TF trend, trigger TF trend. */
inline void UpdateAllContexts()
{
  UpdateDailyRiskContext();
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend);
}

#endif
