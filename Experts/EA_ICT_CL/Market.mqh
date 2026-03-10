#ifndef EA_ICT_CL__MARKET_MQH
#define EA_ICT_CL__MARKET_MQH

// Module: Market
// Market/tick/contract-spec helpers live here.

inline double GetBid(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_BID); }
inline double GetAsk(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_ASK); }
inline double GetPoint(const string symbol) { return SymbolInfoDouble(symbol, SYMBOL_POINT); }
inline int    GetDigits(const string symbol) { return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS); }

inline double GetSpreadPoints(const string symbol)
{
  const double bid = GetBid(symbol);
  const double ask = GetAsk(symbol);
  const double pt  = GetPoint(symbol);
  if (pt <= 0.0) return 0.0;
  return (ask - bid) / pt;
}

inline bool IsTradeAllowedNow(const string symbol)
{
  if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
  if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
  if (!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE)) return false;
  return true;
}

#endif // EA_ICT_CL__MARKET_MQH

