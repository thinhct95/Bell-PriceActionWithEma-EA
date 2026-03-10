#ifndef EA_ICT_CL__SIGNALS_BOS_FVG_OB_MQH
#define EA_ICT_CL__SIGNALS_BOS_FVG_OB_MQH

/** True if candle at bar index has body % of range >= InpFVGMinBodyPct. */
inline bool IsCandleStrong(ENUM_TIMEFRAMES tf, int barIndex)
{
  double high   = iHigh(_Symbol, tf, barIndex);
  double low    = iLow(_Symbol, tf, barIndex);
  double open   = iOpen(_Symbol, tf, barIndex);
  double close  = iClose(_Symbol, tf, barIndex);
  double range  = high - low;
  if (range < _Point) return false;
  return (MathAbs(close - open) / range * 100.0) >= InpFVGMinBodyPct;
}

/** True if an FVG with given created time already exists in pool. */
inline bool IsFVGInPool(datetime createdTime)
{
  for (int j = 0; j < g_FVGCount; j++)
    if (g_FVGPool[j].createdTime == createdTime) return true;
  return false;
}

/** Scans middle TF for FVGs and registers them into g_FVGPool (once per new bar). */
inline void ScanAndRegisterFVGs()
{
  static datetime lastScanBarTime = 0;
  datetime currentBarTime = iTime(_Symbol, InpMiddleTF, 0);
  if (currentBarTime == lastScanBarTime) return;
  lastScanBarTime = currentBarTime;

  MarketDir trendDir = g_MiddleTrend.trend;
  if (trendDir == DIR_NONE) return;

  int maxBarIndex = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2);

  for (int i = 2; i <= maxBarIndex; i++)
  {
    double leftBarHigh  = iHigh (_Symbol, InpMiddleTF, i + 1);
    double leftBarLow   = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightBarHigh = iHigh (_Symbol, InpMiddleTF, i - 1);
    double rightBarLow  = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midOpen      = iOpen (_Symbol, InpMiddleTF, i);
    double midClose     = iClose(_Symbol, InpMiddleTF, i);
    double gapHigh = 0, gapLow = 0;

    if (trendDir == DIR_UP)
    {
      if (leftBarHigh >= rightBarLow) continue;
      if (midClose <= midOpen) continue;
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gapLow = leftBarHigh;
      gapHigh = rightBarLow;
    }
    else
    {
      if (leftBarLow <= rightBarHigh) continue;
      if (midClose >= midOpen) continue;
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gapHigh = leftBarLow;
      gapLow = rightBarHigh;
    }

    datetime createdTime = iTime(_Symbol, InpMiddleTF, i - 1);
    if (IsFVGInPool(createdTime)) continue;

    if (g_FVGCount >= MAX_FVG_POOL)
    {
      int evictIndex = -1;
      datetime oldestTime = TimeCurrent();
      for (int j = 0; j < g_FVGCount; j++)
        if (g_FVGPool[j].status == FVG_USED && g_FVGPool[j].createdTime < oldestTime)
          { oldestTime = g_FVGPool[j].createdTime; evictIndex = j; }
      if (evictIndex < 0) { if (InpDebugLog) Print("[FVG POOL] Full"); break; }
      for (int j = evictIndex; j < g_FVGCount - 1; j++) g_FVGPool[j] = g_FVGPool[j + 1];
      g_FVGCount--;
      if      (g_ActiveFVGIdx >  evictIndex) g_ActiveFVGIdx--;
      else if (g_ActiveFVGIdx == evictIndex) g_ActiveFVGIdx = -1;
    }

    FVGRecord record;
    ZeroMemory(record);
    record.id = g_NextFVGId++;
    record.direction = trendDir;
    record.high = gapHigh;
    record.low = gapLow;
    record.mid = (gapHigh + gapLow) / 2.0;
    record.createdTime = createdTime;
    int rightBarIndex = i - 1;

    bool isBrokenByClose = false;
    datetime breakTime = 0;
    for (int j = rightBarIndex - 1; j >= 1; j--)
    {
      double closeAtJ = iClose(_Symbol, InpMiddleTF, j);
      if ((record.direction == DIR_UP   && closeAtJ < record.low) ||
          (record.direction == DIR_DOWN && closeAtJ > record.high))
        { isBrokenByClose = true; breakTime = iTime(_Symbol, InpMiddleTF, j); break; }
    }
    if (isBrokenByClose) { record.status = FVG_USED; record.usedCase = 1; record.usedTime = breakTime; }
    else
    {
      record.status = FVG_PENDING;
      if ((int)(TimeCurrent() - record.createdTime) > InpFVGMaxAliveMin * 60)
        { record.status = FVG_USED; record.usedCase = 0; record.usedTime = TimeCurrent(); }
    }

    g_FVGPool[g_FVGCount] = record;
    g_FVGCount++;

    if (InpDebugLog)
      PrintFormat("[FVG +] #%d %s [%.5f–%.5f] %s | %s",
        record.id, EnumToString(record.direction), record.low, record.high,
        EnumToString(record.status), TimeToString(record.createdTime));
  }
}

