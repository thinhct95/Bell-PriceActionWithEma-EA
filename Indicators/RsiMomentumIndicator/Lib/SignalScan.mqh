//+------------------------------------------------------------------+
//| SignalScan.mqh                                                   |
//| Vòng for phát hiện giao cắt RSI vs WMA45, áp 5 filter:           |
//|   1. crossUp / crossDown                                          |
//|   2. trend EMA200 (N nến liên tiếp cùng phía)                     |
//|   3. EMA9 vs WMA45 (persist N bars)                               |
//|   4. slope EMA9 cùng chiều tín hiệu                               |
//|   5. RSI không ở extreme                                          |
//| Sau đó vẽ mũi tên BUY/SELL lên chart.                             |
//+------------------------------------------------------------------+
#ifndef RSIMOM_SIGNALSCAN_MQH
#define RSIMOM_SIGNALSCAN_MQH

//+------------------------------------------------------------------+
//| Quét signal từ bar `barsToScan` về bar 1, ghi vào buf_Signal /    |
//| buf_Trend / buf_EMA200 và tạo OBJ_ARROW khi có tín hiệu hợp lệ.   |
//+------------------------------------------------------------------+
void SignalScan_Run(const int barsToScan,
                    const int rates_total,
                    const int need,
                    const int trendN,
                    const datetime &timeArr[],
                    const double   &highArr[],
                    const double   &lowArr[],
                    const double   &closeArr[],
                    const double   &ema200Arr[])
{
  const double arrowOffset = InpArrowOffsetPts * _Point;

  // Reset buffer cho bar 0 (đang hình thành) — đặt giá trị mặc định
  buf_Signal[0] = 0.0;
  buf_Trend [0] = 0.0;
  buf_EMA200[0] = (need > 0) ? ema200Arr[0] : 0.0;

  // Phát hiện giao cắt RSI vs WMA45, chỉ vẽ khi khớp với trend EMA200
  for (int i = barsToScan; i >= 1; i--)
  {
    buf_Signal[i] = 0.0; // mặc định: không có tín hiệu
    buf_Trend [i] = 0.0;
    buf_EMA200[i] = (i < need) ? ema200Arr[i] : 0.0;

    if (i + 1 >= rates_total)  continue;
    if (i + trendN >= need)    continue; // ngoài phạm vi mảng cục bộ
    if (ema200Arr[i] <= 0.0)   continue; // EMA200 chưa tính đủ bars

    // Lọc theo trend EMA200: cần N nến LIÊN TIẾP gần nhất đều đóng cùng phía
    // Quét từ nến tín hiệu i → i+N-1 (tính LUÔN, kể cả khi không có cross)
    bool trendUp   = true;
    bool trendDown = true;
    for (int k = 0; k < trendN; k++)
    {
      const int idx = i + k;
      if (ema200Arr[idx] <= 0.0) { trendUp = false; trendDown = false; break; }
      if (closeArr[idx] <= ema200Arr[idx]) trendUp   = false;
      if (closeArr[idx] >= ema200Arr[idx]) trendDown = false;
      if (!trendUp && !trendDown) break;
    }
    buf_Trend[i] = trendUp ? 1.0 : (trendDown ? -1.0 : 0.0);

    const bool crossUp   = (buf_RSI[i+1] <= buf_WMA45[i+1]) && (buf_RSI[i] > buf_WMA45[i]);
    const bool crossDown = (buf_RSI[i+1] >= buf_WMA45[i+1]) && (buf_RSI[i] < buf_WMA45[i]);

    if (!crossUp && !crossDown) continue;

    // Vị trí EMA9 vs WMA45 tại nến signal — "lực mua/bán mới bắt đầu chiếm ưu thế"
    //   BUY:  EMA9 vẫn dưới WMA45 (lực mua chỉ vừa nhú lên qua RSI cross)
    //   SELL: EMA9 vẫn trên WMA45 (lực bán chỉ vừa nhú xuống)
    const bool ema9BelowWma = (buf_EMA9[i] < buf_WMA45[i]);
    const bool ema9AboveWma = (buf_EMA9[i] > buf_WMA45[i]);

    // ── Filter PERSIST (chống nhiễu) ─────────────────────────────────────
    // Yêu cầu EMA9 ở CÙNG PHÍA WMA45 trong N nến liên tiếp (i, i+1, …, i+N-1)
    //   - Tránh trường hợp EMA9 cắt lên/xuống WMA45 liên tục (lực không rõ)
    //   - Mặc định N=5: EMA9 phải đã ổn định 1 phía ít nhất 5 bar
    //   - N <= 1 → tắt filter (chỉ check tại bar signal như cũ)
    const int persistN = MathMax(1, InpEma9PersistBars);
    bool ema9PersistBelow = ema9BelowWma;
    bool ema9PersistAbove = ema9AboveWma;
    if (persistN > 1)
    {
      // Cần thêm (persistN - 1) bar trước nến signal cùng phía
      // Đảm bảo không vượt phạm vi buffer (i + persistN - 1 < rates_total)
      if (i + persistN - 1 >= rates_total)
      {
        ema9PersistBelow = false;
        ema9PersistAbove = false;
      }
      else
      {
        for (int k = 1; k < persistN; k++)
        {
          if (buf_EMA9[i+k] >= buf_WMA45[i+k]) ema9PersistBelow = false;
          if (buf_EMA9[i+k] <= buf_WMA45[i+k]) ema9PersistAbove = false;
          if (!ema9PersistBelow && !ema9PersistAbove) break;
        }
      }
    }

    // Slope EMA9 — phải đang hướng cùng chiều với tín hiệu
    const bool ema9SlopeUp   = (buf_EMA9[i] > buf_EMA9[i+1]);
    const bool ema9SlopeDown = (buf_EMA9[i] < buf_EMA9[i+1]);

    // Lọc RSI extreme — không mua đỉnh, không bán đáy
    //   RSI ≥ overbought  → bỏ tín hiệu BUY
    //   RSI ≤ oversold    → bỏ tín hiệu SELL
    const bool rsiOkBuy  = (buf_RSI[i] < InpRSIOverbought);
    const bool rsiOkSell = (buf_RSI[i] > InpRSIOversold);

    // Tín hiệu hợp lệ khi đủ 6 điều kiện (thêm filter PERSIST)
    const bool validBuy  = crossUp   && trendUp   && ema9PersistBelow && ema9SlopeUp   && rsiOkBuy;
    const bool validSell = crossDown && trendDown && ema9PersistAbove && ema9SlopeDown && rsiOkSell;

    if (!validBuy && !validSell) continue;

    // Dùng timestamp làm tên duy nhất để tránh tạo trùng object
    const string arrowName = OBJ_PREFIX + "CR_" + IntegerToString((int)timeArr[i]);
    if (ObjectFind(0, arrowName) >= 0) continue;

    if (validBuy)
    {
      buf_Signal[i] = 1.0; // ghi tín hiệu cho EA đọc qua iCustom

      // Mũi tên lên (↑) đặt dưới đáy nến — tín hiệu BUY trong uptrend
      // ANCHOR_TOP: điểm anchor là đỉnh icon → arrow nằm xuôi xuống dưới price
      // → tip ↑ ở phía trên, sát đáy nến (cách lowArr[i] một khoảng arrowOffset)
      const double price = lowArr[i] - arrowOffset;
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE,  233);
      ObjectSetInteger(0, arrowName, OBJPROP_ANCHOR,     ANCHOR_TOP);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR,      InpArrowUpColor);
      ObjectSetInteger(0, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, arrowName, OBJPROP_TOOLTIP,
                       StringFormat("BUY signal\n%s\nRSI=%.2f  EMA9=%.2f (slope+)  WMA45=%.2f\nEMA200=%.5f (Uptrend)\nEMA9 below WMA45 ≥ %d bars",
                                    TimeToString(timeArr[i], TIME_DATE|TIME_MINUTES),
                                    buf_RSI[i], buf_EMA9[i], buf_WMA45[i], ema200Arr[i], persistN));
    }
    else // validSell
    {
      buf_Signal[i] = -1.0; // ghi tín hiệu cho EA đọc qua iCustom

      // Mũi tên xuống (↓) đặt trên đỉnh nến — tín hiệu SELL trong downtrend
      // ANCHOR_BOTTOM: điểm anchor là đáy icon → arrow nằm ngược lên trên price
      // → tip ↓ ở phía dưới, sát đỉnh nến (cách highArr[i] một khoảng arrowOffset)
      const double price = highArr[i] + arrowOffset;
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE,  234);
      ObjectSetInteger(0, arrowName, OBJPROP_ANCHOR,     ANCHOR_BOTTOM);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR,      InpArrowDownColor);
      ObjectSetInteger(0, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, arrowName, OBJPROP_TOOLTIP,
                       StringFormat("SELL signal\n%s\nRSI=%.2f  EMA9=%.2f (slope-)  WMA45=%.2f\nEMA200=%.5f (Downtrend)\nEMA9 above WMA45 ≥ %d bars",
                                    TimeToString(timeArr[i], TIME_DATE|TIME_MINUTES),
                                    buf_RSI[i], buf_EMA9[i], buf_WMA45[i], ema200Arr[i], persistN));
    }
  }
}

#endif // RSIMOM_SIGNALSCAN_MQH
