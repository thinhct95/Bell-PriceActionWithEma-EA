#ifndef EA_ICT_CL__LOGGING_MQH
#define EA_ICT_CL__LOGGING_MQH

/** Prints message to Journal when enabled. */
inline void LogPrint(const bool enabled, const string msg)
{
  if (!enabled) return;
  Print(msg);
}

/** Prints formatted string (up to 3 string args) to Journal when enabled. */
inline void LogPrintF(const bool enabled, const string fmt, const string a0 = "", const string a1 = "", const string a2 = "")
{
  if (!enabled) return;
  Print(StringFormat(fmt, a0, a1, a2));
}

#endif
