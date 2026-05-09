#ifndef RSI_FORCE_STATE_EA__STATE_MACHINE_MQH
#define RSI_FORCE_STATE_EA__STATE_MACHINE_MQH

// ============================================================
// State machine: NO_TRADE -> WATCHING -> PENDING_ORDER -> IN_TRADE
// ============================================================

// Anti-spam guard: at most one trade per pullback. Reset when:
//   - direction-trend flips (UP <-> DOWN)
//   - pending order is cancelled (no actual trade happened)
//   - the open trade fully closes (TP/SL/manual)
bool           g_HasTradedThisPullback = false;
int            g_BarsInWatching        = 0;

// Two trend trackers:
//   g_LastTrend     - exact value last seen (UP / DOWN / NONE), for context
//   g_LastDirTrend  - last DIRECTIONAL value (UP / DOWN). Used to detect a real
//                     directional flip even if the trend briefly went through NONE.
TrendDirection g_LastTrend    = TREND_NONE;
TrendDirection g_LastDirTrend = TREND_NONE;

// ------------------------------------------------------------
// Misc helpers
// ------------------------------------------------------------

void TransitionTo(const EAState nextState)
{
  if (g_State == nextState) return;
  if (InpDebugLog)
    PrintFormat("[STATE] %s -> %s", EnumToString(g_State), EnumToString(nextState));
  g_State = nextState;
}

bool IsNewBar()
{
  static datetime lastBarTime = 0;
  if (g_Bars[0].time == 0)            return false;
  if (g_Bars[0].time == lastBarTime)  return false;
  lastBarTime = g_Bars[0].time;
  return true;
}

// ------------------------------------------------------------
// Trend filter (EMA200 with optional dead-zone + flat guard)
// ------------------------------------------------------------

TrendDirection DetectTrend(const int signalShift)
{
  const double closePrice = g_Bars[signalShift].close;
  const double ema200     = g_EMA200[signalShift];
  const double atr        = g_ATR[signalShift];
  if (ema200 <= 0.0) return TREND_NONE;

  // Dead-zone around EMA200 to avoid noise.
  double bufferPrice = ema200 * (InpTrendBufferPercent / 100.0);
  if (InpUseATRTrendBuffer) bufferPrice = atr * InpTrendBufferATRMult;
  if (bufferPrice <= 0.0)   bufferPrice = 5.0 * _Point;

  // Flat EMA200 guard: skip when EMA200 barely moves between two bars.
  if (InpSkipFlatEMA200)
  {
    const double emaDelta      = MathAbs(g_EMA200[signalShift] - g_EMA200[signalShift + 1]);
    const double flatThreshold = MathMax(_Point, atr * InpFlatEMA_ATRMult);
    if (emaDelta <= flatThreshold) return TREND_NONE;
  }

  if (closePrice > ema200 + bufferPrice) return TREND_UP;
  if (closePrice < ema200 - bufferPrice) return TREND_DOWN;
  return TREND_NONE;
}

// All N RSI values inside [low, high] band -> sideway.
bool IsRSISideway(const int signalShift)
{
  if (!InpUseRSISidewayFilter) return false;
  for (int i = signalShift; i < signalShift + InpSidewayLookbackBars; i++)
  {
    if (g_RSI[i] < InpSidewayRSILow || g_RSI[i] > InpSidewayRSIHigh)
      return false;
  }
  return true;
}

// ------------------------------------------------------------
// Pullback (state NO_TRADE -> WATCHING) and trigger (WATCHING -> PENDING)
// ------------------------------------------------------------

bool IsPullbackInUptrend(const int signalShift)
{
  // RSI < EMA9 < WMA45  AND  all three buffers slope down (current pullback).
  return (g_RSI[signalShift]   <  g_EMA9[signalShift]
       && g_EMA9[signalShift]  <  g_WMA45[signalShift]
       && IsBufferSlopingDown(g_RSI,   signalShift, InpSlopeLookbackBars)
       && IsBufferSlopingDown(g_EMA9,  signalShift, InpSlopeLookbackBars)
       && IsBufferSlopingDown(g_WMA45, signalShift, InpSlopeLookbackBars));
}

bool IsPullbackInDowntrend(const int signalShift)
{
  // RSI > EMA9 > WMA45  AND  all three buffers slope up.
  return (g_RSI[signalShift]   >  g_EMA9[signalShift]
       && g_EMA9[signalShift]  >  g_WMA45[signalShift]
       && IsBufferSlopingUp(g_RSI,   signalShift, InpSlopeLookbackBars)
       && IsBufferSlopingUp(g_EMA9,  signalShift, InpSlopeLookbackBars)
       && IsBufferSlopingUp(g_WMA45, signalShift, InpSlopeLookbackBars));
}

