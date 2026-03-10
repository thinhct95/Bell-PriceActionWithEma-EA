#ifndef EA_ICT_CL__ORDERS_MQH
#define EA_ICT_CL__ORDERS_MQH

/** Normalizes price to symbol digits. */
inline double NormalizePrice(const string symbol, const double price)
{
  const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  return NormalizeDouble(price, digits);
}

/** Builds order comment string for tracing (magic, FVG id, optional tag). */
inline string BuildOrderComment(const long magic, const int fvgId, const string tag = "ICT")
{
  return StringFormat("%s|mg=%I64d|fvg=%d", tag, magic, fvgId);
}

#endif
