#ifndef EA_ICT_CL__LOGGING_MQH
#define EA_ICT_CL__LOGGING_MQH  // Tránh include trùng

// Module: Logging – in log ra Journal khi bật InpDebugLog

inline void LogPrint(const bool enabled, const string msg)
{
  if (!enabled) return;  // Tắt log thì thoát
  Print(msg);             // In chuỗi ra Experts/Journal
}

inline void LogPrintF(const bool enabled, const string fmt, const string a0 = "", const string a1 = "", const string a2 = "")
{
  if (!enabled) return;  // Tắt log thì thoát
  Print(StringFormat(fmt, a0, a1, a2));  // Format rồi in (tối đa 3 tham số string)
}

#endif // EA_ICT_CL__LOGGING_MQH

