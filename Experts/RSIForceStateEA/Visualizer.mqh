#ifndef RSI_FORCE_STATE_EA__VISUALIZER_MQH
#define RSI_FORCE_STATE_EA__VISUALIZER_MQH

// ============================================================
// Visual layer for RSIForceStateEA.
// Renders:
//   - Top-left dashboard (trend, state, key indicator values).
//   - Bottom-left stats panel (totals, TP, SL, net P/L).
//   - TradingView-style Entry/SL/TP horizontal lines with labels.
//   - Optionally attaches EMA200/RSI/EMA9/WMA45 to the chart.
// All visual objects share the prefix "RSIForce_" and are removed
// in OnDeinit via RemoveAllVisuals().
// ============================================================

#define VIS_PREFIX           "RSIForce_"
#define VIS_LBL_DASH_PREFIX  VIS_PREFIX "DASH_"
#define VIS_LBL_STATS_PREFIX VIS_PREFIX "STATS_"
#define VIS_OBJ_LEVEL_PREFIX VIS_PREFIX "LV_"

// Aggregated stats computed from the deal history.
struct VisualTradeStats
{
  int    totalClosed;   // unique closed positions (any reason)
  int    tpHits;        // close deals with reason TP
  int    slHits;        // close deals with reason SL
  int    otherCloses;   // manual / expert / partial
  double netPL;         // sum of profit on close deals
};

// ------------------------------------------------------------
// Generic object helpers
// ------------------------------------------------------------

void EnsureLabel(const string objName, const int xDist, const int yDist,
                 const ENUM_BASE_CORNER corner, const color clr,
                 const string text, const int fontSize = 9)
{
  if (ObjectFind(0, objName) < 0)
  {
    ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, objName, OBJPROP_CORNER,     corner);
    ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,  xDist);
    ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,  yDist);
    ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,   fontSize);
    ObjectSetString (0, objName, OBJPROP_FONT,       "Consolas");
    ObjectSetInteger(0, objName, OBJPROP_BACK,       false);
    ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, objName, OBJPROP_HIDDEN,     true);
  }
  ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
  ObjectSetString (0, objName, OBJPROP_TEXT,  text);
}

void EnsureHLine(const string objName, const double price, const color clr,
                 const ENUM_LINE_STYLE style, const int width, const string text)
{
  if (ObjectFind(0, objName) < 0)
  {
    ObjectCreate(0, objName, OBJ_HLINE, 0, 0, price);
    ObjectSetInteger(0, objName, OBJPROP_BACK,       true);
    ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, objName, OBJPROP_HIDDEN,     true);
  }
  ObjectSetDouble (0, objName, OBJPROP_PRICE, price);
  ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
  ObjectSetInteger(0, objName, OBJPROP_STYLE, style);
  ObjectSetInteger(0, objName, OBJPROP_WIDTH, width);
  ObjectSetString (0, objName, OBJPROP_TEXT,  text);
}

color TrendColor(const TrendDirection trend)
{
  if (trend == TREND_UP)   return InpColorTrendUp;
  if (trend == TREND_DOWN) return InpColorTrendDown;
  return InpColorTrendNone;
}

string TrendLabel(const TrendDirection trend)
{
  if (trend == TREND_UP)   return "UP";
  if (trend == TREND_DOWN) return "DOWN";
  return "NONE";
}

// ------------------------------------------------------------
// Top-left dashboard
// ------------------------------------------------------------

void DrawDashboardPanel(const TrendDirection trendNow)
{
  if (!InpShowDashboard) return;

  const int xLeft = 12;
  int       y     = 12;
  const int rowH  = 18;

  EnsureLabel(VIS_LBL_DASH_PREFIX "title", xLeft, y, CORNER_LEFT_UPPER,
              clrWhite, "RSIForceStateEA", 11); y += rowH;

  EnsureLabel(VIS_LBL_DASH_PREFIX "trend", xLeft, y, CORNER_LEFT_UPPER,
              TrendColor(trendNow),
              "Trend  : " + TrendLabel(trendNow)); y += rowH;

  color stateClr = (g_State == STATE_IN_TRADE)      ? clrLime
                 : (g_State == STATE_PENDING_ORDER) ? clrOrange
                 : (g_State == STATE_WATCHING)      ? clrYellow
                 :                                    clrSilver;
  EnsureLabel(VIS_LBL_DASH_PREFIX "state", xLeft, y, CORNER_LEFT_UPPER,
              stateClr,
              "State  : " + EnumToString(g_State)); y += rowH;

  EnsureLabel(VIS_LBL_DASH_PREFIX "rsi", xLeft, y, CORNER_LEFT_UPPER,
              clrAqua,
              StringFormat("RSI    : %6.2f  EMA9 : %6.2f  WMA45: %6.2f",
                           g_RSI[1], g_EMA9[1], g_WMA45[1])); y += rowH;

  EnsureLabel(VIS_LBL_DASH_PREFIX "ema200", xLeft, y, CORNER_LEFT_UPPER,
              InpColorEntry,
              StringFormat("EMA200 : %.5f   Close: %.5f",
                           g_EMA200[1], g_Bars[1].close)); y += rowH;

  EnsureLabel(VIS_LBL_DASH_PREFIX "atr", xLeft, y, CORNER_LEFT_UPPER,
              clrSilver,
              StringFormat("ATR    : %.5f", g_ATR[1])); y += rowH;

  string contextLine = "";
  if (g_State == STATE_PENDING_ORDER)
    contextLine = StringFormat("Pending: dir=%s  entry=%.5f  alive=%d/%d",
                               (g_Pending.plan.direction > 0 ? "BUY" : "SELL"),
                               g_Pending.plan.entryPrice,
                               g_Pending.barsSincePlaced,
                               InpPendingMaxAliveBars);
  else if (g_State == STATE_IN_TRADE)
    contextLine = StringFormat("Trade  : dir=%s  entry=%.5f  partial=%s",
                               (g_OpenTrade.plan.direction > 0 ? "BUY" : "SELL"),
                               g_OpenTrade.plan.entryPrice,
                               g_OpenTrade.partialClosedDone ? "DONE" : "PEND");
  else if (g_State == STATE_WATCHING)
    contextLine = StringFormat("Watch  : %d/%d bars",
                               g_BarsInWatching, InpWatchingMaxBars);
  else
    contextLine = "Idle   : looking for pullback...";

  EnsureLabel(VIS_LBL_DASH_PREFIX "context", xLeft, y, CORNER_LEFT_UPPER,
              clrOrange, contextLine);
}