/** Updates status of each FVG in pool (broken, touched, MSS-triggered). TOUCHED chỉ chuyển USED khi broke hoặc MSS, không expire. */
inline void UpdateFVGStatuses()
{
  double bid            = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double lastBarClose   = iClose(_Symbol, InpMiddleTF, 1);
  datetime lastBarTime  = iTime (_Symbol, InpMiddleTF, 1);

  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;

    bool isBroken = (g_FVGPool[i].direction == DIR_UP   && lastBarClose < g_FVGPool[i].low) ||
                    (g_FVGPool[i].direction == DIR_DOWN && lastBarClose > g_FVGPool[i].high);
    if (isBroken)
    {
      g_FVGPool[i].status   = FVG_USED;
      g_FVGPool[i].usedCase = 1;
      g_FVGPool[i].usedTime = lastBarTime;
      if (InpDebugLog)
        PrintFormat("[FVG #%d] BROKEN | close=%.5f", g_FVGPool[i].id, lastBarClose);
      continue;
    }

    if (g_FVGPool[i].status == FVG_PENDING)
    {
      int ageSeconds = (int)(TimeCurrent() - g_FVGPool[i].createdTime);
      if (ageSeconds > InpFVGMaxAliveMin * 60)
      {
        g_FVGPool[i].status = FVG_USED;
        g_FVGPool[i].usedCase = 0;
        g_FVGPool[i].usedTime = TimeCurrent();
        continue;
      }

      double fvgRange   = g_FVGPool[i].high - g_FVGPool[i].low;
      double touchDepth = fvgRange * InpFVGTouchPct / 100.0;
      bool isTouched = (g_FVGPool[i].direction == DIR_UP   && bid <= g_FVGPool[i].high - touchDepth) ||
                       (g_FVGPool[i].direction == DIR_DOWN && bid >= g_FVGPool[i].low  + touchDepth);
      if (isTouched)
      {
        g_FVGPool[i].status              = FVG_TOUCHED;
        g_FVGPool[i].touchTime           = TimeCurrent();
        g_FVGPool[i].triggerTrendAtTouch = g_TriggerTrend.trend;
        if (InpDebugLog)
          PrintFormat("[FVG #%d] TOUCHED | bid=%.5f [%.5f–%.5f]",
            g_FVGPool[i].id, bid, g_FVGPool[i].low, g_FVGPool[i].high);
      }
    }
    else if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      bool hasMssAfterTouch =
        g_TriggerTrend.lastMssTime > g_FVGPool[i].touchTime &&
        g_TriggerTrend.lastMssBreak == g_FVGPool[i].direction;

      if (hasMssAfterTouch)
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 2;
        g_FVGPool[i].usedTime = TimeCurrent();
        g_FVGPool[i].mssTime  = g_TriggerTrend.lastMssTime;
        g_FVGPool[i].mssEntry = g_TriggerTrend.lastMssLevel;
        g_FVGPool[i].mssSL    = g_TriggerTrend.mssSLSwing;

        if (InpDebugLog)
          PrintFormat("[FVG #%d] TRIGGERED | MSS %s entry=%.5f SL=%.5f @ %s",
            g_FVGPool[i].id,
            (g_TriggerTrend.lastMssBreak == DIR_UP) ? "▲" : "▼",
            g_FVGPool[i].mssEntry, g_FVGPool[i].mssSL,
            TimeToString(g_FVGPool[i].mssTime, TIME_MINUTES));
      }
      // TOUCHED chỉ kết thúc khi BROKE (usedCase 1) hoặc MSS (usedCase 2); không expire theo thời gian.
    }
  }
}

/** Returns index of best active FVG (prefer TOUCHED, then newest by created time). */
inline int GetBestActiveFVGIdx()
{
  int bestIndex = -1;
  datetime bestCreatedTime = 0;
  bool foundTouched = false;
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;
    if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      if (!foundTouched || g_FVGPool[i].createdTime > bestCreatedTime)
        { foundTouched = true; bestIndex = i; bestCreatedTime = g_FVGPool[i].createdTime; }
    }
    else if (!foundTouched && g_FVGPool[i].createdTime > bestCreatedTime)
      { bestIndex = i; bestCreatedTime = g_FVGPool[i].createdTime; }
  }
  return bestIndex;
}

#endif
