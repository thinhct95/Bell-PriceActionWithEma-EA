#ifndef EA_ICT_CL__SESSIONS_MQH
#define EA_ICT_CL__SESSIONS_MQH  // Tránh include trùng

// Module: Sessions – kiểm tra giờ trong khoảng (UTC), dùng cho London/NY

inline bool IsHourInRange(const int hour, const int start_hour, const int end_hour)
{
  // start < end: [start, end); start > end: qua đêm [start,24) U [0,end)
  if (start_hour == end_hour) return true;  // Cả ngày
  if (start_hour < end_hour)  return (hour >= start_hour && hour < end_hour);  // Cùng ngày
  return (hour >= start_hour || hour < end_hour);  // Qua nửa đêm
}

inline int GetUTCHour(const datetime t)
{
  MqlDateTime dt;
  TimeToStruct(t, dt);  // Chuyển datetime sang struct (năm, tháng, giờ...)
  return dt.hour;      // Trả về giờ (0–23)
}

#endif // EA_ICT_CL__SESSIONS_MQH

