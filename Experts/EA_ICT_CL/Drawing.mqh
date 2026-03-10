#ifndef EA_ICT_CL__DRAWING_MQH
#define EA_ICT_CL__DRAWING_MQH

/** Draws one swing point (arrow + label + optional key-level line) on chart. */
inline void DrawOneSwingPoint(
  string prefix, ENUM_TIMEFRAMES tf,
  string tag, bool isHigh, int barIdx, double price,
  color clr, bool isKL, int arrowSz = 2, int fontSize = 8)
{
  string arrowObjName = prefix + "ARR_" + tag;
  string textObjName  = prefix + "TXT_" + tag;
  string keyLevelObjName = prefix + "KL_"  + tag;
  datetime barTime   = iTime(_Symbol, tf, barIdx);

  if (ObjectFind(0, arrowObjName) < 0)
    ObjectCreate(0, arrowObjName, OBJ_ARROW, 0, barTime, price);
  ObjectSetInteger(0, arrowObjName, OBJPROP_ARROWCODE, isHigh ? 234 : 233);
  ObjectSetInteger(0, arrowObjName, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrowObjName, OBJPROP_WIDTH,     arrowSz);
  ObjectSetInteger(0, arrowObjName, OBJPROP_ANCHOR,    isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
  ObjectMove(0, arrowObjName, 0, barTime, price);

  double barRange = iHigh(_Symbol, tf, barIdx) - iLow(_Symbol, tf, barIdx);
  double textY    = isHigh ? price + barRange * 0.3 : price - barRange * 0.3;
  if (ObjectFind(0, textObjName) < 0)
    ObjectCreate(0, textObjName, OBJ_TEXT, 0, barTime, textY);
  ObjectMove(0, textObjName, 0, barTime, textY);
  ObjectSetString (0, textObjName, OBJPROP_TEXT,    tag);
  ObjectSetInteger(0, textObjName, OBJPROP_COLOR,   clr);
  ObjectSetInteger(0, textObjName, OBJPROP_FONTSIZE, fontSize);
  ObjectSetInteger(0, textObjName, OBJPROP_ANCHOR,  isHigh ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

  if (isKL)
  {
    datetime endTime = iTime(_Symbol, tf, 0);
    if (ObjectFind(0, keyLevelObjName) < 0)
      ObjectCreate(0, keyLevelObjName, OBJ_TREND, 0, barTime, price, endTime, price);
    ObjectSetInteger(0, keyLevelObjName, OBJPROP_COLOR,     clr);
    ObjectSetInteger(0, keyLevelObjName, OBJPROP_STYLE,     STYLE_DASH);
    ObjectSetInteger(0, keyLevelObjName, OBJPROP_WIDTH,     1);
    ObjectSetInteger(0, keyLevelObjName, OBJPROP_RAY_RIGHT, false);
    ObjectMove(0, keyLevelObjName, 0, barTime, price);
    ObjectMove(0, keyLevelObjName, 1, endTime, price);
  }
  else ObjectDelete(0, keyLevelObjName);
}

/** Draws H1 swing points (H0/H1/L0/L1) when debug draw enabled. */
inline void DrawMiddleSwingPoints()
{
  if (!InpDebugDraw) return;
  if (g_MiddleTrend.idxH0 <= 0 || g_MiddleTrend.idxH1 <= 0 ||
      g_MiddleTrend.idxL0 <= 0 || g_MiddleTrend.idxL1 <= 0)
    { ObjectsDeleteAll(0, PREFIX_SWING_MIDDLE); return; }

  bool isUp   = (g_MiddleTrend.trend == DIR_UP);
  bool isDown = (g_MiddleTrend.trend == DIR_DOWN);
  DrawOneSwingPoint(
    PREFIX_SWING_MIDDLE, InpMiddleTF, "H0",
    true, g_MiddleTrend.idxH0, g_MiddleTrend.h0,
    clrAqua, isDown, 2, 8
  );
  DrawOneSwingPoint(
    PREFIX_SWING_MIDDLE, InpMiddleTF, "H1",
    true, g_MiddleTrend.idxH1, g_MiddleTrend.h1,
    C'0,140,160', false, 2, 8
  );
  DrawOneSwingPoint(
    PREFIX_SWING_MIDDLE, InpMiddleTF, "L0",
    false, g_MiddleTrend.idxL0, g_MiddleTrend.l0,
    clrYellow, isUp, 2, 8
  );
  DrawOneSwingPoint(
    PREFIX_SWING_MIDDLE, InpMiddleTF, "L1",
    false, g_MiddleTrend.idxL1, g_MiddleTrend.l1,
    C'160,140,0', false, 2, 8
  );
}

/** Draws M5 swing points when debug draw enabled. */
inline void DrawTriggerSwingPoints()
{
  if (!InpDebugDraw) return;
  if (g_TriggerTrend.idxH0 <= 0 || g_TriggerTrend.idxH1 <= 0 ||
      g_TriggerTrend.idxL0 <= 0 || g_TriggerTrend.idxL1 <= 0)
    { ObjectsDeleteAll(0, PREFIX_SWING_TRIGGER); return; }

  bool isUp   = (g_TriggerTrend.trend == DIR_UP);
  bool isDown = (g_TriggerTrend.trend == DIR_DOWN);
  DrawOneSwingPoint(
    PREFIX_SWING_TRIGGER, InpTriggerTF, "h0",
    true, g_TriggerTrend.idxH0, g_TriggerTrend.h0,
    C'180,100,255', isDown, 1, 7
  );
  DrawOneSwingPoint(
    PREFIX_SWING_TRIGGER, InpTriggerTF, "h1",
    true, g_TriggerTrend.idxH1, g_TriggerTrend.h1,
    C'100,60,160', false, 1, 7
  );
  DrawOneSwingPoint(
    PREFIX_SWING_TRIGGER, InpTriggerTF, "l0",
    false, g_TriggerTrend.idxL0, g_TriggerTrend.l0,
    C'255,160,40', isUp, 1, 7
  );
  DrawOneSwingPoint(
    PREFIX_SWING_TRIGGER, InpTriggerTF, "l1",
    false, g_TriggerTrend.idxL1, g_TriggerTrend.l1,
    C'160,100,20', false, 1, 7
  );
}

/** Draws one MSS marker (arrow + label + horizontal level) at given time/level. */
inline void DrawMSSMarker(
  string mssId, ENUM_TIMEFRAMES tf,
  datetime mssTime, double mssLevel, MarketDir mssBreak)
{
  if (!InpDebugDraw || mssTime == 0) return;

  string arrowObjName = PREFIX_MSS_MARKER + mssId + "_ARR";
  string labelObjName = PREFIX_MSS_MARKER + mssId + "_LBL";
  string levelObjName = PREFIX_MSS_MARKER + mssId + "_KL";

  bool  isBull = (mssBreak == DIR_UP);
  color clr    = isBull ? clrLime : clrTomato;

  int barShift = MyBarShift(_Symbol, tf, mssTime);
  if (barShift < 0) return;
  double closeAtMss = iClose(_Symbol, tf, barShift);

  if (ObjectFind(0, arrowObjName) < 0)
    ObjectCreate(0, arrowObjName, OBJ_ARROW, 0, mssTime, closeAtMss);
  ObjectSetInteger(0, arrowObjName, OBJPROP_ARROWCODE, isBull ? 233 : 234);
  ObjectSetInteger(0, arrowObjName, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, arrowObjName, OBJPROP_WIDTH,     2);
  ObjectSetInteger(0, arrowObjName, OBJPROP_ANCHOR,    isBull ? ANCHOR_TOP : ANCHOR_BOTTOM);
  ObjectMove(0, arrowObjName, 0, mssTime, closeAtMss);

  double barRange = iHigh(_Symbol, tf, barShift) - iLow(_Symbol, tf, barShift);
  double labelY   = isBull ? closeAtMss - barRange * 0.4 : closeAtMss + barRange * 0.4;
  if (ObjectFind(0, labelObjName) < 0)
    ObjectCreate(0, labelObjName, OBJ_TEXT, 0, mssTime, labelY);
  ObjectMove(0, labelObjName, 0, mssTime, labelY);
  ObjectSetString (0, labelObjName, OBJPROP_TEXT,    isBull ? "▲MSS" : "▼MSS");
  ObjectSetInteger(0, labelObjName, OBJPROP_COLOR,   clr);
  ObjectSetInteger(0, labelObjName, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, labelObjName, OBJPROP_ANCHOR,  isBull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

  datetime endTime = iTime(_Symbol, tf, 0);
  if (ObjectFind(0, levelObjName) < 0)
    ObjectCreate(0, levelObjName, OBJ_TREND, 0, mssTime, mssLevel, endTime, mssLevel);
  ObjectSetInteger(0, levelObjName, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, levelObjName, OBJPROP_STYLE,     STYLE_DOT);
  ObjectSetInteger(0, levelObjName, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, levelObjName, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, levelObjName, 0, mssTime, mssLevel);
  ObjectMove(0, levelObjName, 1, endTime,    mssLevel);
}

/** Draws MSS markers for all FVGs that were triggered by MSS (usedCase == 2). */
inline void DrawMSSMarkers()
{
  if (!InpDebugDraw) return;
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status != FVG_USED || g_FVGPool[i].usedCase != 2) continue;
    if (g_FVGPool[i].mssTime == 0) continue;

    string tid = "T_" + IntegerToString(g_FVGPool[i].id);
    DrawMSSMarker(
      tid,
      InpTriggerTF,
      g_FVGPool[i].mssTime,
      g_FVGPool[i].mssEntry,
      g_FVGPool[i].direction == DIR_UP ? DIR_UP : DIR_DOWN
    );
  }
}

/** Helper: creates or moves a rectangle. */
inline void SetRect(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  ObjectSetInteger(0, name, OBJPROP_FILL,  true);
  ObjectSetInteger(0, name, OBJPROP_BACK,  true);
  ObjectMove(0, name, 0, t1, p1);
  ObjectMove(0, name, 1, t2, p2);
}

/** Helper: creates or moves a horizontal trend line. */
inline void SetHLine(string name, datetime t1, double p, datetime t2, color clr, int style, int width)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_TREND, 0, t1, p, t2, p);
  ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
  ObjectSetInteger(0, name, OBJPROP_WIDTH,     width);
  ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, name, 0, t1, p);
  ObjectMove(0, name, 1, t2, p);
}

