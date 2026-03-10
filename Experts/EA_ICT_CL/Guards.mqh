#ifndef EA_ICT_CL__GUARDS_MQH
#define EA_ICT_CL__GUARDS_MQH

/** True if within allowed session (currently always true). */
inline bool IsSessionAllowed()    { return true; }
/** True if daily loss limit has not been hit. */
inline bool IsDailyLossOK()       { return !g_DailyRisk.limitHit; }
/** True if bias is UP or DOWN (not NONE or SIDEWAY). */
inline bool IsBiasValid()         { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; }

/** True if H1 trend aligns with D1 bias (same direction). */
inline bool IsMiddleTrendAligned()
{
  if (g_MiddleTrend.trend == DIR_NONE) return false;
  return (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP) ||
         (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN);
}

/** Evaluates all guards; sets g_BlockReason and returns false if any guard fails. */
inline bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; }
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; }
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; }
  return true;
}

#endif
