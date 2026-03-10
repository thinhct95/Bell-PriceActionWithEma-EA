#ifndef EA_ICT_CL__CONTEXTS_MQH
#define EA_ICT_CL__CONTEXTS_MQH  // Tránh include trùng

// Module: Contexts – cập nhật D1 bias, H1/M5 trend (swing + MSS), daily risk

inline HTFBias ResolveBias(double bar1High, double bar1Low, double bar1Close,
                           double bar2High, double bar2Low)
{
  if (bar1Close > bar2High)               return BIAS_UP;      // Close bar 1 trên range bar 2 → tăng
  if (bar1Close < bar2Low)                return BIAS_DOWN;    // Close bar 1 dưới range bar 2 → giảm
  if (bar1High > bar2High && bar1Close < bar2High) return BIAS_DOWN;  // Phá cao rồi đóng dưới → bearish
  if (bar1Low  < bar2Low  && bar1Close > bar2Low)  return BIAS_UP;    // Phá thấp rồi đóng trên → bullish
  return BIAS_SIDEWAY;  // Còn lại = sideway
}

inline void UpdateBiasContext()
{
  datetime currentBiasBarTime = iTime(_Symbol, InpBiasTF, 0);  // Bar D1 hiện tại (đang hình thành)
  if (currentBiasBarTime == g_Bias.lastBarTime) return;        // Đã xử lý bar này rồi → bỏ qua
  g_Bias.lastBarTime = currentBiasBarTime;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }  // Không đủ dữ liệu

  double bar1High  = iHigh (_Symbol, InpBiasTF, 1);  // Bar D1 vừa đóng
  double bar1Low   = iLow  (_Symbol, InpBiasTF, 1);
  double bar1Close = iClose(_Symbol, InpBiasTF, 1);
  double bar2High  = iHigh (_Symbol, InpBiasTF, 2);  // Bar D1 trước đó
  double bar2Low   = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prev = g_Bias.bias;
  g_Bias.bias  = ResolveBias(bar1High, bar1Low, bar1Close, bar2High, bar2Low);  // Tính bias
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? bar2High : 0;  // Vùng sideway
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? bar2Low  : 0;

  if (InpDebugLog && g_Bias.bias != prev)  // Chỉ log khi bias đổi
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias),
      bar1High, bar1Low, bar1Close, bar2High, bar2Low);
}

inline void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime currentTfBarTime = iTime(_Symbol, tf, 0);
  if (currentTfBarTime == ctx.lastBarTime) return;  // Bar chưa đổi → không cập nhật
  ctx.lastBarTime = currentTfBarTime;

  double   lastBarClose = iClose(_Symbol, tf, 1);  // Close bar vừa đóng
  datetime lastBarTime  = iTime (_Symbol, tf, 1);

  // Chỉ detect MSS khi đang WAIT_TRIGGER, trên M5, đã có h0/l0, H1 trend rõ
  if (tf == InpTriggerTF
      && g_State == EA_WAIT_TRIGGER
      && ctx.h0 > 0 && ctx.l0 > 0
      && g_MiddleTrend.trend != DIR_NONE)
  {
    bool      isMssTriggered   = false;
    MarketDir mssBreakDirection = DIR_NONE;
    double    entryLevel       = 0;
    double    slLevel          = 0;

    if (g_MiddleTrend.trend == DIR_UP && lastBarClose > ctx.h0)  // H1 uptrend + M5 close phá tH0 = bull MSS
    {
      isMssTriggered   = true;
      mssBreakDirection = DIR_UP;
      entryLevel       = ctx.h0;  // Entry = tH0
      slLevel          = ctx.l0;  // SL = tL0
    }
    else if (g_MiddleTrend.trend == DIR_DOWN && lastBarClose < ctx.l0)  // Bear MSS
    {
      isMssTriggered   = true;
      mssBreakDirection = DIR_DOWN;
      entryLevel       = ctx.l0;
      slLevel          = ctx.h0;
    }

    if (isMssTriggered && lastBarTime != ctx.lastMssTime)  // MSS mới (chưa ghi nhận bar này)
    {
      double mssSwingDepthPoints = MathAbs(ctx.h0 - ctx.l0) / _Point;  // Độ sâu swing (point)
      if (mssSwingDepthPoints < InpMSSMinDepthPts)  // Quá nông → bỏ qua
      {
        if (InpDebugLog)
          PrintFormat("[M5 MSS SKIP] depth=%.0f pts < %d | H0=%.5f L0=%.5f | %s",
            mssSwingDepthPoints, InpMSSMinDepthPts, ctx.h0, ctx.l0, TimeToString(lastBarTime));
      }
      else
      {
        ctx.lastMssTime  = lastBarTime;       // Ghi nhận thời điểm MSS
        ctx.lastMssLevel = entryLevel;  // Giá entry
        ctx.lastMssBreak = mssBreakDirection; // UP/DOWN
        ctx.mssSLSwing   = slLevel;    // Giá SL (tL0 hoặc tH0)

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
    { ctx.trend = DIR_NONE; return; }  // Không đủ swing

  ctx.h0 = h0; ctx.idxH0 = idxH0;  // Gán swing vào context
  ctx.h1 = h1; ctx.idxH1 = idxH1;
  ctx.l0 = l0; ctx.idxL0 = idxL0;
  ctx.l1 = l1; ctx.idxL1 = idxL1;

  MarketDir prev = ctx.trend;
  ResolveTrendFromSwings(tf, h0, h1, l0, l1, ctx.trend, ctx.keyLevel);  // Suy trend + key level

  if (InpDebugLog && ctx.trend != prev)
    PrintFormat("[%s TREND] %s → %s | H0=%.5f H1=%.5f L0=%.5f L1=%.5f | KL=%.5f",
      EnumToString(tf), EnumToString(prev), EnumToString(ctx.trend),
      h0, h1, l0, l1, ctx.keyLevel);
}

inline void UpdateDailyRiskContext()
{
  datetime currentDayTime = iTime(_Symbol, PERIOD_D1, 0);  // Mốc D1 hiện tại
  if (currentDayTime != g_DailyRisk.dayStartTime)  // Sang ngày mới
  {
    g_DailyRisk.dayStartTime = currentDayTime;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);  // Balance đầu ngày
    g_DailyRisk.limitHit     = false;  // Reset cờ chạm limit
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;  // Đã chạm limit → không cập nhật gì thêm

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lossPercentToday = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                            / g_DailyRisk.startBalance * 100.0;  // % lỗ so với đầu ngày
  if (lossPercentToday >= InpMaxDailyLossPct)  // Vượt ngưỡng max daily loss
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lossPercentToday, g_DailyRisk.currentBalance);
  }
}

inline void UpdateAllContexts()
{
  UpdateDailyRiskContext();  // Cập nhật balance, limit hit
  UpdateBiasContext();       // D1 bias
  UpdateTFTrendContext(InpMiddleTF,  InpSwingLookback,        g_MiddleTrend);   // H1 swing + trend + (MSS không ở đây)
  UpdateTFTrendContext(InpTriggerTF, InpTriggerSwingLookback, g_TriggerTrend);  // M5 swing + trend + MSS
}

#endif // EA_ICT_CL__CONTEXTS_MQH

