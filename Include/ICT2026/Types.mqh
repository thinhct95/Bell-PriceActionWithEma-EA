//+------------------------------------------------------------------+
//| Types.mqh — ICT 2026 data model                                  |
//+------------------------------------------------------------------+
#ifndef ICT2026_TYPES_MQH
#define ICT2026_TYPES_MQH

enum ENUM_ICT_BIAS
{
   ICT_BIAS_NONE   = 0,
   ICT_BIAS_BULL   = 1,
   ICT_BIAS_BEAR   = -1,
   ICT_BIAS_RANGE  = 2
};

enum ENUM_ICT_STRUCT
{
   ICT_STRUCT_NONE = 0,
   ICT_STRUCT_BULL = 1,
   ICT_STRUCT_BEAR = -1
};

enum ENUM_ICT_HTF_BIAS
{
   ICT_HTF_NONE    = 0,
   ICT_HTF_UP      = 1,
   ICT_HTF_DOWN    = -1,
   ICT_HTF_SIDEWAY = 2
};

// BOS = Continue | CHoCH = Reversal
enum ENUM_ICT_MS_EVENT
{
   ICT_MS_NONE  = 0,
   ICT_MS_BOS   = 1,
   ICT_MS_CHOCH = 2
};

enum ENUM_ICT_TREND
{
   ICT_TREND_NONE = 0,
   ICT_TREND_UP   = 1,
   ICT_TREND_DOWN = -1
};

// Rõ ràng (HH-HL/LH-LL) hoặc sớm (sau CHoCH, MS chưa rõ)
enum ENUM_ICT_TREND_PHASE
{
   ICT_TREND_PHASE_NONE  = 0,
   ICT_TREND_PHASE_CLEAR = 1,
   ICT_TREND_PHASE_EARLY = 2
};

struct IctSwingPoint
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

struct IctSwingSet
{
   IctSwingPoint h0, h1, l0, l1;
   bool          hasH0, hasH1, hasL0, hasL1;

   bool IsComplete() const
   {
      return hasH0 && hasH1 && hasL0 && hasL1;
   }

   void Clear()
   {
      h0.Clear(); h1.Clear(); l0.Clear(); l1.Clear();
      hasH0 = hasH1 = hasL0 = hasL1 = false;
   }
};

struct IctHTFBiasState
{
   ENUM_ICT_HTF_BIAS bias;
   double            rangeHigh;
   double            rangeLow;
   datetime          lastUpdateTime;
};

struct IctDailyBiasState
{
   ENUM_ICT_BIAS         bias;
   ENUM_ICT_TREND_PHASE  biasPhase;
   ENUM_ICT_STRUCT       structural;
   ENUM_ICT_MS_EVENT     lastEvent;
   bool                  fibOk;
   IctSwingSet           swings;
   double                keyLv1;
   double                keyLv2;
   ENUM_ICT_STRUCT       lastClearStructural;
   double                pdh;
   double                pdl;
   double                pdc;
   double                eq;
   IctHTFBiasState       htf;
   datetime              lastBarTime;
   string                reason;
   string                displayReason;
};

struct IctIntradayState
{
   ENUM_ICT_TREND        trend;
   ENUM_ICT_TREND_PHASE  trendPhase;
   ENUM_ICT_STRUCT       structural;
   ENUM_ICT_MS_EVENT     lastEvent;
   IctSwingSet           swings;
   double                keyLv1;
   double                keyLv2;
   ENUM_ICT_STRUCT       lastClearStructural;
   datetime              lastBarTime;
   string                displayReason;
   bool                  isAllowTrade;
};

enum ENUM_ICT_FVG_SIDE
{
   ICT_FVG_NONE = 0,
   ICT_FVG_BULL = 1,
   ICT_FVG_BEAR = -1
};

enum ENUM_ICT_FVG_STATE
{
   ICT_FVG_AVAILABLE = 0,
   ICT_FVG_USED      = 1
};

enum ENUM_ICT_PD_ZONE
{
   ICT_PD_NONE       = 0,
   ICT_PD_PREMIUM    = 1,
   ICT_PD_DISCOUNT   = -1,
   ICT_PD_EQUILIBRIUM = 2
};

enum ENUM_ICT_MSS_PHASE
{
   ICT_MSS_IDLE        = 0,
   ICT_MSS_H1_TOUCH    = 1,   // Đã retest FVG H1 (POI): chạm + lấp ≥ InpMssH1MinFillPct trên H1
   ICT_MSS_CHOCH       = 2,
   ICT_MSS_M5_FVG      = 3,
   ICT_MSS_ENTRY_FILL  = 4,
   ICT_MSS_READY       = 5
};

struct IctFvgZone
{
   ulong               id;
   ENUM_ICT_FVG_SIDE   side;
   ENUM_ICT_FVG_STATE  state;
   ENUM_ICT_PD_ZONE    pdZone;
   ENUM_ICT_PD_ZONE    repPd;
   double              upper;
   double              lower;
   double              pdHigh;
   double              pdLow;
   double              pdEq;
   double              maxFillRatio;
   datetime            createdTime;
   datetime            timeStart;
   datetime            timeEnd;
   datetime            firstTouchTime;
   datetime            fvgUsedTime;
   datetime            expireTime;
   bool                locked;
   datetime            pdRangeStart;
   datetime            pdRangeEnd;
   bool                pdComplete;
   bool                pdSwing1Set;
   bool                mssH1Touch382;

   void Clear()
   {
      id           = 0;
      side         = ICT_FVG_NONE;
      state        = ICT_FVG_AVAILABLE;
      pdZone       = ICT_PD_NONE;
      repPd        = ICT_PD_NONE;
      upper        = 0.0;
      lower        = 0.0;
      pdHigh       = 0.0;
      pdLow        = 0.0;
      pdEq         = 0.0;
      maxFillRatio = 0.0;
      createdTime     = 0;
      timeStart       = 0;
      timeEnd         = 0;
      firstTouchTime  = 0;
      fvgUsedTime     = 0;
      expireTime      = 0;
      locked          = false;
      pdRangeStart    = 0;
      pdRangeEnd      = 0;
      pdComplete      = false;
      pdSwing1Set     = false;
      mssH1Touch382   = false;
   }
};

struct IctMssState
{
   ENUM_ICT_MSS_PHASE phase;
   ulong                h1FvgId;
   datetime             h1TouchTime;
   ulong                m5FvgId;
   double               chochKeyLevel;
   datetime             chochKeyTime;
   datetime             chochTime;
   datetime             m5FvgTime;
   double               slSwingPrice;
   ulong                pendingTicket;
   double               pendingEntry;
   double               pendingSl;
   double               pendingTp;
   string               displayReason;

   void Clear()
   {
      phase         = ICT_MSS_IDLE;
      h1FvgId       = 0;
      h1TouchTime   = 0;
      m5FvgId       = 0;
      chochKeyLevel = 0.0;
      chochKeyTime  = 0;
      chochTime     = 0;
      m5FvgTime     = 0;
      slSwingPrice  = 0.0;
      pendingTicket = 0;
      pendingEntry  = 0.0;
      pendingSl     = 0.0;
      pendingTp     = 0.0;
      displayReason = "";
   }
};

struct IctLowTfState
{
   datetime lastBarTime;
   datetime lastConfirmBarTime;
   int      activeCount;
   int      availableCount;
   int      confirmFvgCount;
   string   displayReason;
   IctMssState mss;
};

#endif
