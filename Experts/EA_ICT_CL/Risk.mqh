#ifndef EA_ICT_CL__RISK_MQH
#define EA_ICT_CL__RISK_MQH

// Module: Risk
// Put risk sizing and daily loss logic here.

inline double NormalizeVolume(const string symbol, const double vol)
{
  const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double v = vol;
  if (vstep > 0.0) v = MathFloor(v / vstep) * vstep;
  if (v < vmin) v = vmin;
  if (v > vmax) v = vmax;
  return v;
}

inline double LotsFromRiskMoneyAndSLPoints(const string symbol, const double risk_money, const double sl_points)
{
  if (risk_money <= 0.0) return 0.0;
  if (sl_points <= 0.0) return 0.0;

  double tick_value = 0.0, tick_size = 0.0;
  if (!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return 0.0;
  if (!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size))  return 0.0;
  if (tick_value <= 0.0 || tick_size <= 0.0) return 0.0;

  const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (point <= 0.0) return 0.0;

  // Money per 1 lot per point move:
  const double money_per_point_1lot = tick_value * (point / tick_size);
  if (money_per_point_1lot <= 0.0) return 0.0;

  const double lots = risk_money / (sl_points * money_per_point_1lot);
  return NormalizeVolume(symbol, lots);
}

#endif // EA_ICT_CL__RISK_MQH

