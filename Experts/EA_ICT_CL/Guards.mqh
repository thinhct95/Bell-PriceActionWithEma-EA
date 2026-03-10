#ifndef EA_ICT_CL__GUARDS_MQH
#define EA_ICT_CL__GUARDS_MQH

/** True if current time (UTC) is within London or NY session (InpLondon* / InpNY*). */
inline bool IsSessionAllowed()
{
  int hourUtc = GetUTCHour(TimeCurrent());
  return IsHourInRange(hourUtc, InpLondonStartHour, InpLondonEndHour)
      || IsHourInRange(hourUtc, InpNYStartHour, InpNYEndHour);
}
/** True if daily loss limit has not been hit. */
inline bool IsDailyLossOK() { return !g_DailyRisk.limitHit; }
/** True if middle TF has a clear trend (UP or DOWN). */
inline bool IsMiddleTrendValid() { return g_MiddleTrend.trend != DIR_NONE; }

/** Evaluates all guards; sets g_BlockReason and returns false if any guard fails. */
inline bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed())    { g_BlockReason = BLOCK_SESSION;    return false; }
  if (!IsDailyLossOK())       { g_BlockReason = BLOCK_DAILY_LOSS; return false; }
  if (!IsMiddleTrendValid())  { g_BlockReason = BLOCK_NO_TREND;   return false; }
  return true;
}

#endif
