#ifndef EA_ICT_CL__STATE_MACHINE_MQH
#define EA_ICT_CL__STATE_MACHINE_MQH

/** Transitions EA state to next and optionally logs. */
inline void TransitionTo(EAState nextState)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s", EnumToString(g_State), EnumToString(nextState));
  g_State = nextState;
}

/** Resets to IDLE, clears active FVG, trade bar, pending ticket and order plan. */
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

/** Idle: picks best active FVG and transitions to WAIT_TOUCH or WAIT_TRIGGER. */
inline void OnStateIdle()
{
  int bestFvgIndex = GetBestActiveFVGIdx();
  if (bestFvgIndex < 0) return;
  g_ActiveFVGIdx = bestFvgIndex;
  if (InpDebugLog)
    PrintFormat("[ACTIVE FVG] #%d %s [%.5f–%.5f] %s",
      g_FVGPool[bestFvgIndex].id, EnumToString(g_FVGPool[bestFvgIndex].direction),
      g_FVGPool[bestFvgIndex].low, g_FVGPool[bestFvgIndex].high, EnumToString(g_FVGPool[bestFvgIndex].status));
  TransitionTo(g_FVGPool[bestFvgIndex].status == FVG_TOUCHED ? EA_WAIT_TRIGGER : EA_WAIT_TOUCH);
}

/** WaitTouch: checks active FVG still valid, optionally switches to better FVG. */
inline void OnStateWaitTouch()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int activeIndex = g_ActiveFVGIdx;

  if (g_FVGPool[activeIndex].status == FVG_USED)
    { ResetToIdle(StringFormat("FVG #%d broken/expired", g_FVGPool[activeIndex].id)); return; }
  if (g_FVGPool[activeIndex].status == FVG_TOUCHED)
    { TransitionTo(EA_WAIT_TRIGGER); return; }

  int betterIndex = GetBestActiveFVGIdx();
  if (betterIndex >= 0 && betterIndex != activeIndex)
  {
    bool isBetterTouched = (g_FVGPool[betterIndex].status == FVG_TOUCHED);
    bool isBetterNewer   = (g_FVGPool[betterIndex].createdTime > g_FVGPool[activeIndex].createdTime);
    if (isBetterTouched || isBetterNewer)
    {
      if (InpDebugLog)
        PrintFormat("[SWITCH] FVG #%d → #%d", g_FVGPool[activeIndex].id, g_FVGPool[betterIndex].id);
      g_ActiveFVGIdx = betterIndex;
      if (isBetterTouched) TransitionTo(EA_WAIT_TRIGGER);
    }
  }
}

/** WaitTrigger: on FVG usedCase==2 builds order plan, sends limit order, goes IN_TRADE or resets. */
inline void OnStateWaitTrigger()
{
  if (g_ActiveFVGIdx < 0) { ResetToIdle("active lost"); return; }
  int activeIndex = g_ActiveFVGIdx;

  if (g_FVGPool[activeIndex].status == FVG_USED)
  {
    if (g_FVGPool[activeIndex].usedCase == 2)
    {
      if (InpDebugLog)
        PrintFormat("[ENTRY SIGNAL] FVG #%d %s [%.5f–%.5f] | MSS entry=%.5f SL=%.5f",
          g_FVGPool[activeIndex].id, EnumToString(g_FVGPool[activeIndex].direction),
          g_FVGPool[activeIndex].low, g_FVGPool[activeIndex].high,
          g_FVGPool[activeIndex].mssEntry, g_FVGPool[activeIndex].mssSL);

      if (BuildOrderPlan(g_FVGPool[activeIndex].id, g_FVGPool[activeIndex].direction,
                         g_FVGPool[activeIndex].mssEntry, g_FVGPool[activeIndex].mssSL))
      {
        ulong ticket = ExecuteLimitOrder();
        if (ticket > 0)
        {
          g_PendingTicket = ticket;
          g_TradeBarIndex = Bars(_Symbol, InpTriggerTF);
          SaveOrderToHistory(g_FVGPool[activeIndex].mssTime);
          TransitionTo(EA_IN_TRADE);
        }
        else
          ResetToIdle(StringFormat("FVG #%d order failed", g_FVGPool[activeIndex].id));
      }
      else
        ResetToIdle(StringFormat("FVG #%d invalid plan", g_FVGPool[activeIndex].id));
    }
    else
      ResetToIdle(StringFormat("FVG #%d case%d", g_FVGPool[activeIndex].id, g_FVGPool[activeIndex].usedCase));
    return;
  }
  if (g_FVGPool[activeIndex].status == FVG_PENDING) { TransitionTo(EA_WAIT_TOUCH); return; }
}

/** InTrade: tracks pending order fill / cancel / expiry; resets when position closed or order lost. */
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
      bool positionFound = false;
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
        ulong positionTicket = PositionGetTicket(i);
        if (positionTicket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
            && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
          positionFound = true;
          g_PendingTicket = 0;
          if (InpDebugLog) PrintFormat("[TRADE] Filled → position #%llu", positionTicket);
          break;
        }
      }

      if (!positionFound)
      {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());

        bool cancelled = false;
        for (int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
          ulong historyTicket = HistoryOrderGetTicket(i);
          if (historyTicket == g_PendingTicket)
          {
            long orderState = HistoryOrderGetInteger(historyTicket, ORDER_STATE);
            if (orderState == ORDER_STATE_CANCELED || orderState == ORDER_STATE_EXPIRED || orderState == ORDER_STATE_REJECTED)
              cancelled = true;
            break;
          }
        }
        if (cancelled) { CloseActiveOrderRecord(2, 0); ResetToIdle("order cancelled"); return; }

        bool closed = false;
        double closedProfit = 0;
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
          ulong dealTicket = HistoryDealGetTicket(i);
          if (HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagicNumber
              && HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol
              && HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
          {
            closedProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            if (InpDebugLog) PrintFormat("[TRADE] Closed | profit=%.2f", closedProfit);
            closed = true; break;
          }
        }
        if (closed) CloseActiveOrderRecord(closedProfit >= 0 ? 1 : -1, closedProfit);
        else        CloseActiveOrderRecord(2, 0);
        ResetToIdle(closed ? "trade closed" : "order lost");
        return;
      }
    }
    return;
  }

  bool hasPosition = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong positionTicket = PositionGetTicket(i);
    if (positionTicket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
        && PositionGetString(POSITION_SYMBOL) == _Symbol)
    { hasPosition = true; break; }
  }
  if (!hasPosition)
  {
    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    double lastProfit = 0;
    for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
    {
      ulong dt = HistoryDealGetTicket(i);
      if (HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber
          && HistoryDealGetString(dt, DEAL_SYMBOL) == _Symbol
          && HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
        { lastProfit = HistoryDealGetDouble(dt, DEAL_PROFIT); break; }
    }
    CloseActiveOrderRecord(lastProfit >= 0 ? 1 : -1, lastProfit);
    ResetToIdle("position closed");
  }
}

/** Keeps FVG pool up to date regardless of guard state. */
inline void UpdateFVGPool()
{
  UpdateFVGStatuses();
  ScanAndRegisterFVGs();
}

/** Runs state machine: handles current state (entry/exit logic). */
inline void RunStateMachine()
{
  switch (g_State)
  {
    case EA_IDLE:         OnStateIdle();        break;
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;
    case EA_IN_TRADE:     OnStateInTrade();     break;
  }
}

#endif