// BUY trigger: RSI just crossed up WMA45 + EMA9 still below WMA45
//              + RSI didn't cross WMA45 in the previous N bars.
bool IsBuyTriggerSignal(const int signalShift)
{
  const bool rsiCrossedUp   = (g_RSI[signalShift + 1] <= g_WMA45[signalShift + 1]
                            && g_RSI[signalShift]     >  g_WMA45[signalShift]);
  const bool ema9StillBelow = (g_EMA9[signalShift] < g_WMA45[signalShift]);
  const bool wasIsolated    = !HasCrossInLastNBars(g_RSI, g_WMA45,
                                                   signalShift + 2,
                                                   InpMinBarsBetweenCrosses);
  return rsiCrossedUp && ema9StillBelow && wasIsolated;
}

// SELL trigger: mirror of BUY.
bool IsSellTriggerSignal(const int signalShift)
{
  const bool rsiCrossedDown = (g_RSI[signalShift + 1] >= g_WMA45[signalShift + 1]
                            && g_RSI[signalShift]     <  g_WMA45[signalShift]);
  const bool ema9StillAbove = (g_EMA9[signalShift] > g_WMA45[signalShift]);
  const bool wasIsolated    = !HasCrossInLastNBars(g_RSI, g_WMA45,
                                                   signalShift + 2,
                                                   InpMinBarsBetweenCrosses);
  return rsiCrossedDown && ema9StillAbove && wasIsolated;
}

// ------------------------------------------------------------
// Build a complete entry plan (entry / SL / TP / direction / risk)
// ------------------------------------------------------------

bool BuildSignalPlan(const int direction, const int signalShift, SignalSnapshot &outPlan)
{
  // Entry = midpoint between signal close and the nearest swing extreme:
  //   BUY  -> midpoint between close and nearest swing low.
  //   SELL -> midpoint between close and nearest swing high.
  const double swingAnchor = FindNearestSwingForEntry(direction, signalShift);
  if (swingAnchor <= 0.0) return false;

  const double closePrice = g_Bars[signalShift].close;
  const double entryPrice = (closePrice + swingAnchor) * 0.5;

  // Sanity: BUY limit must sit below close, SELL limit above close.
  if (direction > 0 && entryPrice >= closePrice) return false;
  if (direction < 0 && entryPrice <= closePrice) return false;

  const double slPrice = ComputeStopLossPrice(direction, signalShift,
                                              entryPrice, g_ATR[signalShift]);
  if (direction > 0 && slPrice >= entryPrice) return false;
  if (direction < 0 && slPrice <= entryPrice) return false;

  const double riskInPrice = MathAbs(entryPrice - slPrice);
  if (riskInPrice <= (2.0 * _Point)) return false;

  outPlan.signalBarTime    = g_Bars[signalShift].time;
  outPlan.direction        = direction;
  outPlan.entryPrice       = NormalizePriceToTick(entryPrice);
  outPlan.stopLossPrice    = NormalizePriceToTick(slPrice);
  outPlan.initialRiskPrice = riskInPrice;
  outPlan.takeProfitPrice  = NormalizePriceToTick((direction > 0)
                                                  ? (entryPrice + InpRiskRewardRatio * riskInPrice)
                                                  : (entryPrice - InpRiskRewardRatio * riskInPrice));
  return true;
}

// ------------------------------------------------------------
// Broker-state synchronization
// ------------------------------------------------------------

void ResetPullbackCycle()
{
  g_HasTradedThisPullback = false;
  g_BarsInWatching        = 0;
}

// Reconcile internal state with the broker:
//   PENDING_ORDER -> IN_TRADE  if a position appears
//   PENDING_ORDER -> NO_TRADE  if order vanished without fill (cancel/reject/expire)
//   IN_TRADE      -> NO_TRADE  if position no longer exists (TP/SL/manual)
// On both NO_TRADE transitions, also clear g_HasTradedThisPullback so the EA
// can take the next pullback opportunity in the same trend.
void SyncStateWithBroker()
{
  ulong posTicket    = 0;
  const bool hasPos     = HasOurOpenPosition(posTicket);
  const bool hasPending = HasOurPendingOrder(g_Pending.orderTicket);

  if (g_State == STATE_PENDING_ORDER)
  {
    if (hasPos)
    {
      g_OpenTrade.isActive          = true;
      g_OpenTrade.positionTicket    = posTicket;
      g_OpenTrade.plan              = g_Pending.plan;
      g_OpenTrade.partialClosedDone = false;
      g_Pending.orderTicket         = 0;
      g_Pending.barsSincePlaced     = 0;
      TransitionTo(STATE_IN_TRADE);
      return;
    }
    if (!hasPending)
    {
      // Pending was cancelled / expired / rejected externally.
      g_Pending.orderTicket     = 0;
      g_Pending.barsSincePlaced = 0;
      g_HasTradedThisPullback   = false; // allow the next setup attempt
      TransitionTo(STATE_NO_TRADE);
    }
  }
  else if (g_State == STATE_IN_TRADE)
  {
    if (!hasPos)
    {
      g_OpenTrade.isActive       = false;
      g_OpenTrade.positionTicket = 0;
      g_HasTradedThisPullback    = false; // trade done -> allow next setup
      TransitionTo(STATE_NO_TRADE);
    }
  }
}

