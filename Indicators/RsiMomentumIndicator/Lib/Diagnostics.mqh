//+------------------------------------------------------------------+
//| Diagnostics.mqh                                                  |
//| Log chẩn đoán lần đầu OnCalculate hoàn thành full để xác minh    |
//| data. Chỉ chạy 1 lần duy nhất (static guard).                     |
//+------------------------------------------------------------------+
#ifndef RSIMOM_DIAGNOSTICS_MQH
#define RSIMOM_DIAGNOSTICS_MQH

//+------------------------------------------------------------------+
//| In thông tin chẩn đoán khi indicator chạy xong lần đầu           |
//+------------------------------------------------------------------+
void Diagnostics_FirstPass(const int rates_total,
                           const int copyN,
                           const int trendN,
                           const int need,
                           const double &closeArr[])
{
  static bool firstSuccess = false;
  if (firstSuccess || copyN < rates_total) return;
  firstSuccess = true;

  int upCount = 0, downCount = 0, rangeCount = 0, zeroEma = 0;
  const int n = MathMin(500, rates_total - 2);
  for (int i = 1; i <= n; i++)
  {
    if (buf_EMA200[i] <= 0.0) zeroEma++;
    if      (buf_Trend[i] >  0.5) upCount++;
    else if (buf_Trend[i] < -0.5) downCount++;
    else                          rangeCount++;
  }
  PrintFormat("[RsiMom] First-pass OK rates_total=%d copyN=%d trendN=%d need=%d",
              rates_total, copyN, trendN, need);
  PrintFormat("[RsiMom]   bar1: RSI=%.2f EMA9=%.2f WMA45=%.2f EMA200=%.5f Trend=%.0f Signal=%.0f close[1]=%.5f",
              buf_RSI[1], buf_EMA9[1], buf_WMA45[1], buf_EMA200[1], buf_Trend[1], buf_Signal[1], closeArr[1]);
  PrintFormat("[RsiMom]   last %d bars trend dist: UP=%d DOWN=%d RANGE=%d  (zeroEma200=%d)",
              n, upCount, downCount, rangeCount, zeroEma);
}

#endif // RSIMOM_DIAGNOSTICS_MQH
