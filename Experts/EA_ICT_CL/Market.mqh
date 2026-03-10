#ifndef EA_ICT_CL__MARKET_MQH
#define EA_ICT_CL__MARKET_MQH  // Tránh include trùng

// Module: Market – giá, point, spread, điều kiện trade

inline double GetBid(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_BID); }   // Giá bid
inline double GetAsk(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_ASK); }   // Giá ask
inline double GetPoint(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_POINT); }  // Kích thước 1 point
inline int    GetDigits(const string symbol) { return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS); }  // Số chữ số thập phân

inline double GetSpreadPoints(const string symbol)
{
  const double bid = GetBid(symbol);   // Lấy bid
  const double ask = GetAsk(symbol);   // Lấy ask
  const double pt  = GetPoint(symbol); // Lấy point
  if (pt <= 0.0) return 0.0;          // Tránh chia 0
  return (ask - bid) / pt;             // Spread quy đổi ra số point
}

inline bool IsTradeAllowedNow(const string symbol)
{
  if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;   // Terminal có cho trade không
  if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;             // EA có quyền trade không
  if (!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)) return false;  // Symbol có cho trade không
  return true;  // Đủ điều kiện
}

#endif // EA_ICT_CL__MARKET_MQH

