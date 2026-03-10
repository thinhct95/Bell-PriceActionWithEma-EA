#ifndef EA_ICT_CL__SESSIONS_MQH
#define EA_ICT_CL__SESSIONS_MQH

/** True if hour (0–23) falls in [startHour, endHour); supports overnight range. */
inline bool IsHourInRange(const int hour, const int startHour, const int endHour)
{
  if (startHour == endHour) return true;
  if (startHour < endHour)  return (hour >= startHour && hour < endHour);
  return (hour >= startHour || hour < endHour);
}

/** Returns hour (0–23) in UTC for given datetime. */
inline int GetUTCHour(const datetime t)
{
  MqlDateTime dt;
  TimeToStruct(t, dt);
  return dt.hour;
}

#endif
