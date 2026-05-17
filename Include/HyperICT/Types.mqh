//+------------------------------------------------------------------+
//| Types.mqh — enums & structs (spec §1–1.4)                        |
//+------------------------------------------------------------------+
#ifndef HYPERICT_TYPES_MQH
#define HYPERICT_TYPES_MQH

enum ENUM_STRUCT_BIAS
{
   STRUCT_NONE  = 0,
   STRUCT_BULL  = 1,
   STRUCT_BEAR  = -1
};

enum ENUM_HTF_STATE
{
   HTF_NEUTRAL           = 0,
   HTF_BULL_INCOMPLETE   = 1,
   HTF_BEAR_INCOMPLETE   = 2,
   HTF_BULL_PULLBACK     = 3,
   HTF_BULL_CHOCH        = 4,
   HTF_BULL_CONTINUE     = 5,
   HTF_BEAR_PULLBACK     = 6,
   HTF_BEAR_CHOCH        = 7,
   HTF_BEAR_CONTINUE     = 8
};

enum ENUM_UPDATE_EVENT
{
   UPD_NONE      = 0,
   UPD_CHOCH     = 1,
   UPD_CONTINUE  = 2
};

enum ENUM_UPDATE_PHASE
{
   UPD_PHASE_IDLE          = 0,
   UPD_PHASE_BUILD         = 1,
   UPD_PHASE_CHOCH_RESOLVE = 2
};

enum ENUM_CHOCH_BRANCH
{
   CHOCH_BRANCH_NONE = 0,
   CHOCH_BRANCH_BACK_TO_BULL = 1,
   CHOCH_BRANCH_CONFIRM_BEAR = 2
};

struct SwingPoint
{
   double   price;
   datetime time;
   int      shift;
   void Clear()
   {
      price = 0.0;
      time  = 0;
      shift = -1;
   }
   bool Valid() const { return shift >= 0 && price > 0.0; }
};

struct OrderBlockZone
{
   double   swingPrice;
   double   obHigh;
   double   obLow;
   datetime obTime;
   int      obShift;
   bool     valid;
   void Clear()
   {
      swingPrice = obHigh = obLow = 0.0;
      obTime = 0;
      obShift = -1;
      valid = false;
   }
};

struct KeyLevelPair
{
   double         price;
   OrderBlockZone zone;
};

struct SwingSet
{
   SwingPoint h0, h1, l0, l1;
   bool       hasH0, hasH1, hasL0, hasL1;
   bool       IsComplete() const
   {
      return hasH0 && hasH1 && hasL0 && hasL1;
   }
   void Clear()
   {
      h0.Clear(); h1.Clear(); l0.Clear(); l1.Clear();
      hasH0 = hasH1 = hasL0 = hasL1 = false;
   }
};

struct UpdateContext
{
   ENUM_UPDATE_EVENT   event;
   ENUM_UPDATE_PHASE   phase;
   ENUM_CHOCH_BRANCH   chochBranch;
   SwingPoint          newH0;
   SwingPoint          newL0;
   SwingPoint          newL02;
   bool                newH0Locked;
   bool                newLLocked;
   bool                case1TrackingH0;
   void Clear()
   {
      event = UPD_NONE;
      phase = UPD_PHASE_IDLE;
      chochBranch = CHOCH_BRANCH_NONE;
      newH0.Clear(); newL0.Clear(); newL02.Clear();
      newH0Locked = newLLocked = false;
      case1TrackingH0 = false;
   }
};

struct HtfContext
{
   string            symbol;
   ENUM_TIMEFRAMES   htf;
   SwingSet          swings;
   ENUM_STRUCT_BIAS  structBias;
   bool              fibOk;
   KeyLevelPair      keyLv1;
   KeyLevelPair      keyLv2;
   ENUM_HTF_STATE    state;
   UpdateContext     update;
   datetime          lockedAt;
   datetime          lastHtfBar;
   bool              snapshotReady;
};

#endif // HYPERICT_TYPES_MQH
