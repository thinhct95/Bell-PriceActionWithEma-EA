#ifndef EA_ICT_CL__STATE_MQH
#define EA_ICT_CL__STATE_MQH

// Module: State
// Core EA types: enums + structs used across all modules.
// Extracted from EA_ICT_CL.mq5 (enums + structs sections).

//====================================================
// ENUMS
//====================================================
enum EAState
{
  EA_IDLE,
  EA_WAIT_TOUCH,
  EA_WAIT_TRIGGER,
  EA_IN_TRADE
};

enum HTFBias    { BIAS_NONE=0, BIAS_UP=1, BIAS_DOWN=-1, BIAS_SIDEWAY=2 };
enum MarketDir  { DIR_NONE=0,  DIR_UP=1,  DIR_DOWN=-1                  };
enum BlockReason
{
  BLOCK_NONE, BLOCK_SESSION, BLOCK_DAILY_LOSS,
  BLOCK_BIAS_MISMATCH, BLOCK_NO_BIAS
};
enum FVGStatus
{
  FVG_PENDING,
  FVG_TOUCHED,
  FVG_USED
};

//====================================================
// STRUCTS
//====================================================
struct BiasContext
{
  HTFBias  bias;
  double   rangeHigh, rangeLow;
  datetime lastBarTime;
};

struct TFTrendContext
{
  MarketDir trend;
  double    h0, h1, l0, l1;
  int       idxH0, idxH1, idxL0, idxL1;
  double    keyLevel;
  datetime  lastBarTime;

  datetime  lastMssTime;
  double    lastMssLevel;
  MarketDir lastMssBreak;
  double    mssSLSwing;
};

struct FVGRecord
{
  int       id;
  FVGStatus status;
  int       usedCase;
  MarketDir direction;
  double    high, low, mid;
  datetime  createdTime;
  datetime  touchTime;
  datetime  usedTime;
  MarketDir triggerTrendAtTouch;

  datetime  mssTime;
  double    mssEntry;
  double    mssSL;
};

struct OrderPlan
{
  bool   valid;
  int    direction;
  double entry, stopLoss, takeProfit, lot;
  int    parentFVGId;
};

struct DailyRiskContext
{
  double   startBalance, currentBalance;
  datetime dayStartTime;
  bool     limitHit;
};

#endif // EA_ICT_CL__STATE_MQH
