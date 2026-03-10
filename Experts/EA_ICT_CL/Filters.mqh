#ifndef EA_ICT_CL__FILTERS_MQH
#define EA_ICT_CL__FILTERS_MQH  // Tránh include trùng

// Module: Filters – lọc spread (có thể mở rộng news, max trades...)

inline bool Filter_MaxSpreadPoints(const string symbol, const double max_spread_points)
{
  if (max_spread_points <= 0) return true;  // Không giới hạn → luôn pass
  const double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (pt <= 0.0) return true;  // Point lỗi → bỏ qua check
  const double spread_pts = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / pt;  // Spread theo point
  return (spread_pts <= max_spread_points);  // Pass khi spread <= ngưỡng
}

#endif // EA_ICT_CL__FILTERS_MQH

