#ifndef RSI_FORCE_STATE_EA__STATE_MQH
#define RSI_FORCE_STATE_EA__STATE_MQH

// ============================================================
// State machine enums + lightweight value types (no globals)
// ============================================================

enum EAState
{
  STATE_NO_TRADE      = 0, // khong co setup
  STATE_WATCHING      = 1, // co pullback hop le, cho trigger
  STATE_PENDING_ORDER = 2, // da dat limit, cho khop
  STATE_IN_TRADE      = 3  // da khop, dang quan ly position
};

enum TrendDirection
{
  TREND_NONE =  0,
  TREND_UP   = +1,
  TREND_DOWN = -1
};

// Snapshot of an entry plan computed at the signal bar.
// All prices are already normalized to broker digits.
struct SignalSnapshot
{
  datetime signalBarTime;     // open time of the signal bar
  int      direction;         // +1 buy, -1 sell
  double   entryPrice;
  double   stopLossPrice;
  double   takeProfitPrice;
  double   initialRiskPrice;  // |entry - SL| in price units
};

// Track a live pending limit order.
struct PendingContext
{
  ulong          orderTicket;
  int            barsSincePlaced;
  SignalSnapshot plan;
};

// Track an open position created from a filled pending order.
struct TradeContext
{
  bool           isActive;
  ulong          positionTicket;
  bool           partialClosedDone; // true after 1.5R partial + BE move
  SignalSnapshot plan;
};

#endif
