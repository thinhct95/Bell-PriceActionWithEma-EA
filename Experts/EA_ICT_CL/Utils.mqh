#ifndef EA_ICT_CL__UTILS_MQH
#define EA_ICT_CL__UTILS_MQH

// Module: Utils
// Put small, dependency-free helpers here (time, rounding, clamps, formatting).

inline double ClampDouble(const double v, const double lo, const double hi)
{
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

inline int ClampInt(const int v, const int lo, const int hi)
{
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

inline double RoundToStep(const double value, const double step)
{
  if (step <= 0.0) return value;
  return MathRound(value / step) * step;
}

inline bool IsNewBar(const datetime last_bar_time, const datetime current_bar_time)
{
  return (current_bar_time != 0 && current_bar_time != last_bar_time);
}

#endif // EA_ICT_CL__UTILS_MQH

