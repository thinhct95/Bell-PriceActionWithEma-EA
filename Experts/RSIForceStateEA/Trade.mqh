#ifndef RSI_FORCE_STATE_EA__TRADE_MQH
#define RSI_FORCE_STATE_EA__TRADE_MQH

#include <Trade/Trade.mqh>

// CTrade wrapper used for all order/position operations.
// Defaults (magic, deviation) are set once in InitTradeOps() at OnInit.
CTrade g_TradeOps;

// ------------------------------------------------------------
// Lifecycle
// ------------------------------------------------------------

void InitTradeOps()
{
  g_TradeOps.SetExpertMagicNumber(InpMagicNumber);
  g_TradeOps.SetDeviationInPoints(10);
  g_TradeOps.SetTypeFillingBySymbol(_Symbol);
}

// ------------------------------------------------------------
// Symbol primitives
// ------------------------------------------------------------

double NormalizePriceToTick(const double price)
{
  return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeVolumeToBroker(const double rawVolume)
{
  const double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  const double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (volStep <= 0.0) return 0.0;
  double v = MathFloor(rawVolume / volStep) * volStep;
  v = MathMax(v, volMin);
  v = MathMin(v, volMax);
  return NormalizeDouble(v, 2);
}

double GetStopsLevelPrice()
{
  // Broker minimum distance for SL/TP/limit price from market.
  const long stopsLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  return (double)stopsLevelPoints * _Point;
}

// Position sizing from fixed % of balance and price distance entry->SL.
double CalcLotsForRisk(const double entryPrice, const double stopLossPrice)
{
  const double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
  const double riskMoney   = balance * (InpRiskPercent / 100.0);
  const double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  const double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  const double slDistance  = MathAbs(entryPrice - stopLossPrice);
  if (slDistance <= 0.0 || tickValue <= 0.0 || tickSize <= 0.0) return 0.0;
  const double moneyPerLot = (slDistance / tickSize) * tickValue;
  if (moneyPerLot <= 0.0) return 0.0;
  return NormalizeVolumeToBroker(riskMoney / moneyPerLot);
}

// ------------------------------------------------------------
// Swing helpers (used both for entry anchor and SL anchor)
// ------------------------------------------------------------

// Returns the raw extreme price of the nearest swing (no buffer added).
// Used to compute the entry midpoint = (close + swingExtreme) / 2.
double FindNearestSwingForEntry(const int direction, const int signalShift)
{
  const int startShift = signalShift + 1;
  const int lookback   = MathMax(5, InpSwingLookbackBars);

  if (direction > 0)
  {
    const int swingIdx = iLowest(_Symbol, _Period, MODE_LOW, lookback, startShift);
    if (swingIdx <= 0) return 0.0;
    return g_Bars[swingIdx].low;
  }

  const int swingIdx = iHighest(_Symbol, _Period, MODE_HIGH, lookback, startShift);
  if (swingIdx <= 0) return 0.0;
  return g_Bars[swingIdx].high;
}

// Returns the SL price anchored to the nearest swing extreme + safety buffer.
double FindNearestSwingForSL(const int direction, const int signalShift)
{
  const int startShift = signalShift + 1;
  const int lookback   = MathMax(5, InpSwingLookbackBars);

  if (direction > 0)
  {
    const int swingIdx = iLowest(_Symbol, _Period, MODE_LOW, lookback, startShift);
    if (swingIdx <= 0) return 0.0;
    return g_Bars[swingIdx].low - (InpSL_SwingBufferPoints * _Point);
  }

  const int swingIdx = iHighest(_Symbol, _Period, MODE_HIGH, lookback, startShift);
  if (swingIdx <= 0) return 0.0;
  return g_Bars[swingIdx].high + (InpSL_SwingBufferPoints * _Point);
}

// Compose final SL price honoring InpStopLossMode.
double ComputeStopLossPrice(const int direction, const int signalShift,
                            const double entryPrice, const double atrValue)
{
  const double swingSL = FindNearestSwingForSL(direction, signalShift);
  const double atrSL   = (direction > 0)
                         ? entryPrice - (atrValue * InpSL_ATRMult)
                         : entryPrice + (atrValue * InpSL_ATRMult);

  if (InpStopLossMode == SL_SWING && swingSL > 0.0) return swingSL;
  if (InpStopLossMode == SL_ATR)                    return atrSL;
  if (swingSL <= 0.0)                                return atrSL;

  // SL_HYBRID: pick the wider (safer) stop on the correct side.
  return (direction > 0) ? MathMin(swingSL, atrSL) : MathMax(swingSL, atrSL);
}

// ------------------------------------------------------------
// Order placement / cancellation
// ------------------------------------------------------------

// Validates that the limit price + SL/TP respect the broker's stops level.
// For BUY LIMIT, entry must be below current Ask by at least stopsLevel.
// For SELL LIMIT, entry must be above current Bid by at least stopsLevel.
bool ValidateLimitPrices(const SignalSnapshot &plan)
{
  const double stopsLevel = GetStopsLevelPrice();
  const double askNow     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bidNow     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (plan.direction > 0)
  {
    if (plan.entryPrice > askNow - stopsLevel)
    {
      if (InpDebugLog)
        PrintFormat("[ORDER] reject BUY LIMIT entry=%.5f too close to ask=%.5f (stops=%.5f)",
                    plan.entryPrice, askNow, stopsLevel);
      return false;
    }
    if (plan.entryPrice - plan.stopLossPrice < stopsLevel
     || plan.takeProfitPrice - plan.entryPrice < stopsLevel)
    {
      if (InpDebugLog)
        PrintFormat("[ORDER] reject BUY LIMIT SL/TP too close to entry (stops=%.5f)", stopsLevel);
      return false;
    }
  }
  else
  {
    if (plan.entryPrice < bidNow + stopsLevel)
    {
      if (InpDebugLog)
        PrintFormat("[ORDER] reject SELL LIMIT entry=%.5f too close to bid=%.5f (stops=%.5f)",
                    plan.entryPrice, bidNow, stopsLevel);
      return false;
    }
    if (plan.stopLossPrice - plan.entryPrice < stopsLevel
     || plan.entryPrice - plan.takeProfitPrice < stopsLevel)
    {
      if (InpDebugLog)
        PrintFormat("[ORDER] reject SELL LIMIT SL/TP too close to entry (stops=%.5f)", stopsLevel);
      return false;
    }
  }
  return true;
}

bool PlaceLimitOrderFromPlan(const SignalSnapshot &plan, PendingContext &pendingCtx)
{
  if (!ValidateLimitPrices(plan)) return false;

  const double lots = CalcLotsForRisk(plan.entryPrice, plan.stopLossPrice);
  if (lots <= 0.0)
  {
    if (InpDebugLog)
      PrintFormat("[ORDER] reject: lots=%.4f (risk too small or symbol info missing)", lots);
    return false;
  }

  const string comment = (plan.direction > 0) ? "RSIForce_BUY_LIMIT" : "RSIForce_SELL_LIMIT";
  bool placed = false;

  if (plan.direction > 0)
    placed = g_TradeOps.BuyLimit(lots,
                                 NormalizePriceToTick(plan.entryPrice), _Symbol,
                                 NormalizePriceToTick(plan.stopLossPrice),
                                 NormalizePriceToTick(plan.takeProfitPrice),
                                 ORDER_TIME_GTC, 0, comment);
  else
    placed = g_TradeOps.SellLimit(lots,
                                  NormalizePriceToTick(plan.entryPrice), _Symbol,
                                  NormalizePriceToTick(plan.stopLossPrice),
                                  NormalizePriceToTick(plan.takeProfitPrice),
                                  ORDER_TIME_GTC, 0, comment);

  if (!placed)
  {
    if (InpDebugLog)
      PrintFormat("[ORDER] place fail: ret=%u msg=%s",
                  g_TradeOps.ResultRetcode(), g_TradeOps.ResultRetcodeDescription());
    return false;
  }

  pendingCtx.orderTicket     = g_TradeOps.ResultOrder();
  pendingCtx.barsSincePlaced = 0;
  pendingCtx.plan            = plan;

  if (InpDebugLog)
    PrintFormat("[ORDER] placed %s lots=%.2f entry=%.5f SL=%.5f TP=%.5f ticket=%I64u",
                comment, lots, plan.entryPrice, plan.stopLossPrice, plan.takeProfitPrice,
                pendingCtx.orderTicket);
  return (pendingCtx.orderTicket > 0);
}

bool CancelPendingOrder(PendingContext &pendingCtx)
{
  if (pendingCtx.orderTicket == 0) return true;
  if (!g_TradeOps.OrderDelete(pendingCtx.orderTicket))
  {
    if (InpDebugLog)
      PrintFormat("[ORDER] delete fail: ret=%u", g_TradeOps.ResultRetcode());
    return false;
  }
  pendingCtx.orderTicket     = 0;
  pendingCtx.barsSincePlaced = 0;
  return true;
}

// ------------------------------------------------------------
// Broker queries (filtered by symbol + magic)
// ------------------------------------------------------------

bool HasOurOpenPosition(ulong &outTicket)
{
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    const ulong posTicket = PositionGetTicket(i);
    if (posTicket <= 0) continue;
    if (PositionGetString(POSITION_SYMBOL)   != _Symbol)        continue;
    if (PositionGetInteger(POSITION_MAGIC)   != InpMagicNumber) continue;
    outTicket = posTicket;
    return true;
  }
  return false;
}

