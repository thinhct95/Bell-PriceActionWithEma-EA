#ifndef EA_ICT_CL__ORDERS_MQH
#define EA_ICT_CL__ORDERS_MQH  // Tránh include trùng

// Module: Orders – chuẩn hóa giá, tạo comment lệnh (magic, fvg_id)

inline double NormalizePrice(const string symbol, const double price)
{
  const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);  // Số chữ số thập phân của symbol
  return NormalizeDouble(price, digits);  // Làm tròn giá theo digits
}

inline string BuildOrderComment(const long magic, const int fvg_id, const string tag = "ICT")
{
  return StringFormat("%s|mg=%I64d|fvg=%d", tag, magic, fvg_id);  // Comment để trace EA + FVG
}

#endif // EA_ICT_CL__ORDERS_MQH

