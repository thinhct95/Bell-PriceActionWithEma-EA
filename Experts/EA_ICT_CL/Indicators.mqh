#ifndef EA_ICT_CL__INDICATORS_MQH
#define EA_ICT_CL__INDICATORS_MQH  // Tránh include trùng

// Module: Indicators – copy dữ liệu buffer/time an toàn (series index 0 = mới nhất)

inline bool CopyBufferSafe(const int handle, const int buffer, const int start_pos, const int count, double &out[])
{
  if (handle == INVALID_HANDLE) return false;  // Handle không hợp lệ
  ArraySetAsSeries(out, true);                 // Index 0 = bar mới nhất
  const int copied = CopyBuffer(handle, buffer, start_pos, count, out);  // Copy dữ liệu indicator
  return (copied == count);  // Thành công khi copy đủ count phần tử
}

inline bool CopyTimeSafe(const string symbol, const ENUM_TIMEFRAMES tf, const int start_pos, const int count, datetime &out[])
{
  ArraySetAsSeries(out, true);  // Index 0 = bar mới nhất
  const int copied = CopyTime(symbol, tf, start_pos, count, out);  // Copy thời gian mở bar
  return (copied == count);     // Thành công khi copy đủ count
}

#endif // EA_ICT_CL__INDICATORS_MQH

