#ifndef EA_ICT_CL__GUARDS_MQH
#define EA_ICT_CL__GUARDS_MQH

// Module: Guards
// Pre-trade guard checks extracted from EA_ICT_CL.mq5 (Section 3 – Guards).
// NOTE: Uses EA globals (g_*) and inputs. Include AFTER globals exist.

inline bool IsSessionAllowed()    { return true; /* TODO: implement session filter using InpLondon/NY hours */ }
inline bool IsDailyLossOK()       { return !g_DailyRisk.limitHit; }
inline bool IsBiasValid()         { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; }

inline bool IsMiddleTrendAligned()
{
  if (g_MiddleTrend.trend == DIR_NONE) return false;
  return (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP) ||
         (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN);
}

inline bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; }
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; }
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; }
  return true;
}

#endif // EA_ICT_CL__GUARDS_MQH

