#ifndef EA_ICT_CL__ORDERS_MQH
#define EA_ICT_CL__ORDERS_MQH

// Module: Orders
// Helpers for building request fields, normalize price, magic/comment conventions.

inline double NormalizePrice(const string symbol, const double price)
{
  const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  return NormalizeDouble(price, digits);
}

inline string BuildOrderComment(const long magic, const int fvg_id, const string tag = "ICT")
{
  return StringFormat("%s|mg=%I64d|fvg=%d", tag, magic, fvg_id);
}

#endif // EA_ICT_CL__ORDERS_MQH