bool HasOurPendingOrder(const ulong ticket)
{
  if (ticket == 0) return false;
  for (int i = OrdersTotal() - 1; i >= 0; i--)
  {
    if (OrderGetTicket(i) == ticket) return true;
  }
  return false;
}

// ------------------------------------------------------------
// Trade management: partial close at +R + move SL to BE
// ------------------------------------------------------------

bool ManagePartialAndBreakEven(TradeContext &openTrade)
{
  if (!openTrade.isActive || openTrade.partialClosedDone) return true;
  if (!PositionSelectByTicket(openTrade.positionTicket))   return false;
  if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return false;

  const long   posType    = PositionGetInteger(POSITION_TYPE);
  const double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
  const double slPrice    = PositionGetDouble(POSITION_SL);
  const double tpPrice    = PositionGetDouble(POSITION_TP);
  const double posVolume  = PositionGetDouble(POSITION_VOLUME);

  // Use the ACTUAL fill->SL distance as R, not the planned one
  // (broker fill price may differ from planned entry price).
  const double initRisk = MathAbs(openPrice - slPrice);
  if (initRisk <= 0.0) return false;

  const double priceNow   = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  const double profitDist = (posType == POSITION_TYPE_BUY)
                            ? (priceNow - openPrice)
                            : (openPrice - priceNow);

  // Not yet at the partial trigger.
  if (profitDist < (InpPartialCloseAtR * initRisk)) return true;

  // Try to split off `InpPartialClosePercent`% but only if both sides
  // remain >= volMin after split (otherwise just move BE).
  const double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double rawClose  = posVolume * (InpPartialClosePercent / 100.0);
  const double closeVol  = NormalizeVolumeToBroker(rawClose);
  const double remainVol = NormalizeVolumeToBroker(posVolume - closeVol);

  const bool canSplit = (closeVol >= volMin)
                     && (remainVol >= volMin)
                     && (closeVol < posVolume);
  if (canSplit)
  {
    if (!g_TradeOps.PositionClosePartial(openTrade.positionTicket, closeVol))
    {
      if (InpDebugLog)
        PrintFormat("[TRADE] partial-close fail: ret=%u", g_TradeOps.ResultRetcode());
      return false;
    }
  }

  // Always move SL to the actual fill price (BE).
  if (!g_TradeOps.PositionModify(openTrade.positionTicket,
                                 NormalizePriceToTick(openPrice), tpPrice))
  {
    if (InpDebugLog)
      PrintFormat("[TRADE] BE-move fail: ret=%u", g_TradeOps.ResultRetcode());
    return false;
  }

  openTrade.partialClosedDone = true;
  if (InpDebugLog)
    PrintFormat("[TRADE] Partial=%s vol=%.2f -> SL moved to BE @ %.5f",
                canSplit ? "yes" : "skipped(min vol)", closeVol, openPrice);
  return true;
}

#endif
