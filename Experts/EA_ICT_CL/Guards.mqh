#ifndef EA_ICT_CL__GUARDS_MQH
#define EA_ICT_CL__GUARDS_MQH  // Tránh include trùng

// Module: Guards – điều kiện trước khi cho chạy state machine (session, daily loss, bias, alignment)

inline bool IsSessionAllowed()    { return true; /* TODO: lọc giờ London/NY theo InpLondonStartHour/End, InpNY... */ }
inline bool IsDailyLossOK()       { return !g_DailyRisk.limitHit; }  // Chưa chạm max daily loss
inline bool IsBiasValid()         { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; }  // Bias rõ (không NONE/SIDEWAY)

inline bool IsMiddleTrendAligned()
{
  if (g_MiddleTrend.trend == DIR_NONE) return false;  // H1 không có trend → không align
  return (g_Bias.bias == BIAS_UP   && g_MiddleTrend.trend == DIR_UP) ||
         (g_Bias.bias == BIAS_DOWN && g_MiddleTrend.trend == DIR_DOWN);  // D1 và H1 cùng chiều
}

inline bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed())     { g_BlockReason = BLOCK_SESSION;       return false; }  // Ngoài giờ trade
  if (!IsDailyLossOK())        { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }  // Đã chạm limit lỗ
  if (!IsBiasValid())          { g_BlockReason = BLOCK_NO_BIAS;       return false; }  // Không có bias
  if (!IsMiddleTrendAligned()) { g_BlockReason = BLOCK_BIAS_MISMATCH; return false; }  // D1 ≠ H1
  return true;  // Tất cả pass
}

#endif // EA_ICT_CL__GUARDS_MQH

