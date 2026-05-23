//+------------------------------------------------------------------+
//| PhaseEntry.mqh — entry 5 phase (mở rộng → cuộn → EMA9↑ → WMA45 phẳng → cắt) |
//+------------------------------------------------------------------+
#ifndef RSI_MOM_PHASE_ENTRY_MQH
#define RSI_MOM_PHASE_ENTRY_MQH

struct PhaseEntryConfig
{
   bool   enabled;
   int    expandLookback;      // quét phase 1 trong [shift+1 .. shift+N]
   double minExpandSpread;     // min (WMA45-RSI) khi xếp lớp bear/bull
   int    coilLookback;        // quét cuộn RSI↔EMA9 trước nến tín hiệu
   int    minRsiEma9Crosses;   // số lần RSI cắt EMA9 (chống xuyên 1 lần — dấu hiệu 3)
   double coilBand;            // |RSI-EMA9| <= band tính là quanh EMA9
   int    ema9SlopeBars;       // cửa sổ so sánh hướng EMA9 (P3)
   double ema9SlopeTol;        // BUY: cho phép EMA9 giảm tối đa X pt RSI trong cửa sổ P3
   int    wmaFlatBars;         // |WMA45[i]-WMA45[i+bars]| <= flatMax
   double wmaWasSlopeMin;      // P4: WMA45 trước đó dốc đủ (khi wmaRelaxPrior=false)
   double wmaFlatMaxSlope;     // WMA45 gần phẳng tại signal
   bool   wmaRelaxPrior;       // P4: chỉ cần WMA45 từng giảm/tăng, không cần dốc tối thiểu
   double maxEma9WmaGap;       // EMA9 gần WMA45 tại cắt (chống dấu hiệu 1)
};

bool Phase_Ema9TurningBuy(const int shift, const PhaseEntryConfig &cfg, const double &ema9[])
{
   const int b = cfg.ema9SlopeBars;
   if(ema9[shift + b] <= 0.0)
      return false;
   return (ema9[shift] >= ema9[shift + b] - cfg.ema9SlopeTol);
}

bool Phase_Ema9TurningSell(const int shift, const PhaseEntryConfig &cfg, const double &ema9[])
{
   const int b = cfg.ema9SlopeBars;
   if(ema9[shift + b] <= 0.0)
      return false;
   return (ema9[shift] <= ema9[shift + b] + cfg.ema9SlopeTol);
}

int Phase_CountRsiEma9Crosses(const int shift, const int lookback, const int rates_total,
                              const double &rsi[], const double &ema9[])
{
   int crosses = 0;
   const int end = MathMin(shift + lookback, rates_total - 2);
   for(int j = shift + 1; j < end; j++)
   {
      const bool up = (rsi[j+1] <= ema9[j+1]) && (rsi[j] > ema9[j]);
      const bool dn = (rsi[j+1] >= ema9[j+1]) && (rsi[j] < ema9[j]);
      if(up || dn)
         crosses++;
   }
   return crosses;
}

int Phase_CountCoilBars(const int shift, const int lookback, const int rates_total,
                        const double &rsi[], const double &ema9[], const double band)
{
   int n = 0;
   const int end = MathMin(shift + lookback, rates_total - 1);
   for(int j = shift + 1; j <= end; j++)
   {
      if(MathAbs(rsi[j] - ema9[j]) <= band)
         n++;
   }
   return n;
}

bool Phase_FindMaxSpreadDown(const int shift, const int lookback, const int rates_total,
                             const double &rsi[], const double &ema9[], const double &wma[],
                             const double minSpread, double &maxSpread)
{
   maxSpread = 0.0;
   const int end = MathMin(shift + lookback, rates_total - 1);
   for(int j = shift + 1; j <= end; j++)
   {
      if(rsi[j] >= ema9[j] || ema9[j] >= wma[j])
         continue;
      const double sp = wma[j] - rsi[j];
      if(sp > maxSpread)
         maxSpread = sp;
   }
   return (maxSpread >= minSpread - 1e-8);
}

bool Phase_FindMaxSpreadUp(const int shift, const int lookback, const int rates_total,
                           const double &rsi[], const double &ema9[], const double &wma[],
                           const double minSpread, double &maxSpread)
{
   maxSpread = 0.0;
   const int end = MathMin(shift + lookback, rates_total - 1);
   for(int j = shift + 1; j <= end; j++)
   {
      if(rsi[j] <= ema9[j] || ema9[j] <= wma[j])
         continue;
      const double sp = rsi[j] - wma[j];
      if(sp > maxSpread)
         maxSpread = sp;
   }
   return (maxSpread >= minSpread - 1e-8);
}

bool Phase_Wma45FlatteningBuyEx(const int shift, const int flatBars,
                               const double flatMaxSlope, const double wasSlopeMin,
                               const bool relaxPrior, const double &wma[])
{
   const int b = MathMax(2, flatBars);
   const double recent = (wma[shift] - wma[shift + b]) / (double)b;
   const double prior  = (wma[shift + b] - wma[shift + 2 * b]) / (double)b;
   if(relaxPrior)
   {
      if(prior > 0.0)
         return false;
   }
   else if(prior > -wasSlopeMin)
      return false;
   return (MathAbs(recent) <= flatMaxSlope);
}

