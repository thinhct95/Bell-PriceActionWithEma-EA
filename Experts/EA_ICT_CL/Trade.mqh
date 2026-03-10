#ifndef EA_ICT_CL__TRADE_MQH
#define EA_ICT_CL__TRADE_MQH

/** Calculates lot size from account risk percent and entry–SL distance. */
inline double CalcLotFromRisk(double entry, double sl)
{
  double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney = balance * InpRiskPercent / 100.0;
  double slPips    = MathAbs(entry - sl) / _Point;
  if (slPips < 1) return 0;

  double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if (tickValue <= 0 || tickSize <= 0) return 0;

  double pipValue = tickValue * (_Point / tickSize);
  double rawLot   = riskMoney / (slPips * pipValue);

  double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (lotStep <= 0) lotStep = 0.01;

  rawLot = MathFloor(rawLot / lotStep) * lotStep;
  rawLot = MathMax(minLot, MathMin(maxLot, rawLot));
  return NormalizeDouble(rawLot, 2);
}

/** Fills g_OrderPlan from FVG id, direction, MSS entry and SL; returns true if valid. */
inline bool BuildOrderPlan(int fvgId, MarketDir dir, double mssEntry, double mssSL)
{
  ZeroMemory(g_OrderPlan);

  double entry = NormalizeDouble(mssEntry, _Digits);
  double sl    = mssSL;

  if (entry <= 0 || sl <= 0) return false;

  double tp;
  if (dir == DIR_UP)
  {
    if (sl >= entry) return false;
    sl = NormalizeDouble(sl - 2 * _Point, _Digits);
    double riskDist = entry - sl;
    tp = NormalizeDouble(entry + InpRiskReward * riskDist, _Digits);
  }
  else
  {
    if (sl <= entry) return false;
    sl = NormalizeDouble(sl + 2 * _Point, _Digits);
    double riskDist = sl - entry;
    tp = NormalizeDouble(entry - InpRiskReward * riskDist, _Digits);
  }

  double lot = CalcLotFromRisk(entry, sl);
  if (lot <= 0) return false;

  g_OrderPlan.valid       = true;
  g_OrderPlan.direction   = (dir == DIR_UP) ? 1 : -1;
  g_OrderPlan.entry       = entry;
  g_OrderPlan.stopLoss    = sl;
  g_OrderPlan.takeProfit  = tp;
  g_OrderPlan.lot         = lot;
  g_OrderPlan.parentFVGId = fvgId;

  if (InpDebugLog)
    PrintFormat("[ORDER PLAN] %s | entry=%.5f SL=%.5f TP=%.5f lot=%.2f | FVG#%d",
      (dir == DIR_UP) ? "BUY LIMIT" : "SELL LIMIT",
      entry, sl, tp, lot, fvgId);
  return true;
}

