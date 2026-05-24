//+------------------------------------------------------------------+
//| EaState.mqh — State machine tổng: STOP vs SETUP pipeline MSS      |
//+------------------------------------------------------------------+
#ifndef ICT2026_EASTATE_MQH
#define ICT2026_EASTATE_MQH

#include <ICT2026/DailyBias.mqh>
#include <ICT2026/IntradayStructure.mqh>
#include <ICT2026/LowTfApi.mqh>

enum ENUM_ICT_EA_CATEGORY
{
   ICT_EA_CAT_STOP  = 0,
   ICT_EA_CAT_SETUP = 1,
   ICT_EA_CAT_TRADE = 2
};

enum ENUM_ICT_EA_STATE
{
   ICT_EA_STOP_NO_BIAS = 0,
   ICT_EA_STOP_BIAS_RANGE,
   ICT_EA_STOP_INTRADAY_NONE,
   ICT_EA_STOP_BIAS_INTRADAY_MISMATCH,

   ICT_EA_WAIT_FVG_TOUCH = 100,
   ICT_EA_FVG_TOUCHED_WAIT_MSS,
   ICT_EA_MSS_OK_WAIT_M5_FVG,
   ICT_EA_M5_FVG_WAIT_RETRACE,
   ICT_EA_READY_FOR_LIMIT,
   ICT_EA_LIMIT_ORDER_PENDING,
   ICT_EA_ON_TRADE
};

struct IctEaState
{
   ENUM_ICT_EA_CATEGORY category;
   ENUM_ICT_EA_STATE  state;
   ENUM_ICT_MSS_PHASE mssPhase;
   string             detail;

   void Clear()
   {
      category = ICT_EA_CAT_STOP;
      state    = ICT_EA_STOP_NO_BIAS;
      mssPhase = ICT_MSS_IDLE;
      detail   = "";
   }
};

IctEaState g_ictEaState;

string IctEaState_Code(const ENUM_ICT_EA_STATE st)
{
   switch(st)
   {
      case ICT_EA_STOP_NO_BIAS:                 return "STOP_NO_BIAS";
      case ICT_EA_STOP_BIAS_RANGE:              return "STOP_BIAS_RANGE";
      case ICT_EA_STOP_INTRADAY_NONE:           return "STOP_INTRADAY_NONE";
      case ICT_EA_STOP_BIAS_INTRADAY_MISMATCH:  return "STOP_BIAS_INTRADAY_MISMATCH";
      case ICT_EA_WAIT_FVG_TOUCH:               return "WAIT_FVG_TOUCH";
      case ICT_EA_FVG_TOUCHED_WAIT_MSS:         return "FVG_TOUCHED_WAIT_MSS";
      case ICT_EA_MSS_OK_WAIT_M5_FVG:           return "MSS_OK_WAIT_M5_FVG";
      case ICT_EA_M5_FVG_WAIT_RETRACE:          return "M5_FVG_WAIT_RETRACE";
      case ICT_EA_READY_FOR_LIMIT:              return "READY_FOR_LIMIT";
      case ICT_EA_LIMIT_ORDER_PENDING:          return "LIMIT_ORDER_PENDING";
      case ICT_EA_ON_TRADE:                     return "ON_TRADE";
      default:                                  return "UNKNOWN";
   }
}

string IctEaState_TitleVi(const ENUM_ICT_EA_STATE st)
{
   switch(st)
   {
      case ICT_EA_STOP_NO_BIAS:                 return "STOP: chua co Bias";
      case ICT_EA_STOP_BIAS_RANGE:              return "STOP: Bias Range";
      case ICT_EA_STOP_INTRADAY_NONE:           return "STOP: H1 chua ro huong";
      case ICT_EA_STOP_BIAS_INTRADAY_MISMATCH:  return "STOP: Bias vs H1 lech";
      case ICT_EA_WAIT_FVG_TOUCH:               return "Cho retest FVG H1";
      case ICT_EA_FVG_TOUCHED_WAIT_MSS:         return "FVG H1 OK — cho MSS M5";
      case ICT_EA_MSS_OK_WAIT_M5_FVG:           return "MSS OK — cho M5 FVG";
      case ICT_EA_M5_FVG_WAIT_RETRACE:          return "M5 FVG — cho hoi entry";
      case ICT_EA_READY_FOR_LIMIT:              return "San sang dat limit";
      case ICT_EA_LIMIT_ORDER_PENDING:          return "Limit pending";
      case ICT_EA_ON_TRADE:                     return "Dang giu lenh";
      default:                                  return "Khong xac dinh";
   }
}

