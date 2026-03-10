#ifndef EA_ICT_CL__CONTEXTS_MQH
#define EA_ICT_CL__CONTEXTS_MQH

/** Resolves D1 bias from two consecutive daily bars (bar1 = last closed, bar2 = prior). */
inline HTFBias ResolveBias(double bar1High, double bar1Low, double bar1Close,
                           double bar2High, double bar2Low)
{
  if (bar1Close > bar2High)                       return BIAS_UP;
  if (bar1Close < bar2Low)                        return BIAS_DOWN;

  bool sweptHigh = (bar1High > bar2High);
  bool sweptLow  = (bar1Low  < bar2Low);

  // Trường hợp quét cả hai đầu: so sánh độ dài râu vượt khỏi range bar2.
  // Râu nào dài hơn → ưu tiên chiều NGƯỢC LẠI (stop run –> đi ngược sweep mạnh hơn).
  if (sweptHigh && sweptLow)
  {
    double upperSweep = bar1High - bar2High;  // khoảng quét lên trên đỉnh cũ
    double lowerSweep = bar2Low  - bar1Low;   // khoảng quét xuống dưới đáy cũ

    if (upperSweep > lowerSweep) return BIAS_DOWN; // quét đỉnh mạnh hơn → bearish
    if (lowerSweep > upperSweep) return BIAS_UP;   // quét đáy mạnh hơn → bullish

    // Nếu hai râu gần như bằng nhau → dùng close tương đối với mid-range để phân định
    double mid = (bar2High + bar2Low) * 0.5;
    if (bar1Close > mid) return BIAS_UP;
    if (bar1Close < mid) return BIAS_DOWN;
    return BIAS_SIDEWAY;
  }

  // Chỉ quét 1 đầu: giữ logic cũ với điều kiện close quay lại trong range.
  if (sweptLow  && bar1Close > bar2Low)  return BIAS_UP;
  if (sweptHigh && bar1Close < bar2High) return BIAS_DOWN;

  return BIAS_SIDEWAY;
}

/** Updates global D1 bias context once per new bias-TF bar. */
inline void UpdateBiasContext()
{
  datetime currentBiasBarTime = iTime(_Symbol, InpBiasTF, 0);
  if (currentBiasBarTime == g_Bias.lastBarTime) return;
  g_Bias.lastBarTime = currentBiasBarTime;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }

  double bar1High  = iHigh (_Symbol, InpBiasTF, 1);
  double bar1Low   = iLow  (_Symbol, InpBiasTF, 1);
  double bar1Close = iClose(_Symbol, InpBiasTF, 1);
  double bar2High  = iHigh (_Symbol, InpBiasTF, 2);
  double bar2Low   = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prev = g_Bias.bias;
  g_Bias.bias  = ResolveBias(bar1High, bar1Low, bar1Close, bar2High, bar2Low);
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? bar2High : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? bar2Low  : 0;

  if (InpDebugLog && g_Bias.bias != prev)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias),
      bar1High, bar1Low, bar1Close, bar2High, bar2Low);
}

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
      entryLevel       = ctx.h0;  // Entry = tH0
      slLevel          = ctx.l0;  // SL = tL0
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

/** Updates all contexts: daily risk, bias, middle TF trend, trigger TF trend. */
inline void UpdateAllContexts()
{
  UpdateDailyRiskContext();
  UpdateBiasContext();
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend);
}

#endif // EA_ICT_CL__CONTEXTS_MQH