/** Sends limit order from g_OrderPlan; returns ticket or 0 on failure. */
inline ulong ExecuteLimitOrder()
{
  if (!g_OrderPlan.valid) return 0;

  ENUM_ORDER_TYPE orderType = (g_OrderPlan.direction > 0)
                                ? ORDER_TYPE_BUY_LIMIT
                                : ORDER_TYPE_SELL_LIMIT;

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (orderType == ORDER_TYPE_BUY_LIMIT && g_OrderPlan.entry >= ask)
  {
    if (InpDebugLog) PrintFormat("[ORDER] BUY LIMIT entry %.5f >= ask %.5f → skip",
      g_OrderPlan.entry, ask);
    return 0;
  }
  if (orderType == ORDER_TYPE_SELL_LIMIT && g_OrderPlan.entry <= bid)
  {
    if (InpDebugLog) PrintFormat("[ORDER] SELL LIMIT entry %.5f <= bid %.5f → skip",
      g_OrderPlan.entry, bid);
    return 0;
  }

  MqlTradeRequest request;
  MqlTradeResult  result;
  ZeroMemory(request);
  ZeroMemory(result);

  request.action       = TRADE_ACTION_PENDING;
  request.symbol       = _Symbol;
  request.volume       = g_OrderPlan.lot;
  request.type         = orderType;
  request.price        = g_OrderPlan.entry;
  request.sl           = g_OrderPlan.stopLoss;
  request.tp           = g_OrderPlan.takeProfit;
  request.deviation    = (ulong)InpSlippage;
  request.magic        = InpMagicNumber;
  request.comment      = StringFormat("ICT#%d", g_OrderPlan.parentFVGId);
  request.type_filling = ORDER_FILLING_RETURN;
  request.type_time    = ORDER_TIME_GTC;

  if (!OrderSend(request, result))
  {
    PrintFormat("[ORDER] ❌ retcode=%u", result.retcode);
    return 0;
  }
  if (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
  {
    PrintFormat("[ORDER] ❌ rejected retcode=%u: %s", result.retcode, result.comment);
    return 0;
  }

  PrintFormat("[ORDER] ✅ %s #%llu | %.2f @ %.5f SL=%.5f TP=%.5f",
    (orderType == ORDER_TYPE_BUY_LIMIT) ? "BUY_LIM" : "SELL_LIM",
    result.order, g_OrderPlan.lot, g_OrderPlan.entry,
    g_OrderPlan.stopLoss, g_OrderPlan.takeProfit);
  return result.order;
}

/** Scans trigger TF bars from signalTime forward to find which bar first hit SL or TP. */
inline datetime FindHitBarTime(const OrderHistRecord &rec)
{
  int startShift = MyBarShift(_Symbol, InpTriggerTF, rec.signalTime);
  if (startShift < 0) return TimeCurrent();

  for (int i = startShift; i >= 0; i--)
  {
    double h = iHigh(_Symbol, InpTriggerTF, i);
    double l = iLow (_Symbol, InpTriggerTF, i);
    bool hitTP = (rec.direction > 0) ? (h >= rec.takeProfit) : (l <= rec.takeProfit);
    bool hitSL = (rec.direction > 0) ? (l <= rec.stopLoss)   : (h >= rec.stopLoss);
    if (hitTP || hitSL)
      return iTime(_Symbol, InpTriggerTF, i);
  }
  return TimeCurrent();
}

/** Saves the current order plan into order history as active (result=0). */
inline void SaveOrderToHistory(datetime signalTime)
{
  if (g_OrderHistCount >= MAX_ORDER_HISTORY)
  {
    for (int j = 0; j < g_OrderHistCount - 1; j++)
      g_OrderHist[j] = g_OrderHist[j + 1];
    g_OrderHistCount--;
  }

  int n = g_OrderHistCount;
  ZeroMemory(g_OrderHist[n]);
  g_OrderHist[n].id          = g_NextOrderHistId++;
  g_OrderHist[n].direction   = g_OrderPlan.direction;
  g_OrderHist[n].entry       = g_OrderPlan.entry;
  g_OrderHist[n].stopLoss    = g_OrderPlan.stopLoss;
  g_OrderHist[n].takeProfit  = g_OrderPlan.takeProfit;
  g_OrderHist[n].lot         = g_OrderPlan.lot;
  g_OrderHist[n].signalTime  = signalTime;
  g_OrderHist[n].parentFVGId = g_OrderPlan.parentFVGId;
  g_OrderHistCount++;
}

/** Closes the most recent active order record with given result and profit. */
inline void CloseActiveOrderRecord(int result, double profit)
{
  for (int i = g_OrderHistCount - 1; i >= 0; i--)
  {
    if (g_OrderHist[i].result != 0) continue;
    g_OrderHist[i].result    = result;
    g_OrderHist[i].profit    = profit;
    g_OrderHist[i].closeTime = FindHitBarTime(g_OrderHist[i]);
    if (InpDebugLog)
      PrintFormat("[ORDER HIST] #%d %s | profit=%.2f | close=%s",
        g_OrderHist[i].id,
        (result == 1) ? "TP HIT" : (result == -1) ? "SL HIT" : "CANCELLED",
        profit, TimeToString(g_OrderHist[i].closeTime, TIME_MINUTES));
    break;
  }
}

#endif