string IctEaState_CategoryText(const ENUM_ICT_EA_CATEGORY cat)
{
   switch(cat)
   {
      case ICT_EA_CAT_SETUP: return "SETUP";
      case ICT_EA_CAT_TRADE: return "TRADE";
      default:               return "STOP";
   }
}

bool IctEaState_HasOpenPosition(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMssMagic)
         return true;
   }
   return false;
}

bool IctEaState_HasPendingLimit(const string sym, const ulong ticketHint = 0)
{
   if(ticketHint > 0 && OrderSelect(ticketHint))
   {
      const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT)
         return true;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != sym)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMssMagic)
         continue;
      const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT)
         return true;
   }
   return false;
}

ENUM_ICT_EA_STATE IctEaState_FromMssPhase(const ENUM_ICT_MSS_PHASE ph)
{
   switch(ph)
   {
      case ICT_MSS_H1_TOUCH:    return ICT_EA_FVG_TOUCHED_WAIT_MSS;
      case ICT_MSS_CHOCH:       return ICT_EA_MSS_OK_WAIT_M5_FVG;
      case ICT_MSS_M5_FVG:
      case ICT_MSS_ENTRY_FILL:  return ICT_EA_M5_FVG_WAIT_RETRACE;
      case ICT_MSS_READY:       return ICT_EA_READY_FOR_LIMIT;
      default:                  return ICT_EA_WAIT_FVG_TOUCH;
   }
}

void IctEaState_Refresh(const string sym)
{
   g_ictEaState.mssPhase = g_ictLowTf.mss.phase;
   g_ictEaState.detail   = g_ictLowTf.mss.displayReason;

   if(IctEaState_HasOpenPosition(sym))
   {
      g_ictEaState.category = ICT_EA_CAT_TRADE;
      g_ictEaState.state    = ICT_EA_ON_TRADE;
      if(StringLen(g_ictEaState.detail) == 0)
         g_ictEaState.detail = "Position active";
      return;
   }

   if(IctEaState_HasPendingLimit(sym, g_ictLowTf.mss.pendingTicket))
   {
      g_ictEaState.category = ICT_EA_CAT_TRADE;
      g_ictEaState.state    = ICT_EA_LIMIT_ORDER_PENDING;
      if(StringLen(g_ictEaState.detail) == 0 && g_ictLowTf.mss.pendingEntry > 0.0)
         g_ictEaState.detail = StringFormat("Limit @ %.2f", g_ictLowTf.mss.pendingEntry);
      return;
   }

   if(!g_ictIntraday.isAllowTrade)
   {
      g_ictEaState.category = ICT_EA_CAT_STOP;

      if(g_ictDailyBias.bias == ICT_BIAS_NONE)
         g_ictEaState.state = ICT_EA_STOP_NO_BIAS;
      else if(g_ictDailyBias.bias == ICT_BIAS_RANGE)
         g_ictEaState.state = ICT_EA_STOP_BIAS_RANGE;
      else if(g_ictIntraday.trend == ICT_TREND_NONE)
         g_ictEaState.state = ICT_EA_STOP_INTRADAY_NONE;
      else
         g_ictEaState.state = ICT_EA_STOP_BIAS_INTRADAY_MISMATCH;

      if(StringLen(g_ictEaState.detail) == 0)
      {
         g_ictEaState.detail = StringFormat("Bias %s | H1 %s",
                              IctBiasDisplayShort(g_ictDailyBias.bias),
                              IctTrendDisplayShort(g_ictIntraday.trend));
      }
      return;
   }

   g_ictEaState.category = ICT_EA_CAT_SETUP;
   g_ictEaState.state    = IctEaState_FromMssPhase(g_ictLowTf.mss.phase);

   if(g_ictEaState.state == ICT_EA_READY_FOR_LIMIT && !InpMssTradeEnabled)
      g_ictEaState.detail = StringFormat("%s | trade OFF", g_ictEaState.detail);
}

void IctEaState_Get(IctEaState &out) { out = g_ictEaState; }

ENUM_ICT_EA_STATE IctEaState_Current() { return g_ictEaState.state; }

bool IctEaState_IsSetupActive() { return g_ictEaState.category == ICT_EA_CAT_SETUP; }

bool IctEaState_IsStop() { return g_ictEaState.category == ICT_EA_CAT_STOP; }

#endif