bool Phase_Wma45FlatteningBuy(const int shift, const int flatBars,
                              const double flatMaxSlope, const double wasSlopeMin,
                              const double &wma[])
{
   return Phase_Wma45FlatteningBuyEx(shift, flatBars, flatMaxSlope, wasSlopeMin, false, wma);
}

bool Phase_Wma45FlatteningSellEx(const int shift, const int flatBars,
                                const double flatMaxSlope, const double wasSlopeMin,
                                const bool relaxPrior, const double &wma[])
{
   const int b = MathMax(2, flatBars);
   const double recent = (wma[shift] - wma[shift + b]) / (double)b;
   const double prior  = (wma[shift + b] - wma[shift + 2 * b]) / (double)b;
   if(relaxPrior)
   {
      if(prior < 0.0)
         return false;
   }
   else if(prior < wasSlopeMin)
      return false;
   return (MathAbs(recent) <= flatMaxSlope);
}

bool Phase_Wma45FlatteningSell(const int shift, const int flatBars,
                               const double flatMaxSlope, const double wasSlopeMin,
                               const double &wma[])
{
   return Phase_Wma45FlatteningSellEx(shift, flatBars, flatMaxSlope, wasSlopeMin, false, wma);
}

bool Phase_Wma45FlatteningBuyCfg(const int shift, const PhaseEntryConfig &cfg, const double &wma[])
{
   return Phase_Wma45FlatteningBuyEx(shift, cfg.wmaFlatBars, cfg.wmaFlatMaxSlope,
                                    cfg.wmaWasSlopeMin, cfg.wmaRelaxPrior, wma);
}

bool Phase_Wma45FlatteningSellCfg(const int shift, const PhaseEntryConfig &cfg, const double &wma[])
{
   return Phase_Wma45FlatteningSellEx(shift, cfg.wmaFlatBars, cfg.wmaFlatMaxSlope,
                                     cfg.wmaWasSlopeMin, cfg.wmaRelaxPrior, wma);
}

bool Phase_Ema9NearWmaBuy(const int shift, const double maxGap,
                          const double &ema9[], const double &wma[])
{
   if(ema9[shift] >= wma[shift])
      return false;
   return ((wma[shift] - ema9[shift]) <= maxGap + 1e-8);
}

bool Phase_Ema9NearWmaSell(const int shift, const double maxGap,
                           const double &ema9[], const double &wma[])
{
   if(ema9[shift] <= wma[shift])
      return false;
   return ((ema9[shift] - wma[shift]) <= maxGap + 1e-8);
}

bool Phase_BuyPasses(const int shift, const int rates_total,
                     const double &rsi[], const double &ema9[], const double &wma[],
                     const PhaseEntryConfig &cfg, string &failTag)
{
   failTag = "";
   if(!cfg.enabled)
      return true;

   double maxSp = 0.0;
   if(!Phase_FindMaxSpreadDown(shift, cfg.expandLookback, rates_total,
                               rsi, ema9, wma, cfg.minExpandSpread, maxSp))
   {
      failTag = "P1-mở rộng ";
      return false;
   }

   const int crosses = Phase_CountRsiEma9Crosses(shift, cfg.coilLookback, rates_total, rsi, ema9);
   if(crosses < cfg.minRsiEma9Crosses)
   {
      failTag = "P2-cuộn ";
      return false;
   }

   if(!Phase_Ema9TurningBuy(shift, cfg, ema9))
   {
      failTag = "P3-EMA9↑ ";
      return false;
   }

   if(!Phase_Wma45FlatteningBuyCfg(shift, cfg, wma))
   {
      failTag = "P4-WMA45 phẳng ";
      return false;
   }

   if(!Phase_Ema9NearWmaBuy(shift, cfg.maxEma9WmaGap, ema9, wma))
   {
      failTag = "P5-EMA9 xa WMA45 ";
      return false;
   }

   return true;
}

bool Phase_SellPasses(const int shift, const int rates_total,
                      const double &rsi[], const double &ema9[], const double &wma[],
                      const PhaseEntryConfig &cfg, string &failTag)
{
   failTag = "";
   if(!cfg.enabled)
      return true;

   double maxSp = 0.0;
   if(!Phase_FindMaxSpreadUp(shift, cfg.expandLookback, rates_total,
                             rsi, ema9, wma, cfg.minExpandSpread, maxSp))
   {
      failTag = "P1-mở rộng ";
      return false;
   }

   const int crosses = Phase_CountRsiEma9Crosses(shift, cfg.coilLookback, rates_total, rsi, ema9);
   if(crosses < cfg.minRsiEma9Crosses)
   {
      failTag = "P2-cuộn ";
      return false;
   }

   if(!Phase_Ema9TurningSell(shift, cfg, ema9))
   {
      failTag = "P3-EMA9↓ ";
      return false;
   }

   if(!Phase_Wma45FlatteningSellCfg(shift, cfg, wma))
   {
      failTag = "P4-WMA45 phẳng ";
      return false;
   }

   if(!Phase_Ema9NearWmaSell(shift, cfg.maxEma9WmaGap, ema9, wma))
   {
      failTag = "P5-EMA9 xa WMA45 ";
      return false;
   }

   return true;
}

#endif