/** Helper: creates or moves a text label at a chart coordinate. */
inline void SetText(string name, datetime t, double p, string txt, color clr, int fontSize, int anchor)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
  ObjectMove(0, name, 0, t, p);
  ObjectSetString (0, name, OBJPROP_TEXT,     txt);
  ObjectSetInteger(0, name, OBJPROP_COLOR,    clr);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
  ObjectSetInteger(0, name, OBJPROP_ANCHOR,   anchor);
}

/** Draws one order record in TradingView style (TP/SL zones, entry line, labels). */
inline void DrawOneOrderHist(int idx)
{
  string sid = IntegerToString(g_OrderHist[idx].id);
  string pfx = PREFIX_ORDER_HIST + sid + "_";

  bool   isBuy = (g_OrderHist[idx].direction > 0);
  double entry = g_OrderHist[idx].entry;
  double sl    = g_OrderHist[idx].stopLoss;
  double tp    = g_OrderHist[idx].takeProfit;
  int    res   = g_OrderHist[idx].result;

  datetime tStart = g_OrderHist[idx].signalTime;
  datetime tEnd;
  if (res == 0)
    tEnd = iTime(_Symbol, InpTriggerTF, 0) + PeriodSeconds(InpTriggerTF) * 10;
  else
    tEnd = g_OrderHist[idx].closeTime;
  if (tEnd <= tStart)
    tEnd = tStart + PeriodSeconds(InpTriggerTF) * 10;

  double slPips = MathAbs(entry - sl) / _Point;
  double tpPips = MathAbs(tp - entry) / _Point;
  double rr     = (slPips > 0) ? tpPips / slPips : 0;

  color entClr, tpZoneClr, slZoneClr, tpLineClr, slLineClr, resultClr;
  if (res == 1)
  {
    entClr     = C'0,180,80';
    tpZoneClr  = C'10,70,30';
    slZoneClr  = C'40,15,15';
    tpLineClr  = C'38,200,91';
    slLineClr  = C'120,50,50';
    resultClr  = C'0,220,100';
  }
  else if (res == -1)
  {
    entClr     = C'220,50,50';
    tpZoneClr  = C'15,40,15';
    slZoneClr  = C'90,12,12';
    tpLineClr  = C'50,120,50';
    slLineClr  = C'229,57,53';
    resultClr  = C'229,57,53';
  }
  else
  {
    entClr     = isBuy ? C'33,150,243' : C'255,152,0';
    tpZoneClr  = C'15,60,30';
    slZoneClr  = C'75,12,12';
    tpLineClr  = C'38,166,91';
    slLineClr  = C'229,57,53';
    resultClr  = entClr;
  }

  double tpTop = isBuy ? tp    : entry;
  double tpBot = isBuy ? entry : tp;
  SetRect(pfx + "TP", tStart, tpTop, tEnd, tpBot, tpZoneClr);

  double slTop = isBuy ? entry : sl;
  double slBot = isBuy ? sl    : entry;
  SetRect(pfx + "SL", tStart, slTop, tEnd, slBot, slZoneClr);

  SetHLine(pfx + "ENT", tStart, entry, tEnd, entClr,     STYLE_SOLID, 2);
  SetHLine(pfx + "TPL", tStart, tp,    tEnd, tpLineClr,  STYLE_DASH,  1);
  SetHLine(pfx + "SLL", tStart, sl,    tEnd, slLineClr,  STYLE_DASH,  1);

  datetime lblT = tEnd + PeriodSeconds(InpTriggerTF);

  string entTxt;
  if (res == 0)
    entTxt = StringFormat("%s %.3f | %.2f lot",
      isBuy ? "BUY LIM" : "SELL LIM", entry, g_OrderHist[idx].lot);
  else
    entTxt = StringFormat("%s %.3f | %.2f lot | %s",
      isBuy ? "BUY" : "SELL", entry, g_OrderHist[idx].lot,
      (res == 1) ? "WIN" : (res == -1) ? "LOSS" : "X");
  SetText(pfx + "ELBL", lblT, entry, entTxt, entClr, 8, ANCHOR_LEFT);

  SetText(pfx + "TPLBL", lblT, tp,
    StringFormat("TP %.3f | +%.0fp (%.1fR)", tp, tpPips, rr),
    tpLineClr, 7, isBuy ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);

  SetText(pfx + "SLLBL", lblT, sl,
    StringFormat("SL %.3f | -%.0fp", sl, slPips),
    slLineClr, 7, isBuy ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

  if (res != 0)
  {
    string resTxt = (res == 1)
      ? StringFormat("✓ +$%.2f", g_OrderHist[idx].profit)
      : (res == -1)
        ? StringFormat("✗ $%.2f", g_OrderHist[idx].profit)
        : "✗ cancelled";
    SetText(pfx + "RES", lblT, (entry + sl) / 2.0, resTxt, resultClr, 8, ANCHOR_LEFT);
  }
  else
  {
    SetText(pfx + "RES", lblT, (entry + sl) / 2.0,
      StringFormat("Risk %.1f%% | %.0f:%.0fp | %.1fR", InpRiskPercent, slPips, tpPips, rr),
      C'140,140,140', 7, ANCHOR_LEFT);
  }
}

/** Deletes all chart objects for one order history record. */
inline void DeleteOrderHistObjects(int id)
{
  string sid = IntegerToString(id);
  string pfx = PREFIX_ORDER_HIST + sid + "_";
  ObjectDelete(0, pfx + "TP");
  ObjectDelete(0, pfx + "SL");
  ObjectDelete(0, pfx + "ENT");
  ObjectDelete(0, pfx + "TPL");
  ObjectDelete(0, pfx + "SLL");
  ObjectDelete(0, pfx + "ELBL");
  ObjectDelete(0, pfx + "TPLBL");
  ObjectDelete(0, pfx + "SLLBL");
  ObjectDelete(0, pfx + "RES");
}

/** Draws all order history records; cleans up records older than ORDER_HIST_DAYS. */
inline void DrawAllOrders()
{
  if (!InpDebugDraw) return;

  datetime cutoff = TimeCurrent() - ORDER_HIST_DAYS * 86400;
  for (int i = g_OrderHistCount - 1; i >= 0; i--)
  {
    if (g_OrderHist[i].closeTime > 0 && g_OrderHist[i].closeTime < cutoff)
    {
      DeleteOrderHistObjects(g_OrderHist[i].id);
      for (int j = i; j < g_OrderHistCount - 1; j++)
        g_OrderHist[j] = g_OrderHist[j + 1];
      g_OrderHistCount--;
      continue;
    }
    DrawOneOrderHist(i);
  }
}

/** Draws one FVG record (rectangle + mid line + label) by pool index. */
inline void DrawOneFVGRecord(int idx)
{
  if (!InpDebugDraw || idx < 0 || idx >= g_FVGCount) return;

  string sid   = IntegerToString(g_FVGPool[idx].id);
  string rectN = PREFIX_FVG_POOL + "RECT_" + sid;
  string midN  = PREFIX_FVG_POOL + "MID_"  + sid;
  string lblN  = PREFIX_FVG_POOL + "LBL_"  + sid;

  datetime rectEnd;
  if (g_FVGPool[idx].status == FVG_PENDING)
    rectEnd = iTime(_Symbol, InpMiddleTF, 0);
  else if (g_FVGPool[idx].touchTime > 0)
  {
    int shift = MyBarShift(_Symbol, InpTriggerTF, g_FVGPool[idx].touchTime);
    rectEnd   = (shift >= 0) ? iTime(_Symbol, InpTriggerTF, shift) : iTime(_Symbol, InpMiddleTF, 0);
  }
  else
  {
    int shift = MyBarShift(_Symbol, InpMiddleTF, g_FVGPool[idx].usedTime);
    rectEnd   = (shift >= 0) ? iTime(_Symbol, InpMiddleTF, shift) : iTime(_Symbol, InpMiddleTF, 0);
  }
  if (rectEnd <= g_FVGPool[idx].createdTime) rectEnd = iTime(_Symbol, InpMiddleTF, 0);

  color fillColor;
  if      (g_FVGPool[idx].status == FVG_PENDING) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,50,110'  : C'90,25,0';
  else if (g_FVGPool[idx].status == FVG_TOUCHED) fillColor = (g_FVGPool[idx].direction == DIR_UP) ? C'0,120,220' : C'220,75,0';
  else if (g_FVGPool[idx].usedCase == 2)         fillColor = C'0,100,0';
  else if (g_FVGPool[idx].usedCase == 1)         fillColor = C'70,0,0';
  else                                           fillColor = C'50,50,50';

  if (ObjectFind(0, rectN) < 0)
    ObjectCreate(
      0,
      rectN,
      OBJ_RECTANGLE,
      0,
      g_FVGPool[idx].createdTime,
      g_FVGPool[idx].high,
      rectEnd,
      g_FVGPool[idx].low
    );
  ObjectSetInteger(0, rectN, OBJPROP_COLOR, fillColor);
  ObjectSetInteger(0, rectN, OBJPROP_FILL,  true);
  ObjectSetInteger(0, rectN, OBJPROP_BACK,  true);
  ObjectMove(
    0,
    rectN,
    0,
    g_FVGPool[idx].createdTime,
    g_FVGPool[idx].high
  );
  ObjectMove(0, rectN, 1, rectEnd, g_FVGPool[idx].low);

  color midColor = (g_FVGPool[idx].status == FVG_USED) ? C'60,60,60' : clrSilver;
  if (ObjectFind(0, midN) < 0)
    ObjectCreate(
      0,
      midN,
      OBJ_TREND,
      0,
      g_FVGPool[idx].createdTime,
      g_FVGPool[idx].mid,
      rectEnd,
      g_FVGPool[idx].mid
    );
  ObjectSetInteger(0, midN, OBJPROP_COLOR,     midColor);
  ObjectSetInteger(0, midN, OBJPROP_STYLE,     STYLE_DOT);
  ObjectSetInteger(0, midN, OBJPROP_WIDTH,     1);
  ObjectSetInteger(0, midN, OBJPROP_RAY_RIGHT, false);
  ObjectMove(
    0,
    midN,
    0,
    g_FVGPool[idx].createdTime,
    g_FVGPool[idx].mid
  );
  ObjectMove(0, midN, 1, rectEnd, g_FVGPool[idx].mid);

  string sym = (g_FVGPool[idx].direction == DIR_UP) ? "▲" : "▼";
  string stTxt = "";
  if      (g_FVGPool[idx].status == FVG_TOUCHED) stTxt  = " [T]";
  else if (g_FVGPool[idx].usedCase == 2)         stTxt  = " [TRIG]";
  else if (g_FVGPool[idx].usedCase == 1)         stTxt  = " [BRK]";
  else if (g_FVGPool[idx].status == FVG_USED)    stTxt  = " [EXP]";

  if (ObjectFind(0, lblN) < 0)
    ObjectCreate(
      0,
      lblN,
      OBJ_TEXT,
      0,
      g_FVGPool[idx].createdTime,
      g_FVGPool[idx].high
    );
  ObjectMove(
    0,
    lblN,
    0,
    g_FVGPool[idx].createdTime,
    g_FVGPool[idx].high
  );
  ObjectSetString(
    0,
    lblN,
    OBJPROP_TEXT,
    StringFormat(
      "FVG#%d %s%s",
      g_FVGPool[idx].id,
      sym,
      stTxt
    )
  );
  ObjectSetInteger(0, lblN, OBJPROP_COLOR,   fillColor);
  ObjectSetInteger(0, lblN, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, lblN, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
}

/** Draws all FVGs in pool (calls DrawOneFVGRecord for each). */
inline void DrawFVGPool()
{
  if (!InpDebugDraw) return;
  for (int i = 0; i < g_FVGCount; i++) DrawOneFVGRecord(i);
}

/** Draws debug panel (bias, H1/M5 trend, risk, state, pool, active FVG, order). */
inline void DrawContextDebug()
{
  if (!InpDebugDraw) return;

  #define LBL(name,txt,y,clr)                             \
    if (ObjectFind(0, name) < 0)                          \
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);          \
    ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER); \
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);     \
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);      \
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);      \
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);    \
    ObjectSetString (0, name, OBJPROP_TEXT,      txt);

  LBL(PREFIX_DEBUG_PANEL + "HDR",  "── ICT EA v4.3 ──", 10, clrSilver)

  color cMT = (g_MiddleTrend.trend == DIR_UP)
    ? clrLime
    : (g_MiddleTrend.trend == DIR_DOWN) ? clrTomato : clrGray;
  LBL(
    PREFIX_DEBUG_PANEL + "MT",
    StringFormat(
      "H1   : %s  KL=%.5f",
      EnumToString(g_MiddleTrend.trend),
      g_MiddleTrend.keyLevel
    ),
    34,
    cMT
  )

  color cTT = (g_TriggerTrend.trend == DIR_UP)
    ? clrLime
    : (g_TriggerTrend.trend == DIR_DOWN) ? clrTomato : clrGray;
  LBL(
    PREFIX_DEBUG_PANEL + "TT",
    StringFormat(
      "M5   : %s  KL=%.5f",
      EnumToString(g_TriggerTrend.trend),
      g_TriggerTrend.keyLevel
    ),
    58,
    cTT
  )

  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount
      && g_FVGPool[g_ActiveFVGIdx].usedCase == 2
      && g_FVGPool[g_ActiveFVGIdx].mssTime > 0)
  {
    int ai = g_ActiveFVGIdx;
    color cM = (g_FVGPool[ai].direction == DIR_UP) ? clrLime : clrTomato;
    LBL(
      PREFIX_DEBUG_PANEL + "MSS",
      StringFormat(
        "MSS  : %s entry=%.5f SL=%.5f @ %s (FVG#%d)",
        (g_FVGPool[ai].direction == DIR_UP) ? "▲" : "▼",
        g_FVGPool[ai].mssEntry,
        g_FVGPool[ai].mssSL,
        TimeToString(g_FVGPool[ai].mssTime, TIME_MINUTES),
        g_FVGPool[ai].id
      ),
      82,
      cM
    )
  }
  else ObjectDelete(0, PREFIX_DEBUG_PANEL + "MSS");

  double lostPct = (g_DailyRisk.startBalance > 0)
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
        / g_DailyRisk.startBalance * 100.0
    : 0.0;
  color cR = g_DailyRisk.limitHit
    ? clrRed
    : (lostPct > InpMaxDailyLossPct * 0.7) ? clrOrange : clrLime;
  LBL(
    PREFIX_DEBUG_PANEL + "RISK",
    StringFormat("Risk : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct),
    106,
    cR
  )

  color cS = (g_State == EA_IDLE)
    ? clrSilver
    : (g_State == EA_WAIT_TOUCH)
      ? clrOrange
      : (g_State == EA_WAIT_TRIGGER) ? clrYellow : clrLime;
  LBL(
    PREFIX_DEBUG_PANEL + "ST",
    StringFormat("State: %s", EnumToString(g_State)),
    130,
    cS
  )

  if (g_BlockReason != BLOCK_NONE)
  {
    LBL(
      PREFIX_DEBUG_PANEL + "BLK",
      StringFormat("Block: %s", EnumToString(g_BlockReason)),
      154,
      clrTomato
    )
  }
  else ObjectDelete(0, PREFIX_DEBUG_PANEL + "BLK");

  int countPending = 0;
  int countTouched = 0;
  int countUsed    = 0;
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_PENDING)
      countPending++;
    else if (g_FVGPool[i].status == FVG_TOUCHED)
      countTouched++;
    else
      countUsed++;
  }
  LBL(
    PREFIX_DEBUG_PANEL + "POOL",
    StringFormat(
      "Pool : P=%d T=%d U=%d (%d/%d)",
      countPending,
      countTouched,
      countUsed,
      g_FVGCount,
      MAX_FVG_POOL
    ),
    178,
    clrDodgerBlue
  )

  if (g_ActiveFVGIdx >= 0 && g_ActiveFVGIdx < g_FVGCount)
  {
    int ai = g_ActiveFVGIdx;
    LBL(
      PREFIX_DEBUG_PANEL + "ACT",
      StringFormat(
        "Act  : #%d %s [%.5f–%.5f] %s",
        g_FVGPool[ai].id,
        EnumToString(g_FVGPool[ai].direction),
        g_FVGPool[ai].low,
        g_FVGPool[ai].high,
        EnumToString(g_FVGPool[ai].status)
      ),
      202,
      clrDeepSkyBlue
    )
  }
  else ObjectDelete(0, PREFIX_DEBUG_PANEL + "ACT");

  if (g_PendingTicket > 0 && g_OrderPlan.valid)
  {
    LBL(
      PREFIX_DEBUG_PANEL + "ORD",
      StringFormat(
        "Order: %s #%llu @ %.5f SL=%.5f TP=%.5f",
        (g_OrderPlan.direction > 0) ? "BUY" : "SELL",
        g_PendingTicket,
        g_OrderPlan.entry,
        g_OrderPlan.stopLoss,
        g_OrderPlan.takeProfit
      ),
      226,
      clrGold
    )
  }
  else ObjectDelete(0, PREFIX_DEBUG_PANEL + "ORD");

  #undef LBL
  ChartRedraw(0);
}

