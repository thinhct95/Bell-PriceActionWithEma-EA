#ifndef EA_ICT_CL__CONTEXTS_MQH
#define EA_ICT_CL__CONTEXTS_MQH  // Tránh include trùng

// Module: Contexts – cập nhật D1 bias, H1/M5 trend (swing + MSS), daily risk

inline HTFBias ResolveBias(double b1H, double b1L, double b1C, double b2H, double b2L)
{
  if (b1C > b2H)               return BIAS_UP;      // Close bar 1 trên range bar 2 → tăng
  if (b1C < b2L)               return BIAS_DOWN;   // Close bar 1 dưới range bar 2 → giảm
  if (b1H > b2H && b1C < b2H)  return BIAS_DOWN;   // Phá cao rồi đóng dưới → bearish
  if (b1L < b2L && b1C > b2L)  return BIAS_UP;     // Phá thấp rồi đóng trên → bullish
  return BIAS_SIDEWAY;  // Còn lại = sideway
}

inline void UpdateBiasContext()
{
  datetime t0 = iTime(_Symbol, InpBiasTF, 0);  // Bar D1 hiện tại (đang hình thành)
  if (t0 == g_Bias.lastBarTime) return;        // Đã xử lý bar này rồi → bỏ qua
  g_Bias.lastBarTime = t0;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }  // Không đủ dữ liệu

  double b1H = iHigh (_Symbol, InpBiasTF, 1);  // Bar D1 vừa đóng
  double b1L = iLow  (_Symbol, InpBiasTF, 1);
  double b1C = iClose(_Symbol, InpBiasTF, 1);
  double b2H = iHigh (_Symbol, InpBiasTF, 2);  // Bar D1 trước đó
  double b2L = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prev = g_Bias.bias;
  g_Bias.bias  = ResolveBias(b1H, b1L, b1C, b2H, b2L);  // Tính bias
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2H : 0;  // Vùng sideway
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2L : 0;

  if (InpDebugLog && g_Bias.bias != prev)  // Chỉ log khi bias đổi
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prev), EnumToString(g_Bias.bias), b1H, b1L, b1C, b2H, b2L);
}

inline void UpdateTFTrendContext(ENUM_TIMEFRAMES tf, int lookback, TFTrendContext &ctx)
{
  datetime t0 = iTime(_Symbol, tf, 0);
  if (t0 == ctx.lastBarTime) return;  // Bar chưa đổi → không cập nhật
  ctx.lastBarTime = t0;

  double   bar1C = iClose(_Symbol, tf, 1);  // Close bar vừa đóng
  datetime bar1T = iTime (_Symbol, tf, 1);

  // Chỉ detect MSS khi đang WAIT_TRIGGER, trên M5, đã có h0/l0, H1 trend rõ
  if (tf == InpTriggerTF
      && g_State == EA_WAIT_TRIGGER
      && ctx.h0 > 0 && ctx.l0 > 0
      && g_MiddleTrend.trend != DIR_NONE)
  {
    bool mssHit = false;
    MarketDir breakDir = DIR_NONE;
    double entryLevel = 0, slLevel = 0;

    if (g_MiddleTrend.trend == DIR_UP && bar1C > ctx.h0)  // H1 uptrend + M5 close phá tH0 = bull MSS
    {
      mssHit     = true;
      breakDir   = DIR_UP;
      entryLevel = ctx.h0;  // Entry = tH0
      slLevel    = ctx.l0;   // SL = tL0
    }
    else if (g_MiddleTrend.trend == DIR_DOWN && bar1C < ctx.l0)  // Bear MSS
    {
      mssHit     = true;
      breakDir   = DIR_DOWN;
      entryLevel = ctx.l0;
      slLevel    = ctx.h0;
    }

    if (mssHit && bar1T != ctx.lastMssTime)  // MSS mới (chưa ghi nhận bar này)
    {
      double swingDepth = MathAbs(ctx.h0 - ctx.l0) / _Point;  // Độ sâu swing (point)
      if (swingDepth < InpMSSMinDepthPts)  // Quá nông → bỏ qua
      {
        if (InpDebugLog)
          PrintFormat("[M5 MSS SKIP] depth=%.0f pts < %d | H0=%.5f L0=%.5f | %s",
            swingDepth, InpMSSMinDepthPts, ctx.h0, ctx.l0, TimeToString(bar1T));
      }
      else
      {
        ctx.lastMssTime  = bar1T;       // Ghi nhận thời điểm MSS
        ctx.lastMssLevel = entryLevel;  // Giá entry
        ctx.lastMssBreak = breakDir;    // UP/DOWN
        ctx.mssSLSwing   = slLevel;    // Giá SL (tL0 hoặc tH0)

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
  datetime today = iTime(_Symbol, PERIOD_D1, 0);  // Mốc D1 hiện tại
  if (today != g_DailyRisk.dayStartTime)  // Sang ngày mới
  {
    g_DailyRisk.dayStartTime = today;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);  // Balance đầu ngày
    g_DailyRisk.limitHit     = false;  // Reset cờ chạm limit
    if (InpDebugLog) PrintFormat("[DAILY RISK] New day | start=%.2f", g_DailyRisk.startBalance);
  }
  if (g_DailyRisk.limitHit) return;  // Đã chạm limit → không cập nhật gì thêm

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                    / g_DailyRisk.startBalance * 100.0;  // % lỗ so với đầu ngày
  if (lostPct >= InpMaxDailyLossPct)  // Vượt ngưỡng max daily loss
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | bal=%.2f",
      lostPct, g_DailyRisk.currentBalance);
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