// ------------------------------------------------------------
// Pending order lifecycle on every newly closed bar
// ------------------------------------------------------------

void TickPendingOrderLifecycle(const TrendDirection trendNow)
{
  if (g_State != STATE_PENDING_ORDER || g_Pending.orderTicket == 0) return;

  g_Pending.barsSincePlaced++;

  const bool expired = (g_Pending.barsSincePlaced >= InpPendingMaxAliveBars);

  bool invalidated = false;
  if (InpInvalidateIfCrossBack)
  {
    if (g_Pending.plan.direction > 0)
      invalidated = (trendNow != TREND_UP   || g_RSI[1] < g_WMA45[1]);
    else
      invalidated = (trendNow != TREND_DOWN || g_RSI[1] > g_WMA45[1]);
  }

  if (!expired && !invalidated) return;

  if (CancelPendingOrder(g_Pending))
  {
    if (InpDebugLog)
      PrintFormat("[PENDING] cancelled (%s)", expired ? "expired" : "invalidated");
    g_HasTradedThisPullback = false; // allow next pullback to retry
    TransitionTo(STATE_NO_TRADE);
  }
}

// ------------------------------------------------------------
// Per-state handlers
// ------------------------------------------------------------

void HandleStateNoTrade(const int signalShift, const TrendDirection trendNow)
{
  if (g_HasTradedThisPullback)        return; // anti-spam: wait until reset
  if (IsRSISideway(signalShift))      return; // sideway filter only blocks new setups
  if (trendNow == TREND_NONE)         return; // need a real direction

  if (trendNow == TREND_UP   && IsPullbackInUptrend(signalShift))
  {
    g_BarsInWatching = 0;
    TransitionTo(STATE_WATCHING);
  }
  else if (trendNow == TREND_DOWN && IsPullbackInDowntrend(signalShift))
  {
    g_BarsInWatching = 0;
    TransitionTo(STATE_WATCHING);
  }
}

void HandleStateWatching(const int signalShift, const TrendDirection trendNow)
{
  g_BarsInWatching++;

  // Trend lost while watching -> abandon setup.
  if (trendNow == TREND_NONE)
  {
    TransitionTo(STATE_NO_TRADE);
    return;
  }

  // Watching too long without a trigger -> abandon to avoid stale setups.
  if (g_BarsInWatching > InpWatchingMaxBars)
  {
    if (InpDebugLog) Print("[WATCHING] timed out, back to NO_TRADE");
    TransitionTo(STATE_NO_TRADE);
    return;
  }

  // Try to trigger an entry on this bar.
  SignalSnapshot plan;
  ZeroMemory(plan);
  bool hasSignal = false;

  if (trendNow == TREND_UP   && IsBuyTriggerSignal(signalShift))
    hasSignal = BuildSignalPlan(+1, signalShift, plan);
  else if (trendNow == TREND_DOWN && IsSellTriggerSignal(signalShift))
    hasSignal = BuildSignalPlan(-1, signalShift, plan);

  if (!hasSignal) return;

  if (PlaceLimitOrderFromPlan(plan, g_Pending))
  {
    g_HasTradedThisPullback = true;
    TransitionTo(STATE_PENDING_ORDER);
  }
}

// ------------------------------------------------------------
// Top-level entry point: called once per closed bar
// ------------------------------------------------------------

void RunStateMachine()
{
  const int            signalShift = InpSignalBarShift;
  const TrendDirection trendNow    = DetectTrend(signalShift);

  // Detect a TRUE directional flip (UP <-> DOWN).
  // A short trip through TREND_NONE between two same-direction trends
  // is NOT a flip and must NOT reset the cycle / abandon WATCHING.
  bool dirFlipped = false;
  if (trendNow != TREND_NONE)
  {
    if (g_LastDirTrend != TREND_NONE && g_LastDirTrend != trendNow)
      dirFlipped = true;
    g_LastDirTrend = trendNow;
  }

  if (dirFlipped)
  {
    if (InpDebugLog)
      PrintFormat("[TREND] direction flipped %s -> %s",
                  EnumToString(g_LastTrend), EnumToString(trendNow));
    ResetPullbackCycle();

    if (g_State == STATE_PENDING_ORDER && g_Pending.orderTicket > 0)
    {
      if (CancelPendingOrder(g_Pending))
      {
        if (InpDebugLog) Print("[PENDING] cancelled by trend flip");
        TransitionTo(STATE_NO_TRADE);
      }
    }
    else if (g_State == STATE_WATCHING)
    {
      TransitionTo(STATE_NO_TRADE);
    }
  }

  g_LastTrend = trendNow;

  switch (g_State)
  {
    case STATE_NO_TRADE:      HandleStateNoTrade(signalShift, trendNow);      break;
    case STATE_WATCHING:      HandleStateWatching(signalShift, trendNow);     break;
    case STATE_PENDING_ORDER: TickPendingOrderLifecycle(trendNow);            break;
    case STATE_IN_TRADE:      /* tick-level handler does the work */          break;
  }
}

#endif
