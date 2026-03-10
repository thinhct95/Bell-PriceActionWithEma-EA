#ifndef EA_ICT_CL__SIGNALS_BOS_FVG_OB_MQH
#define EA_ICT_CL__SIGNALS_BOS_FVG_OB_MQH

// Module: Signals (FVG)
// Extracted from EA_ICT_CL.mq5 (Sections 5, 6, 7, 8).
// FVG helpers, scan/register, status update, best selector.
// NOTE: Uses EA globals (g_*) and inputs. Include AFTER globals exist.

//+------------------------------------------------------------------+
//|  SECTION 5 – FVG HELPERS                                         |
//+------------------------------------------------------------------+

inline bool IsCandleStrong(ENUM_TIMEFRAMES tf, int i)
{
  double h = iHigh(_Symbol, tf, i), l = iLow(_Symbol, tf, i);
  double o = iOpen(_Symbol, tf, i), c = iClose(_Symbol, tf, i);
  double range = h - l;
  if (range < _Point) return false;
  return (MathAbs(c - o) / range * 100.0) >= InpFVGMinBodyPct;
}

inline bool IsFVGInPool(datetime created)
{
  for (int j = 0; j < g_FVGCount; j++)
    if (g_FVGPool[j].createdTime == created) return true;
  return false;
}

//+------------------------------------------------------------------+
//|  SECTION 6 – FVG POOL: SCAN & REGISTER                          |
//+------------------------------------------------------------------+

inline void ScanAndRegisterFVGs()
{
  static datetime s_lastScan = 0;
  datetime t0 = iTime(_Symbol, InpMiddleTF, 0);
  if (t0 == s_lastScan) return;
  s_lastScan = t0;

  MarketDir dir = g_MiddleTrend.trend;
  if (dir == DIR_NONE) return;

  int maxBar = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2);

  for (int i = 2; i <= maxBar; i++)
  {
    double leftH  = iHigh (_Symbol, InpMiddleTF, i + 1);
    double leftL  = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightH = iHigh (_Symbol, InpMiddleTF, i - 1);
    double rightL = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midO   = iOpen (_Symbol, InpMiddleTF, i);
    double midC   = iClose(_Symbol, InpMiddleTF, i);
    double gH = 0, gL = 0;

    if (dir == DIR_UP)
    {
      if (leftH >= rightL) continue;
      if (midC <= midO) continue;
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gL = leftH; gH = rightL;
    }
    else
    {
      if (leftL <= rightH) continue;
      if (midC >= midO) continue;
      if (!IsCandleStrong(InpMiddleTF, i)) continue;
      gH = leftL; gL = rightH;
    }

    datetime created = iTime(_Symbol, InpMiddleTF, i - 1);
    if (IsFVGInPool(created)) continue;

    if (g_FVGCount >= MAX_FVG_POOL)
    {
      int evict = -1; datetime oldest = TimeCurrent();
      for (int j = 0; j < g_FVGCount; j++)
        if (g_FVGPool[j].status == FVG_USED && g_FVGPool[j].createdTime < oldest)
          { oldest = g_FVGPool[j].createdTime; evict = j; }
      if (evict < 0) { if (InpDebugLog) Print("[FVG POOL] Full"); break; }
      for (int j = evict; j < g_FVGCount - 1; j++) g_FVGPool[j] = g_FVGPool[j + 1];
      g_FVGCount--;
      if      (g_ActiveFVGIdx >  evict) g_ActiveFVGIdx--;
      else if (g_ActiveFVGIdx == evict) g_ActiveFVGIdx = -1;
    }

    FVGRecord rec;
    ZeroMemory(rec);
    rec.id = g_NextFVGId++; rec.direction = dir;
    rec.high = gH; rec.low = gL; rec.mid = (gH + gL) / 2.0;
    rec.createdTime = created;
    int rightBar = i - 1;

    bool c1Hit = false; datetime c1T = 0;
    for (int j = rightBar - 1; j >= 1; j--)
    {
      double cl = iClose(_Symbol, InpMiddleTF, j);
      if ((rec.direction == DIR_UP   && cl < rec.low) ||
          (rec.direction == DIR_DOWN && cl > rec.high))
        { c1Hit = true; c1T = iTime(_Symbol, InpMiddleTF, j); break; }
    }
    if (c1Hit) { rec.status = FVG_USED; rec.usedCase = 1; rec.usedTime = c1T; }
    else
    {
      bool tdHit = false; datetime tdT = 0;
      for (int j = rightBar - 1; j >= 1; j--)
      {
        bool inGap = (rec.direction == DIR_UP   && iLow (_Symbol, InpMiddleTF, j) <= rec.high) ||
                     (rec.direction == DIR_DOWN && iHigh(_Symbol, InpMiddleTF, j) >= rec.low);
        if (inGap) { tdHit = true; tdT = iTime(_Symbol, InpMiddleTF, j); break; }
      }
      if (tdHit) { rec.status = FVG_TOUCHED; rec.touchTime = tdT; rec.triggerTrendAtTouch = g_TriggerTrend.trend; }
      else
      {
        rec.status = FVG_PENDING;
        if ((int)(TimeCurrent() - rec.createdTime) > InpFVGMaxAliveMin * 60)
          { rec.status = FVG_USED; rec.usedCase = 0; rec.usedTime = TimeCurrent(); }
      }
    }

    g_FVGPool[g_FVGCount] = rec;
    g_FVGCount++;

    if (InpDebugLog)
      PrintFormat("[FVG +] #%d %s [%.5f–%.5f] %s | %s",
        rec.id, EnumToString(rec.direction), rec.low, rec.high,
        EnumToString(rec.status), TimeToString(rec.createdTime));
  }
}

