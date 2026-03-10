#ifndef EA_ICT_CL__STATE_MACHINE_MQH
#define EA_ICT_CL__STATE_MACHINE_MQH

// Module: StateMachine
// State transitions + handlers + runner.
// Extracted from EA_ICT_CL.mq5 (Sections 4, 9, 10).
// NOTE: Uses EA globals + functions from Signals/Trade modules.
//       Include AFTER Signals_BOS_FVG_OB.mqh and Trade.mqh.

//+------------------------------------------------------------------+
//|  SECTION 4 – STATE MACHINE HELPERS                               |
//+------------------------------------------------------------------+

inline void TransitionTo(EAState next)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s", EnumToString(g_State), EnumToString(next));
  g_State = next;
}

inline void ResetToIdle(string reason = "")
{
  if (InpDebugLog && reason != "")
    PrintFormat("[RESET→IDLE] %s", reason);
  g_ActiveFVGIdx  = -1;
  g_TradeBarIndex = -1;
  g_PendingTicket = 0;
  ZeroMemory(g_OrderPlan);
  TransitionTo(EA_IDLE);
}

//+------------------------------------------------------------------+
//|  SECTION 9 – STATE HANDLERS                                      |
//+------------------------------------------------------------------+

inline void OnStateIdle()
{
  int idx = GetBestActiveFVGIdx();
  if (idx < 0) return;
  g_ActiveFVGIdx = idx;
  if (InpDebugLog)
    PrintFormat("[ACTIVE FVG] #%d %s [%.5f–%.5f] %s",
      g_FVGPool[idx].id, EnumToString(g_FVGPool[idx].direction),
      g_FVGPool[idx].low, g_FVGPool[idx].high, EnumToString(g_FVGPool[idx].status));
  TransitionTo(g_FVGPool[idx].status == FVG_TOUCHED ? EA_WAIT_TRIGGER : EA_WAIT_TOUCH);
}

inline void OnStateWaitTouch()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int ai = g_ActiveFVGIdx;

  if (g_FVGPool[ai].status == FVG_USED)
    { ResetToIdle(StringFormat("FVG #%d broken/expired", g_FVGPool[ai].id)); return; }
  if (g_FVGPool[ai].status == FVG_TOUCHED)
    { TransitionTo(EA_WAIT_TRIGGER); return; }

  int better = GetBestActiveFVGIdx();
  if (better >= 0 && better != ai)
  {
    bool bTouch = (g_FVGPool[better].status == FVG_TOUCHED);
    bool bNewer = (g_FVGPool[better].createdTime > g_FVGPool[ai].createdTime);
    if (bTouch || bNewer)
    {
      if (InpDebugLog)
        PrintFormat("[SWITCH] FVG #%d → #%d", g_FVGPool[ai].id, g_FVGPool[better].id);
      g_ActiveFVGIdx = better;
      if (bTouch) TransitionTo(EA_WAIT_TRIGGER);
    }
  }
}

inline void OnStateWaitTrigger()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int ai = g_ActiveFVGIdx;

  if (g_FVGPool[ai].status == FVG_USED)
  {
    if (g_FVGPool[ai].usedCase == 2)
    {
      if (InpDebugLog)
        PrintFormat("[ENTRY SIGNAL] FVG #%d %s [%.5f–%.5f] | MSS entry=%.5f SL=%.5f",
          g_FVGPool[ai].id, EnumToString(g_FVGPool[ai].direction),
          g_FVGPool[ai].low, g_FVGPool[ai].high,
          g_FVGPool[ai].mssEntry, g_FVGPool[ai].mssSL);

      if (BuildOrderPlan(g_FVGPool[ai].id, g_FVGPool[ai].direction,
                         g_FVGPool[ai].mssEntry, g_FVGPool[ai].mssSL))
      {
        ulong ticket = ExecuteLimitOrder();
        if (ticket > 0)
        {
          g_PendingTicket = ticket;
          g_TradeBarIndex = Bars(_Symbol, InpTriggerTF);
          TransitionTo(EA_IN_TRADE);
        }
        else
          ResetToIdle(StringFormat("FVG #%d order failed", g_FVGPool[ai].id));
      }
      else
        ResetToIdle(StringFormat("FVG #%d invalid plan", g_FVGPool[ai].id));
    }
    else
      ResetToIdle(StringFormat("FVG #%d case%d", g_FVGPool[ai].id, g_FVGPool[ai].usedCase));
    return;
  }
  if (g_FVGPool[ai].status == FVG_PENDING) { TransitionTo(EA_WAIT_TOUCH); return; }
}

inline void OnStateInTrade()
{
  if (g_PendingTicket > 0)
  {
    bool foundPending = false;
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
      if (OrderGetTicket(i) == g_PendingTicket) { foundPending = true; break; }
    }

    if (!foundPending)
    {
      bool posFound = false;
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        ulong pt = PositionGetTicket(i);
        if (pt > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
            && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
          posFound = true;
          g_PendingTicket = 0;
          if (InpDebugLog) PrintFormat("[TRADE] Filled → position #%llu", pt);
          break;
        }
      }

      if (!posFound)
      {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());

        bool cancelled = false;
        for (int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
          ulong ht = HistoryOrderGetTicket(i);
          if (ht == g_PendingTicket)
          {
            long st = HistoryOrderGetInteger(ht, ORDER_STATE);
            if (st == ORDER_STATE_CANCELED || st == ORDER_STATE_EXPIRED || st == ORDER_STATE_REJECTED)
              cancelled = true;
            break;
          }
        }
        if (cancelled) { ResetToIdle("order cancelled"); return; }

        bool closed = false;
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
          ulong dt = HistoryDealGetTicket(i);
          if (HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber
              && HistoryDealGetString(dt, DEAL_SYMBOL) == _Symbol
              && HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
          {
            double profit = HistoryDealGetDouble(dt, DEAL_PROFIT);
            if (InpDebugLog) PrintFormat("[TRADE] Closed | profit=%.2f", profit);
            closed = true; break;
          }
        }
        ResetToIdle(closed ? "trade closed" : "order lost");
        return;
      }
    }
    return;
  }

  bool hasPos = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong pt = PositionGetTicket(i);
    if (pt > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
        && PositionGetString(POSITION_SYMBOL) == _Symbol)
    { hasPos = true; break; }
  }
  if (!hasPos) ResetToIdle("position closed");
}

//+------------------------------------------------------------------+
//|  SECTION 10 – STATE MACHINE RUNNER                               |
//+------------------------------------------------------------------+

inline void RunStateMachine()
{
  UpdateFVGStatuses();
  ScanAndRegisterFVGs();
  switch (g_State)
  {
    case EA_IDLE:         OnStateIdle();        break;
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;
    case EA_IN_TRADE:     OnStateInTrade();     break;
  }
}

#endif // EA_ICT_CL__STATE_MACHINE_MQH