/** Draws London and NY session zones (background color) on visible chart range. */
inline void DrawSessionMarkers()
{
  if (!InpDebugDraw) return;

  int firstBar = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
  int visibleBars = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
  if (visibleBars <= 0) return;

  ENUM_TIMEFRAMES chartTf = (ENUM_TIMEFRAMES)ChartPeriod(0);
  datetime firstTime = iTime(_Symbol, chartTf, firstBar);
  int lastBarIdx = firstBar - visibleBars + 1;
  if (lastBarIdx < 0) return;
  datetime lastTime = iTime(_Symbol, chartTf, lastBarIdx);

  double yHigh = 0;
  double yLow = 1e300;
  for (int i = firstBar; i >= lastBarIdx && i >= 0; i--)
  {
    double h = iHigh(_Symbol, chartTf, i);
    double l = iLow(_Symbol, chartTf, i);
    if (h > yHigh) yHigh = h;
    if (l < yLow) yLow = l;
  }
  double range = yHigh - yLow;
  if (range < _Point) return;
  double margin = MathMax(range * 0.02, 10 * _Point);
  yHigh += margin;
  yLow -= margin;

  const color clrLondon = (color)C'50,75,115';
  const color clrNY     = (color)C'115,80,50';

  ObjectsDeleteAll(0, PREFIX_SESSION);

  for (int d = 0; d <= 200; d++)
  {
    datetime dayStart = iTime(_Symbol, PERIOD_D1, d);
    if (dayStart > lastTime) break;
    if (dayStart + 86400 < firstTime) continue;

    long startL = (long)InpLondonStartHour * 3600;
    long endL   = (long)InpLondonEndHour   * 3600;
    long startN = (long)InpNYStartHour * 3600;
    long endN   = (long)InpNYEndHour   * 3600;

    if (InpLondonStartHour < InpLondonEndHour)
    {
      datetime t1 = (datetime)(dayStart + startL);
      datetime t2 = (datetime)(dayStart + endL);
      if (t2 > firstTime && t1 < lastTime)
      {
        string name = PREFIX_SESSION + "L_" + IntegerToString(d);
        if (ObjectFind(0, name) < 0)
          ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, yHigh, t2, yLow);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrLondon);
        ObjectSetInteger(0, name, OBJPROP_FILL,  true);
        ObjectSetInteger(0, name, OBJPROP_BACK,  true);
        ObjectMove(0, name, 0, t1, yHigh);
        ObjectMove(0, name, 1, t2, yLow);
      }
    }
    else
    {
      datetime t1 = (datetime)(dayStart + startL);
      datetime t2 = (datetime)(dayStart + 86400 + endL);
      if (t2 > firstTime && t1 < lastTime)
      {
        string name = PREFIX_SESSION + "L_" + IntegerToString(d);
        if (ObjectFind(0, name) < 0)
          ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, yHigh, t2, yLow);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrLondon);
        ObjectSetInteger(0, name, OBJPROP_FILL,  true);
        ObjectSetInteger(0, name, OBJPROP_BACK,  true);
        ObjectMove(0, name, 0, t1, yHigh);
        ObjectMove(0, name, 1, t2, yLow);
      }
    }

    if (InpNYStartHour < InpNYEndHour)
    {
      datetime t1 = (datetime)(dayStart + startN);
      datetime t2 = (datetime)(dayStart + endN);
      if (t2 > firstTime && t1 < lastTime)
      {
        string name = PREFIX_SESSION + "N_" + IntegerToString(d);
        if (ObjectFind(0, name) < 0)
          ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, yHigh, t2, yLow);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrNY);
        ObjectSetInteger(0, name, OBJPROP_FILL,  true);
        ObjectSetInteger(0, name, OBJPROP_BACK,  true);
        ObjectMove(0, name, 0, t1, yHigh);
        ObjectMove(0, name, 1, t2, yLow);
      }
    }
    else
    {
      datetime t1 = (datetime)(dayStart + startN);
      datetime t2 = (datetime)(dayStart + 86400 + endN);
      if (t2 > firstTime && t1 < lastTime)
      {
        string name = PREFIX_SESSION + "N_" + IntegerToString(d);
        if (ObjectFind(0, name) < 0)
          ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, yHigh, t2, yLow);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrNY);
        ObjectSetInteger(0, name, OBJPROP_FILL,  true);
        ObjectSetInteger(0, name, OBJPROP_BACK,  true);
        ObjectMove(0, name, 0, t1, yHigh);
        ObjectMove(0, name, 1, t2, yLow);
      }
    }
  }
}

/** Draws all debug visuals: swings, MSS markers, FVG pool, orders, debug panel. */
inline void DrawVisuals()
{
  DrawSessionMarkers();
  DrawContextDebug();
  DrawMiddleSwingPoints();
  DrawFVGPool();
  DrawTriggerSwingPoints();
  DrawMSSMarkers();
  DrawAllOrders();
}

#endif // EA_ICT_CL__DRAWING_MQH