// ------------------------------------------------------------
// Bottom-left stats panel
// ------------------------------------------------------------

bool IsDealOurs(const ulong dealTicket)
{
  if (HistoryDealGetInteger(dealTicket, DEAL_MAGIC)  != InpMagicNumber) return false;
  if (HistoryDealGetString (dealTicket, DEAL_SYMBOL) != _Symbol)        return false;
  return true;
}

bool ContainsULong(const ulong &arr[], const int count, const ulong needle)
{
  for (int i = 0; i < count; i++)
    if (arr[i] == needle) return true;
  return false;
}

void ComputeTradeStats(VisualTradeStats &stats)
{
  ZeroMemory(stats);

  const datetime fromTime = TimeCurrent() - (datetime)(InpStatsLookbackDays * 86400);
  if (!HistorySelect(fromTime, TimeCurrent())) return;

  ulong seenPositions[];
  int   seenCount = 0;

  const int dealsTotal = HistoryDealsTotal();
  for (int i = 0; i < dealsTotal; i++)
  {
    const ulong dealTicket = HistoryDealGetTicket(i);
    if (dealTicket == 0)                                          continue;
    if (!IsDealOurs(dealTicket))                                  continue;
    if (HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

    const long   reason     = HistoryDealGetInteger(dealTicket, DEAL_REASON);
    const ulong  positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    const double profit     = HistoryDealGetDouble (dealTicket, DEAL_PROFIT)
                            + HistoryDealGetDouble (dealTicket, DEAL_SWAP)
                            + HistoryDealGetDouble (dealTicket, DEAL_COMMISSION);

    stats.netPL += profit;

    if (reason == DEAL_REASON_TP)        stats.tpHits++;
    else if (reason == DEAL_REASON_SL)   stats.slHits++;
    else                                  stats.otherCloses++;

    if (positionId > 0 && !ContainsULong(seenPositions, seenCount, positionId))
    {
      ArrayResize(seenPositions, seenCount + 1);
      seenPositions[seenCount++] = positionId;
      // Count as "fully closed" only if the position no longer exists.
      if (!PositionSelectByTicket(positionId)) stats.totalClosed++;
    }
  }
}

void DrawStatsPanel()
{
  if (!InpShowStatsPanel) return;

  VisualTradeStats stats;
  ComputeTradeStats(stats);

  const int    xLeft = 12;
  const int    rowH  = 18;
  int          y     = 12;

  EnsureLabel(VIS_LBL_STATS_PREFIX "pl",    xLeft, y, CORNER_LEFT_LOWER,
              stats.netPL >= 0 ? clrLime : clrTomato,
              StringFormat("Net PL : %.2f", stats.netPL)); y += rowH;

  EnsureLabel(VIS_LBL_STATS_PREFIX "other", xLeft, y, CORNER_LEFT_LOWER,
              clrSilver,
              StringFormat("Other  : %d", stats.otherCloses)); y += rowH;

  EnsureLabel(VIS_LBL_STATS_PREFIX "sl",    xLeft, y, CORNER_LEFT_LOWER,
              InpColorSL,
              StringFormat("SL hit : %d", stats.slHits)); y += rowH;

  EnsureLabel(VIS_LBL_STATS_PREFIX "tp",    xLeft, y, CORNER_LEFT_LOWER,
              InpColorTP,
              StringFormat("TP hit : %d", stats.tpHits)); y += rowH;

  EnsureLabel(VIS_LBL_STATS_PREFIX "total", xLeft, y, CORNER_LEFT_LOWER,
              clrWhite,
              StringFormat("Total  : %d", stats.totalClosed)); y += rowH;

  EnsureLabel(VIS_LBL_STATS_PREFIX "title", xLeft, y, CORNER_LEFT_LOWER,
              clrWhite,
              StringFormat("-- STATS (last %dd) --", InpStatsLookbackDays), 10);
}

// ------------------------------------------------------------
// Entry / SL / TP horizontal lines (TradingView style)
// ------------------------------------------------------------

void RemoveTradeLevels()
{
  ObjectDelete(0, VIS_OBJ_LEVEL_PREFIX "entry");
  ObjectDelete(0, VIS_OBJ_LEVEL_PREFIX "sl");
  ObjectDelete(0, VIS_OBJ_LEVEL_PREFIX "tp");
}

void DrawTradeLevels()
{
  if (!InpShowTradeLevels) { RemoveTradeLevels(); return; }

  SignalSnapshot plan;
  ZeroMemory(plan);
  bool show = false;

  if (g_State == STATE_PENDING_ORDER)
  {
    plan = g_Pending.plan;
    show = true;
  }
  else if (g_State == STATE_IN_TRADE)
  {
    plan = g_OpenTrade.plan;
    show = true;
  }

  if (!show) { RemoveTradeLevels(); return; }

  const string sideStr = (plan.direction > 0) ? "BUY" : "SELL";

  EnsureHLine(VIS_OBJ_LEVEL_PREFIX "entry", plan.entryPrice,
              InpColorEntry, STYLE_DOT, 1,
              StringFormat("%s ENTRY %.5f", sideStr, plan.entryPrice));

  EnsureHLine(VIS_OBJ_LEVEL_PREFIX "sl", plan.stopLossPrice,
              InpColorSL, STYLE_DASH, 1,
              StringFormat("SL %.5f", plan.stopLossPrice));

  EnsureHLine(VIS_OBJ_LEVEL_PREFIX "tp", plan.takeProfitPrice,
              InpColorTP, STYLE_DASH, 1,
              StringFormat("TP %.5f", plan.takeProfitPrice));
}

// ------------------------------------------------------------
// Indicator attach (EMA200 main + RSI cluster in subwindow)
// ------------------------------------------------------------

// Returns true if any indicator named like `prefix*` already lives on the
// given subwindow. Used to avoid stacking duplicates when the EA is reloaded.
bool IsIndicatorAlreadyAttached(const int subWindow, const string namePrefix)
{
  const int total = ChartIndicatorsTotal(0, subWindow);
  for (int i = 0; i < total; i++)
  {
    const string n = ChartIndicatorName(0, subWindow, i);
    if (StringFind(n, namePrefix) == 0) return true;
  }
  return false;
}

void AttachIndicatorsToChart()
{
  if (!InpAttachIndicators) return;

  // EMA200 in main window.
  if (!IsIndicatorAlreadyAttached(0, "Moving Average"))
  {
    if (!ChartIndicatorAdd(0, 0, g_hEMA200))
      PrintFormat("[VIS] add EMA200 to main fail: %d", GetLastError());
  }

  // RSI cluster in a dedicated subwindow.
  // We try to find an existing subwindow that already hosts an RSI; if not,
  // pass CHART_WINDOWS_TOTAL to create a fresh one.
  int rsiSubWindow = -1;
  const int totalWindows = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
  for (int w = 1; w < totalWindows; w++)
  {
    if (IsIndicatorAlreadyAttached(w, "RSI"))
    {
      rsiSubWindow = w;
      break;
    }
  }
  if (rsiSubWindow < 0) rsiSubWindow = totalWindows; // create new

  if (!IsIndicatorAlreadyAttached(rsiSubWindow, "RSI"))
  {
    if (!ChartIndicatorAdd(0, rsiSubWindow, g_hRSI))
      PrintFormat("[VIS] add RSI to subwindow fail: %d", GetLastError());
  }
  if (!IsIndicatorAlreadyAttached(rsiSubWindow, "Moving Average"))
  {
    if (!ChartIndicatorAdd(0, rsiSubWindow, g_hEMA9))
      PrintFormat("[VIS] add RSI_EMA9 to subwindow fail: %d", GetLastError());
    if (!ChartIndicatorAdd(0, rsiSubWindow, g_hWMA45))
      PrintFormat("[VIS] add RSI_WMA45 to subwindow fail: %d", GetLastError());
  }

  ChartRedraw(0);
}

// ------------------------------------------------------------
// Top-level orchestration
// ------------------------------------------------------------

void DrawAllVisuals(const TrendDirection trendNow)
{
  if (!InpVisualize) return;
  DrawDashboardPanel(trendNow);
  DrawStatsPanel();
  DrawTradeLevels();
}

void RemoveAllVisuals()
{
  ObjectsDeleteAll(0, VIS_PREFIX);
  ChartRedraw(0);
}

#endif
