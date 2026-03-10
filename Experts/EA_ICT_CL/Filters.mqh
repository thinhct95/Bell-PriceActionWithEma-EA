#ifndef EA_ICT_CL__FILTERS_MQH
#define EA_ICT_CL__FILTERS_MQH

// Module: Filters
// Put spread/news/day-of-week/max-trades filters here.

inline bool Filter_MaxSpreadPoints(const string symbol, const double max_spread_points)
{
  if (max_spread_points <= 0) return true;
  const double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (pt <= 0.0) return true;
  const double spread_pts = (SymbolInfoDouble(symbol, SYMBOL_ASK) - SymbolInfoDouble(symbol, SYMBOL_BID)) / pt;
  return (spread_pts <= max_spread_points);
}

#endif // EA_ICT_CL__FILTERS_MQH

