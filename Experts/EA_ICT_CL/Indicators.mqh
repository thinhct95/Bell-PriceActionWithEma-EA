#ifndef EA_ICT_CL__INDICATORS_MQH
#define EA_ICT_CL__INDICATORS_MQH

/** Copies indicator buffer into out[] (series); returns true only if copied count equals requested. */
inline bool CopyBufferSafe(const int handle, const int buffer, const int startPos, const int count, double &out[])
{
  if (handle == INVALID_HANDLE) return false;
  ArraySetAsSeries(out, true);
  const int copiedCount = CopyBuffer(handle, buffer, startPos, count, out);
  return (copiedCount == count);
}

/** Copies bar times into out[] (series); returns true only if copied count equals requested. */
inline bool CopyTimeSafe(const string symbol, const ENUM_TIMEFRAMES tf, const int startPos, const int count, datetime &out[])
{
  ArraySetAsSeries(out, true);
  const int copiedCount = CopyTime(symbol, tf, startPos, count, out);
  return (copiedCount == count);
}

#endif
