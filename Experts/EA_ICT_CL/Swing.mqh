#ifndef EA_ICT_CL__SWING_MQH
#define EA_ICT_CL__SWING_MQH  // Tránh include trùng

// Module: Swing – tìm bar shift theo time, swing high/low, quét cấu trúc swing, suy trend

//+------------------------------------------------------------------+
//|  MyBarShift: tìm chỉ số bar (series) ứng với thời gian time       |
//+------------------------------------------------------------------+
inline int MyBarShift(string symbol, ENUM_TIMEFRAMES tf, datetime time, bool exact = false)
{
  datetime arr[];
  int maxCopy = MathMin(Bars(symbol, tf), 5000);  // Giới hạn copy
  int copied = CopyTime(symbol, tf, 0, maxCopy, arr);
  if (copied <= 0) return -1;

  for (int i = copied - 1; i >= 0; i--)  // Duyệt từ bar cũ → mới
  {
    if (arr[i] <= time)
      return copied - 1 - i;  // Index trong series (0 = mới nhất)
  }
  return exact ? -1 : copied - 1;  // exact: không tìm thấy = -1; không exact: trả về bar xa nhất
}

inline bool IsSwingHighAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iHigh(_Symbol, tf, i);  // High tại bar i
  for (int k = 1; k <= InpSwingRange; k++)  // So với InpSwingRange bar mỗi bên
    if (iHigh(_Symbol, tf, i-k) >= p || iHigh(_Symbol, tf, i+k) >= p) return false;  // Có high cao hơn → không phải swing high
  return true;
}

inline bool IsSwingLowAt(ENUM_TIMEFRAMES tf, int i)
{
  double p = iLow(_Symbol, tf, i);
  for (int k = 1; k <= InpSwingRange; k++)
    if (iLow(_Symbol, tf, i-k) <= p || iLow(_Symbol, tf, i+k) <= p) return false;
  return true;
}

inline bool ScanSwingStructure(
  ENUM_TIMEFRAMES tf, int lookback,
  double &h0, double &h1, int &idxH0, int &idxH1,
  double &l0, double &l1, int &idxL0, int &idxL1)
{
  int maxBar = MathMin(lookback, Bars(_Symbol, tf) - InpSwingRange - 2);  // Giới hạn quét
  double highs[2]; int hiIdx[2]; int hc = 0;  // 2 swing high gần nhất
  double lows [2]; int loIdx[2]; int lc = 0;  // 2 swing low gần nhất

  for (int i = InpSwingRange + 1; i <= maxBar; i++)  // Từ bar gần hiện tại trở lại
  {
    if (hc < 2 && IsSwingHighAt(tf, i)) { highs[hc] = iHigh(_Symbol, tf, i); hiIdx[hc] = i; hc++; }
    if (lc < 2 && IsSwingLowAt (tf, i)) { lows [lc] = iLow (_Symbol, tf, i); loIdx[lc] = i; lc++; }
    if (hc == 2 && lc == 2) break;  // Đủ 2 high + 2 low thì dừng
  }
  if (hc < 2 || lc < 2) return false;  // Không đủ swing

  h0 = highs[0]; idxH0 = hiIdx[0];  // h0 = swing high gần nhất (index nhỏ)
  h1 = highs[1]; idxH1 = hiIdx[1];  // h1 = swing high cũ hơn
  l0 = lows [0]; idxL0 = loIdx[0];
  l1 = lows [1]; idxL1 = loIdx[1];
  return true;
}

inline void ResolveTrendFromSwings(
  ENUM_TIMEFRAMES tf,
  double h0, double h1, double l0, double l1,
  MarketDir &trend, double &keyLevel)
{
  double c1 = iClose(_Symbol, tf, 1);  // Close bar 1 (gần nhất đã đóng)
  if      (h0 > h1 && l0 > l1 && c1 > l0) { trend = DIR_UP;   keyLevel = l0; }   // HH + HL, giá trên L0 → uptrend
  else if (h0 < h1 && l0 < l1 && c1 < h0) { trend = DIR_DOWN; keyLevel = h0; }   // LH + LL, giá dưới H0 → downtrend
  else                                     { trend = DIR_NONE; keyLevel = 0; }   // Không rõ
}

#endif // EA_ICT_CL__SWING_MQH

