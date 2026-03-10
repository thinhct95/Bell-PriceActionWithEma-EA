#ifndef EA_ICT_CL__UTILS_MQH
#define EA_ICT_CL__UTILS_MQH  // Tránh include trùng

// Module: Utils – helper không phụ thuộc logic EA (clamp, round, new bar)

inline double ClampDouble(const double v, const double lo, const double hi)
{
  if (v < lo) return lo;   // Nhỏ hơn min → trả về min
  if (v > hi) return hi;   // Lớn hơn max → trả về max
  return v;                // Nằm trong [lo,hi] → giữ nguyên
}

inline int ClampInt(const int v, const int lo, const int hi)
{
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

inline double RoundToStep(const double value, const double step)
{
  if (step <= 0.0) return value;  // Step không hợp lệ → không làm tròn
  return MathRound(value / step) * step;  // Làm tròn theo bước step
}

inline bool IsNewBar(const datetime last_bar_time, const datetime current_bar_time)
{
  return (current_bar_time != 0 && current_bar_time != last_bar_time);  // Bar mới khi thời gian bar đổi
}

#endif // EA_ICT_CL__UTILS_MQH

