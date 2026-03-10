#ifndef EA_ICT_CL__RISK_MQH
#define EA_ICT_CL__RISK_MQH

/** Normalizes volume to symbol min/max/step. */
inline double NormalizeVolume(const string symbol, const double vol)
{
  const double minVol  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  const double maxVol  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
  const double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double v = vol;
  if (stepVol > 0.0) v = MathFloor(v / stepVol) * stepVol;
  if (v < minVol) v = minVol;
  if (v > maxVol) v = maxVol;
  return v;
}

/** Computes lot size from risk money and SL distance in points. */
inline double LotsFromRiskMoneyAndSLPoints(const string symbol, const double riskMoney, const double slPoints)
{
  if (riskMoney <= 0.0) return 0.0;
  if (slPoints <= 0.0) return 0.0;

  double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  if (tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

  const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (point <= 0.0) return 0.0;

  const double moneyPerPointPerLot = tickValue * (point / tickSize);
  if (moneyPerPointPerLot <= 0.0) return 0.0;

  const double lots = riskMoney / (slPoints * moneyPerPointPerLot);
  return NormalizeVolume(symbol, lots);
}

#endif