//+------------------------------------------------------------------+
//|  SECTION 7 – FVG POOL: UPDATE STATUSES (every tick)             |
//+------------------------------------------------------------------+

inline void UpdateFVGStatuses()
{
  double   bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double   midC1 = iClose(_Symbol, InpMiddleTF, 1);
  datetime midT1 = iTime (_Symbol, InpMiddleTF, 1);

  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;

    bool c1 = (g_FVGPool[i].direction == DIR_UP   && midC1 < g_FVGPool[i].low) ||
              (g_FVGPool[i].direction == DIR_DOWN && midC1 > g_FVGPool[i].high);
    if (c1)
    {
      g_FVGPool[i].status   = FVG_USED;
      g_FVGPool[i].usedCase = 1;
      g_FVGPool[i].usedTime = midT1;
      if (InpDebugLog)
        PrintFormat("[FVG #%d] BROKEN | close=%.5f", g_FVGPool[i].id, midC1);
      continue;
    }

    if (g_FVGPool[i].status == FVG_PENDING)
    {
      int age = (int)(TimeCurrent() - g_FVGPool[i].createdTime);
      if (age > InpFVGMaxAliveMin * 60)
      {
        g_FVGPool[i].status = FVG_USED; g_FVGPool[i].usedCase = 0;
        g_FVGPool[i].usedTime = TimeCurrent();
        continue;
      }

      bool touched = (g_FVGPool[i].direction == DIR_UP   && bid <= g_FVGPool[i].high) ||
                     (g_FVGPool[i].direction == DIR_DOWN && bid >= g_FVGPool[i].low);
      if (touched)
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
      bool hasMSS =
        g_TriggerTrend.lastMssTime > g_FVGPool[i].touchTime &&
        g_TriggerTrend.lastMssBreak == g_FVGPool[i].direction;

      if (hasMSS)
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
        continue;
      }

      int ageMin = (int)((TimeCurrent() - g_FVGPool[i].createdTime) / 60);
      if (ageMin > InpFVGMaxAliveMin)
      {
        g_FVGPool[i].status   = FVG_USED;
        g_FVGPool[i].usedCase = 0;
        g_FVGPool[i].usedTime = TimeCurrent();

        if (g_ActiveFVGIdx >= 0
            && g_FVGPool[g_ActiveFVGIdx].id == g_FVGPool[i].id)
          g_ActiveFVGIdx = -1;

        if (InpDebugLog)
          PrintFormat("[FVG #%d] TOUCHED EXPIRED (age=%dmin > %d) → USED",
            g_FVGPool[i].id, ageMin, InpFVGMaxAliveMin);
      }
    }
  }
}

//+------------------------------------------------------------------+
//|  SECTION 8 – BEST FVG SELECTOR                                   |
//+------------------------------------------------------------------+

inline int GetBestActiveFVGIdx()
{
  int bestIdx = -1; datetime bestTime = 0; bool foundTouch = false;
  for (int i = 0; i < g_FVGCount; i++)
  {
    if (g_FVGPool[i].status == FVG_USED) continue;
    if (g_FVGPool[i].status == FVG_TOUCHED)
    {
      if (!foundTouch || g_FVGPool[i].createdTime > bestTime)
        { foundTouch = true; bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
    }
    else if (!foundTouch && g_FVGPool[i].createdTime > bestTime)
      { bestIdx = i; bestTime = g_FVGPool[i].createdTime; }
  }
  return bestIdx;
}

#endif // EA_ICT_CL__SIGNALS_BOS_FVG_OB_MQH
