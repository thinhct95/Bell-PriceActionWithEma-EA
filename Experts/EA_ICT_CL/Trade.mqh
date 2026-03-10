#ifndef EA_ICT_CL__TRADE_MQH
#define EA_ICT_CL__TRADE_MQH

// Module: Trade
// Order plan building + limit order execution.
// Extracted from EA_ICT_CL.mq5 (Section 7B – Order plan & execution).
// NOTE: Uses EA globals (g_*) and inputs. Include AFTER globals exist.

inline double CalcLotFromRisk(double entry, double sl)
{
  double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney  = balance * InpRiskPercent / 100.0;
  double slPips     = MathAbs(entry - sl) / _Point;
  if (slPips < 1) return 0;

  double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if (tickValue <= 0 || tickSize <= 0) return 0;

  double pipValue   = tickValue * (_Point / tickSize);
  double rawLot     = riskMoney / (slPips * pipValue);

  double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (lotStep <= 0) lotStep = 0.01;

  rawLot = MathFloor(rawLot / lotStep) * lotStep;
  rawLot = MathMax(minLot, MathMin(maxLot, rawLot));
  return NormalizeDouble(rawLot, 2);
}

inline bool BuildOrderPlan(int fvgId, MarketDir dir, double mssEntry, double mssSL)
{
  ZeroMemory(g_OrderPlan);

  double entry = NormalizeDouble(mssEntry, _Digits);
  double sl = mssSL;

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

inline ulong ExecuteLimitOrder()
{
  if (!g_OrderPlan.valid) return 0;

  ENUM_ORDER_TYPE cmd = (g_OrderPlan.direction > 0)
                         ? ORDER_TYPE_BUY_LIMIT
                         : ORDER_TYPE_SELL_LIMIT;

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (cmd == ORDER_TYPE_BUY_LIMIT && g_OrderPlan.entry >= ask)
  {
    if (InpDebugLog) PrintFormat("[ORDER] BUY LIMIT entry %.5f >= ask %.5f → skip",
      g_OrderPlan.entry, ask);
    return 0;
  }
  if (cmd == ORDER_TYPE_SELL_LIMIT && g_OrderPlan.entry <= bid)
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
  request.type         = cmd;
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
    (cmd == ORDER_TYPE_BUY_LIMIT) ? "BUY_LIM" : "SELL_LIM",
    result.order, g_OrderPlan.lot, g_OrderPlan.entry,
    g_OrderPlan.stopLoss, g_OrderPlan.takeProfit);
  return result.order;
}

#endif // EA_ICT_CL__TRADE_MQH
