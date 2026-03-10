#ifndef EA_ICT_CL__RISK_MQH
#define EA_ICT_CL__RISK_MQH  // Tránh include trùng

// Module: Risk – chuẩn hóa volume, tính lot từ tiền risk và SL (point)

inline double NormalizeVolume(const string symbol, const double vol)
{
  const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);   // Lot tối thiểu
  const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);   // Lot tối đa
  const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP); // Bước lot
  double v = vol;
  if (vstep > 0.0) v = MathFloor(v / vstep) * vstep;  // Làm tròn xuống theo step
  if (v < vmin) v = vmin;  // Không nhỏ hơn min
  if (v > vmax) v = vmax;  // Không lớn hơn max
  return v;
}

inline double LotsFromRiskMoneyAndSLPoints(const string symbol, const double risk_money, const double sl_points)
{
  if (risk_money <= 0.0) return 0.0;  // Không risk → 0 lot
  if (sl_points <= 0.0) return 0.0;   // SL = 0 → không tính được

  double tick_value = 0.0, tick_size = 0.0;
  if (!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return 0.0;  // Giá trị 1 tick/lot
  if (!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size))  return 0.0;   // Kích thước tick
  if (tick_value <= 0.0 || tick_size <= 0.0) return 0.0;

  const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (point <= 0.0) return 0.0;

  // Tiền mất trên 1 point khi di chuyển 1 lot:
  const double money_per_point_1lot = tick_value * (point / tick_size);
  if (money_per_point_1lot <= 0.0) return 0.0;

  const double lots = risk_money / (sl_points * money_per_point_1lot);  // Lot = risk_money / (sl_points * $/point)
  return NormalizeVolume(symbol, lots);  // Chuẩn hóa theo min/max/step
}

#endif // EA_ICT_CL__RISK_MQH

