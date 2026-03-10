#ifndef EA_ICT_CL__FILTERS_MQH
#define EA_ICT_CL__FILTERS_MQH

/** Returns true if symbol spread in points is within max allowed (or no limit). */
inline bool Filter_MaxSpreadPoints(const string symbol, const double maxSpreadPoints)
{
  if (maxSpreadPoints <= 0) return true;
  const double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (pointSize <= 0.0) return true;
  const double spreadInPoints = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / pointSize;
  return (spreadInPoints <= maxSpreadPoints);
}

#endif
