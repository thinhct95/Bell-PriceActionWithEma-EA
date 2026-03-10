#ifndef EA_ICT_CL__INDICATORS_MQH
#define EA_ICT_CL__INDICATORS_MQH

// Module: Indicators
// Keep indicator handle lifecycle helpers here. This file is safe to include now.

inline bool CopyBufferSafe(const int handle, const int buffer, const int start_pos, const int count, double &out[])
{
  if (handle == INVALID_HANDLE) return false;
  ArraySetAsSeries(out, true);
  const int copied = CopyBuffer(handle, buffer, start_pos, count, out);
  return (copied == count);
}

inline bool CopyTimeSafe(const string symbol, const ENUM_TIMEFRAMES tf, const int start_pos, const int count, datetime &out[])
{
  ArraySetAsSeries(out, true);
  const int copied = CopyTime(symbol, tf, start_pos, count, out);
  return (copied == count);
}

#endif // EA_ICT_CL__INDICATORS_MQH

