#ifndef EA_ICT_CL__SWING_MQH
#define EA_ICT_CL__SWING_MQH

/** Returns bar index (series) for given time; -1 if not found or exact and no match. */
inline int MyBarShift(string symbol, ENUM_TIMEFRAMES tf, datetime time, bool exact = false)
{
  datetime arr[];
  int maxBarsToCopy = MathMin(Bars(symbol, tf), 5000);
  int copiedCount = CopyTime(symbol, tf, 0, maxBarsToCopy, arr);
  if (copiedCount <= 0) return -1;

  for (int i = copiedCount - 1; i >= 0; i--)
  {
    if (arr[i] <= time)
      return copiedCount - 1 - i;
  }
  return exact ? -1 : copiedCount - 1;
}

/** Returns swing range (number of bars each side) per timeframe. */
inline int GetSwingRangeForTf(ENUM_TIMEFRAMES tf)
{
  if (tf == InpMiddleTF)  return InpMiddleTfSwingRange;
  if (tf == InpTriggerTF) return InpTriggerTfSwingRange;
  return InpMiddleTfSwingRange;
}

/** True if bar at index i is a swing high (swingRange bars each side lower). */
inline bool IsSwingHighAt(ENUM_TIMEFRAMES tf, int barIndex)
{
  int swingRange = GetSwingRangeForTf(tf);
  double highAtBar = iHigh(_Symbol, tf, barIndex);
  for (int k = 1; k <= swingRange; k++)
    if (iHigh(_Symbol, tf, barIndex - k) >= highAtBar || iHigh(_Symbol, tf, barIndex + k) >= highAtBar) return false;
  return true;
}

/** True if bar at index i is a swing low (swingRange bars each side higher). */
inline bool IsSwingLowAt(ENUM_TIMEFRAMES tf, int barIndex)
{
  int swingRange = GetSwingRangeForTf(tf);
  double lowAtBar = iLow(_Symbol, tf, barIndex);
  for (int k = 1; k <= swingRange; k++)
    if (iLow(_Symbol, tf, barIndex - k) <= lowAtBar || iLow(_Symbol, tf, barIndex + k) <= lowAtBar) return false;
  return true;
}

/** Scans for two most recent swing highs and two most recent swing lows; fills out params, returns true if all found. */
inline bool ScanSwingStructure(
  ENUM_TIMEFRAMES tf, int lookback,
  double &h0, double &h1, int &idxH0, int &idxH1,
  double &l0, double &l1, int &idxL0, int &idxL1)
{
  int swingRange = GetSwingRangeForTf(tf);
  int maxBar = MathMin(lookback, Bars(_Symbol, tf) - swingRange - 2);
  double highs[2]; int hiIdx[2]; int highCount = 0;
  double lows [2]; int loIdx[2]; int lowCount  = 0;

  for (int i = swingRange + 1; i <= maxBar; i++)
  {
    if (highCount < 2 && IsSwingHighAt(tf, i)) { highs[highCount] = iHigh(_Symbol, tf, i); hiIdx[highCount] = i; highCount++; }
    if (lowCount  < 2 && IsSwingLowAt (tf, i)) { lows [lowCount]  = iLow (_Symbol, tf, i); loIdx[lowCount]  = i; lowCount++;  }
    if (highCount == 2 && lowCount == 2) break;
  }
  if (highCount < 2 || lowCount < 2) return false;

  h0 = highs[0]; idxH0 = hiIdx[0];
  h1 = highs[1]; idxH1 = hiIdx[1];
  l0 = lows [0]; idxL0 = loIdx[0];
  l1 = lows [1]; idxL1 = loIdx[1];
  return true;
}

/** Resolves trend and key level from swing highs/lows and last close. */
inline void ResolveTrendFromSwings(
  ENUM_TIMEFRAMES tf,
  double h0, double h1, double l0, double l1,
  MarketDir &trend, double &keyLevel)
{
  double lastClose = iClose(_Symbol, tf, 1);
  if      (h0 > h1 && l0 > l1 && lastClose > l0) { trend = DIR_UP;   keyLevel = l0; }
  else if (h0 < h1 && l0 < l1 && lastClose < h0) { trend = DIR_DOWN; keyLevel = h0; }
  else                                          { trend = DIR_NONE; keyLevel = 0; }
}

#endif
