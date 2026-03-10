#ifndef EA_ICT_CL__UTILS_MQH
#define EA_ICT_CL__UTILS_MQH

/** Clamps value to [lo, hi]. */
inline double ClampDouble(const double value, const double lo, const double hi)
{
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}

/** Clamps integer value to [lo, hi]. */
inline int ClampInt(const int value, const int lo, const int hi)
{
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}

/** Rounds value to nearest step (step must be > 0). */
inline double RoundToStep(const double value, const double step)
{
  if (step <= 0.0) return value;
  return MathRound(value / step) * step;
}

/** Returns true when current bar time differs from last processed bar time (new bar). */
inline bool IsNewBar(const datetime lastBarTime, const datetime currentBarTime)
{
  return (currentBarTime != 0 && currentBarTime != lastBarTime);
}

#endif
