#ifndef EA_ICT_CL__SESSIONS_MQH
#define EA_ICT_CL__SESSIONS_MQH

// Module: Sessions
// Time/session filters live here (UTC-based if your EA uses UTC inputs).

inline bool IsHourInRange(const int hour, const int start_hour, const int end_hour)
{
  // Handles normal and overnight windows:
  // - start < end:  [start, end)
  // - start > end:  [start, 24) U [0, end)
  if (start_hour == end_hour) return true;
  if (start_hour < end_hour)  return (hour >= start_hour && hour < end_hour);
  return (hour >= start_hour || hour < end_hour);
}

inline int GetUTCHour(const datetime t)
{
  MqlDateTime dt;
  TimeToStruct(t, dt);
  return dt.hour;
}

#endif // EA_ICT_CL__SESSIONS_MQH

