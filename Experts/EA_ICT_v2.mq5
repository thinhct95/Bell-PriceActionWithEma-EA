//+------------------------------------------------------------------+
//| EA: ICT v2                                                       |
//| Mục đích: Setup ICT đồng thuận trend 3 timeframes                |
//| Người tạo: Bell CW                                     |
//+------------------------------------------------------------------+
#property copyright "Bell CW"
#property version   "2.00"
#property strict

// Bật/tắt MSS detection cho từng TF
input bool DetectMSS_HTF = true;
input bool DetectMSS_MTF = true;
input bool DetectMSS_LTF = false;

// Cấu hình Swing
input int           htfSwingRange = 1;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           mtfSwingRange = 10;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           ltfSwingRange = 10;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           SwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

// Cấu hình vẽ Swing trên chart
input bool   ShowSwingMarkers = true;      // Hiển thị các marker swing trên chart
input string SwingObjPrefix   = "Swing_"; // Tiền tố tên object (dễ xóa/điều chỉnh)
input int    SwingMarkerFontSize    = 10;        // Kích thước font cho label

input int FVGLookback = 200;   // Số nến lookback khi tính FVG (dùng ở EnsureFVGUpToDate)

input bool   PrintToExperts = true;    // In log ra Expert

// --- lưu trend đã tính cho mỗi slot ---
// slot 0 = HTF, 1 = MTF, 2 = LTF
int TrendTF[3]; // 1 = up, -1 = down, 0 = sideway / unknown

input ENUM_TIMEFRAMES HighTF = PERIOD_D1;    // Khung thời gian cao
input ENUM_TIMEFRAMES MiddleTF = PERIOD_H1;  // Khung thời gian trung bình (dùng để tìm FVG)
input ENUM_TIMEFRAMES LowTF = PERIOD_M5;    // Khung thời gian thấp (Tìm điểm vào lệnh)

// --- multi-TF swing storage (slots) ---
// slot 0 = HighTF, slot 1 = MiddleTF, slot 2 = LowTF
// dimension: [slot][index]  (index 0 = nearest, 1 = older)
double SwingHighPriceTF[3][2];
datetime SwingHighTimeTF[3][2];
int    SwingHighCountTF[3];

double SwingLowPriceTF[3][2];
datetime SwingLowTimeTF[3][2];
int    SwingLowCountTF[3];

// --- cấu hình cho trend provisional (phát hiện sớm) ---
input int ProvisionalBreakPips = 5; // số pips để coi là phá sớm (change-as-you-like)
input int ProvisionalConsecCloses = 1; // số nến đóng liên tiếp vượt level để xác nhận provisional (thường 1 hoặc 2)

// FVG results (global)
double FVG_top[];        // giá trên của zone (lớn hơn)
double FVG_bottom[];     // giá dưới của zone (nhỏ hơn)
datetime FVG_timeA[];    // time của bar A (older)
datetime FVG_timeC[];    // time của bar C (newer)
int    FVG_type[];       //  1 = bullish, -1 = bearish
int    FVG_count = 0;

// last closed bar time per slot (index 0=HighTF,1=MiddleTF,2=LowTF)
datetime lastClosedBarTime[3] = {0,0,0};

// cache last FVG compute time (bar C or bar index 1 time used to detect change)
datetime lastFVGBarTime = 0;

// struct dùng để trả thông tin khi phát hiện MSS
struct MSSInfo {
  bool  found;                 // true nếu tìm thấy MSS
  int   direction;             //  1 = down->up (bull MSS), -1 = up->down (bear MSS)
  datetime sweep_time;         // thời điểm bar "sweep" (bar quét thanh khoản)
  double sweep_price;          // giá (râu) bị sweep (low cho bull, high cho bear)
  // --- thêm: swing gốc đã bị swept (time/price) ---
  datetime swept_swing_time;   // time của swing bar trước khi bị sweep (ví dụ l0/h0 tại thời điểm detect)
  double   swept_swing_price;  // giá swing gốc

  double key_level;            // mức key level (swing cần phá)
  datetime break_time;         // thời điểm bar phá key level (thỏa điều kiện break)
  // --- thêm: swing gốc bị broken (time/price) ---
  datetime broken_swing_time;  // time của swing bar bị phá (ví dụ sh0/sl0 tại thời điểm detect)
  double   broken_swing_price; // giá swing gốc bị phá
};

// ---------------------- Helper: pip size ----------------------
// Trả về 1 "pip" cho symbol (không phải point). 
// Lý do: nhiều broker dùng 5 chữ số (0.00001) => pip = point*10; 4 chữ số => pip = point.
double GetPipSize(string symbol)
{
  // Lấy số chữ số (digits) và point của symbol
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

  // Quy ước phổ biến:
  // - digits 5 hoặc 3 => broker dùng extra digit -> 1 pip = point * 10
  // - digits 4 hoặc 2 => 1 pip = point
  // Việc dùng pip (không phải point) thuận tiện để người dùng nhập ngưỡng theo pips (ví dụ 30 pips).
  if(digits==5 || digits==3) return point * 10.0;
  return point;
}

bool HasBullFVGAfter(string symbol, ENUM_TIMEFRAMES timeframe, datetime after_time, int fvgLookback)
{
   FindFVG(symbol, timeframe, fvgLookback); // cập nhật FVG_count và FVG_* arrays

   for(int k = 0; k < FVG_count; k++)
   {
      if(FVG_type[k] == 1 && FVG_timeC[k] > after_time)
         return true;
   }
   return false;
}

bool HasBearFVGAfter(string symbol, ENUM_TIMEFRAMES timeframe, datetime after_time, int fvgLookback)
{
   FindFVG(symbol, timeframe, fvgLookback);

   for(int k = 0; k < FVG_count; k++)
   {
      if(FVG_type[k] == -1 && FVG_timeC[k] > after_time)
         return true;
   }
   return false;
}



// ---------------------- Hàm chính: DetectMSSOnSlot ----------------------
// Mục tiêu: xác định Market Structure Shift (MSS) trên một timeframe (slot).
// - Dùng các swing đã tính sẵn: SwingHighPriceTF[slot][*], SwingLowPriceTF[slot][*]
// - Có thể yêu cầu FVG xuất hiện sau sweep (requireFVG = true)
// Tham số:
//   symbol            : ký hiệu (Symbol())
//   timeframe         : timeframe để kiểm tra (ví dụ MiddleTF)
//   slot              : index trong mảng swings (0=HTF,1=MTF,2=LTF trong EA của bạn)
//   minBreakPips      : số pips tối thiểu để coi là "phá" key level (ví dụ 30 pips)
//   minConsec         : số nến liên tiếp cùng màu sau sweep để chứng minh momentum
//   lookbackBarsForSweep : số bar tối đa quét tìm bar sweep sau swing (giảm chi phí tính toán)
//   fvgLookback       : nếu dùng FVG, đưa vào FindFVG(..., fvgLookback)
//   requireFVG        : nếu true, bắt buộc phải có FVG loại phù hợp xuất hiện sau sweep
MSSInfo DetectMSSOnSlot(
        string symbol, ENUM_TIMEFRAMES timeframe, int slot,
        double minBreakPips = 5.0,
        int minConsec = 2,
        int lookbackBarsForSweep = 50,
        int fvgLookback = 200,
        bool requireFVG = true)
{
   MSSInfo result;
   result.found = false;
   result.direction = 0;
   result.sweep_time = 0;
   result.sweep_price = 0.0;
   result.key_level = 0.0;
   result.break_time = 0;

   if(PrintToExperts)
     PrintFormat("DetectMSSOnSlot START: sym=%s tf=%s slot=%d minBreakPips=%.1f minConsec=%d lookback=%d requireFVG=%s",
                 symbol, EnumToString(timeframe), slot, minBreakPips, minConsec, lookbackBarsForSweep, (requireFVG ? "true":"false"));

   // cần ít nhất 2 swing high + 2 swing low
   if(SwingHighCountTF[slot] < 2 || SwingLowCountTF[slot] < 2)
   {
      if(PrintToExperts)
        PrintFormat("DetectMSSOnSlot slot=%d: not enough swings H=%d L=%d -> exit", slot, SwingHighCountTF[slot], SwingLowCountTF[slot]);
      return result;
   }

   // lấy swing (index 0 = nearest, 1 = older)
   double sh0 = SwingHighPriceTF[slot][0];
   double sh1 = SwingHighPriceTF[slot][1];
   double sl0 = SwingLowPriceTF[slot][0];
   double sl1 = SwingLowPriceTF[slot][1];

   if(PrintToExperts)
     PrintFormat("DetectMSSOnSlot slot=%d swings: sh0=%.5f sh1=%.5f sl0=%.5f sl1=%.5f",
                 slot, sh0, sh1, sl0, sl1);

   double pip = GetPipSize(symbol);
   double minBreakPoints = minBreakPips * pip;
   double tol = SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.5;

   int barsAvailable = iBars(symbol, timeframe);
   if(barsAvailable <= 3)
   {
     if(PrintToExperts) PrintFormat("DetectMSSOnSlot slot=%d: not enough bars (%d) -> exit", slot, barsAvailable);
     return result;
   }
   int maxScan = MathMin(lookbackBarsForSweep, barsAvailable - 1);

   // trend đã tính trước và lưu vào TrendTF[]
   int currentTrend = TrendTF[slot];

   if(PrintToExperts)
     PrintFormat("DetectMSSOnSlot slot=%d currentTrend=%d maxScan=%d minBreakPoints=%.8f tol=%.8f",
                 slot, currentTrend, maxScan, minBreakPoints, tol);

   // ----------------------- BULLISH PATH -----------------------
   // Logic (updated): swept = sl0 (nearest low), key_level = sh0 (nearest high)
   if(currentTrend == -1 || currentTrend == 0)
   {
      double sweptLow = sl0;       // đáy gần nhất phải bị sweep
      double key_level = sh0;      // đỉnh gần nhất cần bị phá để xác nhận MSS (breaker)
      if(PrintToExperts) PrintFormat("DetectMSSOnSlot slot=%d BULL check: sweptLow=%.5f key_level=%.5f", slot, sweptLow, key_level);

      for(int idx = 1; idx <= maxScan; idx++)
      {
         double low_i   = iLow(symbol, timeframe, idx);
         double close_i = iClose(symbol, timeframe, idx);
         datetime t_i   = iTime(symbol, timeframe, idx);

         if(low_i == 0 || close_i == 0) continue;

         // sweep xuống dưới sweptLow và đóng trở lại trên sweptLow
         if(low_i < sweptLow - tol && close_i > sweptLow + tol)
         {
            if(PrintToExperts)
              PrintFormat("slot=%d idx=%d: potential BULL sweep at low=%.5f close=%.5f sweptLow=%.5f t=%s",
                          slot, idx, low_i, close_i, sweptLow, TimeToString(t_i, TIME_DATE|TIME_MINUTES));

            // check momentum (nến xanh liên tiếp ngay sau sweep)
            int consec = 0;
            int j = idx - 1;
            while(j >= 0 && consec < minConsec)
            {
               double c_j = iClose(symbol, timeframe, j);
               double o_j = iOpen(symbol, timeframe, j);
               if(c_j == 0 || o_j == 0) break;
               if(c_j > o_j) consec++; else break;
               j--;
            }
            if(PrintToExperts) PrintFormat("slot=%d idx=%d: consec green=%d required=%d", slot, idx, consec, minConsec);

            if(consec >= minConsec)
            {
               bool fvg_ok = true;
               if(requireFVG)
                  fvg_ok = HasBullFVGAfter(symbol, timeframe, t_i, fvgLookback);

               if(PrintToExperts && requireFVG) PrintFormat("slot=%d idx=%d: fvg_ok=%s", slot, idx, (fvg_ok?"true":"false"));

               if(fvg_ok)
               {
                  // tìm breaker: nến đóng >= key_level + threshold
                  bool broke = false;
                  datetime break_time = 0;
                  for(int k = idx - 1; k >= 0; k--)
                  {
                     double close_k = iClose(symbol, timeframe, k);
                     if(close_k == 0) continue;
                     if(close_k >= key_level + minBreakPoints)
                     {
                        broke = true;
                        break_time = iTime(symbol, timeframe, k);
                        if(PrintToExperts)
                          PrintFormat("slot=%d idx=%d: breaker at k=%d close=%.5f (>= %.5f) t=%s",
                                      slot, idx, k, close_k, key_level + minBreakPoints, TimeToString(break_time, TIME_DATE|TIME_MINUTES));
                        break;
                     }
                  }

                  if(broke)
                  {
                    result.found = true;
                    result.direction = 1;
                    result.sweep_time = t_i;
                    result.sweep_price = low_i;
                    result.key_level = key_level;
                    result.break_time = break_time;

                    // --- lưu swing gốc tại thời điểm detect ---
                    // swept swing = nearest low at detect time => sl0 (index 0)
                    result.swept_swing_time  = SwingLowTimeTF[slot][0];
                    result.swept_swing_price = SwingLowPriceTF[slot][0];
                    // broken swing (key) = nearest high sh0 (index 0)
                    result.broken_swing_time  = SwingHighTimeTF[slot][0];
                    result.broken_swing_price = SwingHighPriceTF[slot][0];

                     if(PrintToExperts)
                       PrintFormat("DetectMSSOnSlot slot=%d -> BULL MSS FOUND sweep=%.5f key=%.5f break=%s",
                                   slot, result.sweep_price, result.key_level, TimeToString(result.break_time, TIME_DATE|TIME_MINUTES));
                     return result;
                  }
                  else
                  {
                     if(PrintToExperts) PrintFormat("slot=%d idx=%d: no breaker after sweep (need >= %.5f)", slot, idx, key_level + minBreakPoints);
                  }
               }
            }
         } // end if sweep
      } // end for idx
      if(PrintToExperts) PrintFormat("DetectMSSOnSlot slot=%d: finished BULL checks, not found", slot);
   }

   // ----------------------- BEARISH PATH -----------------------
   // Logic (updated): swept = sh0 (nearest high), key_level = sl0 (nearest low)
   if(currentTrend == 1 || currentTrend == 0)
   {
      double sweptHigh = sh0;     // đỉnh gần nhất phải bị sweep
      double key_level = sl0;     // đáy gần nhất cần bị phá để xác nhận MSS (breaker)
      if(PrintToExperts) PrintFormat("DetectMSSOnSlot slot=%d BEAR check: sweptHigh=%.5f key_level=%.5f", slot, sweptHigh, key_level);

      for(int idx = 1; idx <= maxScan; idx++)
      {
         double high_i  = iHigh(symbol, timeframe, idx);
         double close_i = iClose(symbol, timeframe, idx);
         datetime t_i   = iTime(symbol, timeframe, idx);

         if(high_i == 0 || close_i == 0) continue;

         // sweep lên trên sweptHigh và đóng trở lại dưới sweptHigh
         if(high_i > sweptHigh + tol && close_i < sweptHigh - tol)
         {
            if(PrintToExperts)
              PrintFormat("slot=%d idx=%d: potential BEAR sweep at high=%.5f close=%.5f sweptHigh=%.5f t=%s",
                          slot, idx, high_i, close_i, sweptHigh, TimeToString(t_i, TIME_DATE|TIME_MINUTES));

            // check momentum (nến đỏ liên tiếp)
            int consec = 0;
            int j = idx - 1;
            while(j >= 0 && consec < minConsec)
            {
               double c_j = iClose(symbol, timeframe, j);
               double o_j = iOpen(symbol, timeframe, j);
               if(c_j == 0 || o_j == 0) break;
               if(c_j < o_j) consec++; else break;
               j--;
            }
            if(PrintToExperts) PrintFormat("slot=%d idx=%d: consec red=%d required=%d", slot, idx, consec, minConsec);

            if(consec >= minConsec)
            {
               bool fvg_ok = true;
               if(requireFVG)
                  fvg_ok = HasBearFVGAfter(symbol, timeframe, t_i, fvgLookback);

               if(PrintToExperts && requireFVG) PrintFormat("slot=%d idx=%d: fvg_ok=%s", slot, idx, (fvg_ok?"true":"false"));

               if(fvg_ok)
               {
                  // tìm breaker: nến đóng <= key_level - threshold
                  bool broke = false;
                  datetime break_time = 0;
                  for(int k = idx - 1; k >= 0; k--)
                  {
                     double close_k = iClose(symbol, timeframe, k);
                     if(close_k == 0) continue;
                     if(close_k <= key_level - minBreakPoints)
                     {
                        broke = true;
                        break_time = iTime(symbol, timeframe, k);
                        if(PrintToExperts)
                          PrintFormat("slot=%d idx=%d: breaker at k=%d close=%.5f (<= %.5f) t=%s",
                                      slot, idx, k, close_k, key_level - minBreakPoints, TimeToString(break_time, TIME_DATE|TIME_MINUTES));
                        break;
                     }
                  }

                  if(broke)
                  {
                    result.found = true;
                    result.direction = -1;
                    result.sweep_time = t_i;
                    result.sweep_price = high_i;
                    result.key_level = key_level;
                    result.break_time = break_time;

                    // lưu swing gốc
                    result.swept_swing_time  = SwingHighTimeTF[slot][0];
                    result.swept_swing_price = SwingHighPriceTF[slot][0];
                    // broken swing (key) = nearest low sl0
                    result.broken_swing_time  = SwingLowTimeTF[slot][0];
                    result.broken_swing_price = SwingLowPriceTF[slot][0];

                     if(PrintToExperts)
                       PrintFormat("DetectMSSOnSlot slot=%d -> BEAR MSS FOUND sweep=%.5f key=%.5f break=%s",
                                   slot, result.sweep_price, result.key_level, TimeToString(result.break_time, TIME_DATE|TIME_MINUTES));
                     return result;
                  }
                  else
                  {
                     if(PrintToExperts) PrintFormat("slot=%d idx=%d: no breaker after sweep (need <= %.5f)", slot, idx, key_level - minBreakPoints);
                  }
               }
            }
         } // end if sweep up
      } // end for idx
      if(PrintToExperts) PrintFormat("DetectMSSOnSlot slot=%d: finished BEAR checks, not found", slot);
   }

   if(PrintToExperts) PrintFormat("DetectMSSOnSlot END: slot=%d not found any MSS", slot);
   return result;
}

// Kiểm tra 1 bar tại index i có phải SwingHigh không (dùng giá đóng cửa theo yêu cầu)
// Kiểm tra 1 bar tại index i có phải SwingHigh không (xét râu - High)
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES timeframe, int candleIndex, int swingRange)
{
  double hi = iHigh(symbol, timeframe, candleIndex);
  if(hi == 0.0) return false;

  // So sánh với X nến trước (index giảm)
  for(int i = 1; i <= swingRange; i++)
  {
    int idxPrev = candleIndex - i;
    if(idxPrev < 0) return false; // không đủ dữ liệu
    double hprev = iHigh(symbol, timeframe, idxPrev);
    if(hprev == 0.0) return false; // dữ liệu thiếu
    if(hprev >= hi) // nếu có râu high trước >= hi -> không phải swing high
      return false;
  }

  // So sánh với X nến sau (index tăng)
  for(int k = 1; k <= swingRange; k++)
  {
    int idxNext = candleIndex + k;
    // nếu idxNext vượt quá bars available -> không có dữ liệu đủ -> return false
    double hnext = iHigh(symbol, timeframe, idxNext);
    if(hnext == 0.0) return false;
    if(hnext >= hi) // nếu có râu high sau >= hi -> không phải swing high
      return false;
  }

  return true;
}

// Kiểm tra 1 bar tại index i có phải SwingLow không (xét râu - Low)
bool IsSwingLow(string symbol, ENUM_TIMEFRAMES timeframe, int i, int X)
{
  double lo = iLow(symbol, timeframe, i);
  if(lo == 0.0) return false;

  // So sánh với X nến trước (index giảm)
  for(int j = 1; j <= X; j++)
  {
    int idxPrev = i - j;
    if(idxPrev < 0) return false; // không đủ dữ liệu
    double lprev = iLow(symbol, timeframe, idxPrev);
    if(lprev == 0.0) return false; // dữ liệu thiếu
    if(lprev <= lo) // nếu râu low trước <= lo -> không phải swing low
      return false;
  }

  // So sánh với X nến sau (index tăng)
  for(int k = 1; k <= X; k++)
  {
    int idxNext = i + k;
    double lnext = iLow(symbol, timeframe, idxNext);
    if(lnext == 0.0) return false;
    if(lnext <= lo) // nếu râu low sau <= lo -> không phải swing low
      return false;
  }

  return true;
}

// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ SwingKeep phần tử gần nhất)
// UpdateSwings vào slot (0 = HighTF, 1 = MiddleTF)
// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ SwingKeep phần tử gần nhất)
// UpdateSwings vào slot (0 = HighTF, 1 = MiddleTF)
void UpdateSwings(string symbol, ENUM_TIMEFRAMES timeframe, int slot, int SwingRange)
{
  // Reset slot
  SwingHighCountTF[slot] = 0;
  SwingLowCountTF[slot]  = 0;

  int total = iBars(symbol, timeframe);
  if(total <= SwingRange + 2) return; // dữ liệu không đủ

  int iStart = SwingRange + 1;
  int iEnd   = total - SwingRange - 1;

  // Duyệt từ index nhỏ (gần nhất) tới xa để tìm Swing gần nhất trước
  for(int i = iStart; i <= iEnd; i++)
  {
    // nếu đã đủ cả 2 loại thì dừng
    if(SwingHighCountTF[slot] >= SwingKeep && SwingLowCountTF[slot] >= SwingKeep) break;

    // Kiểm tra SwingHigh bằng hàm tiện ích
    if(SwingHighCountTF[slot] < SwingKeep)
    {
      bool isH = IsSwingHigh(symbol, timeframe, i, SwingRange);
      if(isH)
      {
        double ci = iHigh(symbol, timeframe, i);
        datetime ti = iTime(symbol, timeframe, i);
        if(SwingHighCountTF[slot] == 0)
        {
          SwingHighPriceTF[slot][0] = ci;
          SwingHighTimeTF[slot][0]  = ti;
        }
        else
        {
          SwingHighPriceTF[slot][1] = ci;
          SwingHighTimeTF[slot][1]  = ti;
        }
        SwingHighCountTF[slot]++;
        if(PrintToExperts) PrintFormat("UpdateSwings slot=%d Found SwingHigh #%d tf=%s price=%.5f", slot, SwingHighCountTF[slot], EnumToString(timeframe), ci);
      }
    }

    // Kiểm tra SwingLow bằng hàm tiện ích
    if(SwingLowCountTF[slot] < SwingKeep)
    {
      bool isL = IsSwingLow(symbol, timeframe, i, SwingRange);
      if(isL)
      {
        double ci2 = iLow(symbol, timeframe, i);
        datetime ti2 = iTime(symbol, timeframe, i);
        if(SwingLowCountTF[slot] == 0)
        {
          SwingLowPriceTF[slot][0] = ci2;
          SwingLowTimeTF[slot][0]  = ti2;
        }
        else
        {
          SwingLowPriceTF[slot][1] = ci2;
          SwingLowTimeTF[slot][1]  = ti2;
        }
        SwingLowCountTF[slot]++;
        if(PrintToExperts) PrintFormat("UpdateSwings slot=%d Found SwingLow #%d tf=%s price=%.5f", slot, SwingLowCountTF[slot], EnumToString(timeframe), ci2);
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Vẽ SwingHigh & SwingLow lên chart                                 |
//+------------------------------------------------------------------+
// Draw swings for the given timeframe (uses stored slot arrays)
// Draw swings for the given timeframe (uses stored slot arrays)
// Updated: use explicit prefixes "htf_" and "MTF_" and delete only matching objects
void DrawSwingsOnChart(ENUM_TIMEFRAMES timeframe)
{
  if(!ShowSwingMarkers) return;

  // mapping chung: 0=HTF, 1=MTF, 2=LTF
  int slot = 0; // default 0=HTF
  string inChartSwingPrefix = "h";

  if(timeframe == MiddleTF) {
    slot = 1;
    inChartSwingPrefix = "m";
  } else if (timeframe == LowTF) {
    slot = 2;
    inChartSwingPrefix = "l";
  }

  string prefix = SwingObjPrefix + inChartSwingPrefix;

  // Xóa các marker cũ chỉ theo prefix này (không xóa chung tất cả SwingObjPrefix)
  int total = ObjectsTotal(0);

  for(int i = total - 1; i >= 0; i--)
  {
    string name = ObjectName(0, i);
    if(StringLen(name) >= StringLen(prefix))
    {
        if(StringSubstr(name, 0, StringLen(prefix)) == prefix)
          ObjectDelete(0, name);
    }
  }

   // Thời lượng bar (giây)
   datetime bar_secs = (datetime)PeriodSeconds(timeframe);

   // Vẽ Swing High
   int maxH = (SwingHighCountTF[slot] < SwingKeep) ? SwingHighCountTF[slot] : SwingKeep;
   for(int h = 0; h < maxH; h++)
   {
      string obj = prefix + "H_" + IntegerToString(h); // e.g. "HTF_SW_mid_H_0"
      datetime t = SwingHighTimeTF[slot][h];
      double price = SwingHighPriceTF[slot][h];
      datetime display_time_h = (datetime)(t + (bar_secs/2));

      if(t == 0 || price == 0.0) continue; 
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_h, price))
      {
         Print("Cannot create object: ", obj);
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT,  "▲ " + inChartSwingPrefix + "H" + IntegerToString(h));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
   }

   // Vẽ Swing Low
   int maxL = (SwingLowCountTF[slot] < SwingKeep) ? SwingLowCountTF[slot] : SwingKeep;
   for(int l = 0; l < maxL; l++)
   {
      string obj = prefix + "L_" + IntegerToString(l);
      datetime t = SwingLowTimeTF[slot][l];
      double price = SwingLowPriceTF[slot][l];
      datetime display_time_l = (datetime)(t + (bar_secs/2));
      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, display_time_l, price))
      {
         Print("Cannot create object: ", obj);
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT, "▼ " + inChartSwingPrefix +"L" + IntegerToString(l));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_TOP);
      ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
   }
}

// ---------------------------------------------------------------------
// FindTouchTime(): tìm thời điểm bar đầu tiên sau start_time mà bar chạm price
// ---------------------------------------------------------------------
datetime FindTouchTime(string symbol, ENUM_TIMEFRAMES timeframe,
                       datetime start_time, double price, double tol, datetime bar_secs)
{
   // Lấy index bar tại thời điểm start_time
   int idxStart = iBarShift(symbol, timeframe, start_time, false);
   if(idxStart == -1) idxStart = 0;

   // Quét các bar mới hơn (index nhỏ hơn)
   for(int idx = idxStart - 1; idx >= 0; idx--)
   {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      // Nếu bar chạm price
      if(lowM <= price + tol && highM >= price - tol)
         return iTime(symbol, timeframe, idx);
   }

   // Không tìm thấy → kéo đến bar hiện tại + 1 bar
   datetime t0 = iTime(symbol, timeframe, 0);
   if(t0 != 0) return (datetime)((long)t0 + (long)bar_secs);

   return TimeCurrent();
}

// DrawMss: vẽ MSS + liquidity sweep cho 1 slot/timeframe
// symbol      : symbol (Symbol())
// timeframe   : timeframe (MiddleTF / HighTF / LowTF ...)
// info        : MSSInfo struct (result của DetectMSSOnSlot) - truyền bằng tham chiếu
// slot        : 0=HTF,1=MTF,2=LTF (dùng để phân biệt object name và xoá cũ)
// DrawMss: vẽ MSS + liquidity sweep cho 1 slot/timeframe
// symbol      : symbol (Symbol())
// timeframe   : timeframe (MiddleTF / HighTF / LowTF ...)
// info        : MSSInfo struct (result của DetectMSSOnSlot) - truyền bằng tham chiếu
// slot        : 0=HTF,1=MTF,2=LTF (dùng để phân biệt object name và xoá cũ)
void DrawMss(string symbol, ENUM_TIMEFRAMES timeframe, const MSSInfo &info, int slot)
{
  if(!ShowSwingMarkers) return;

  // tiền tố timeframe cho tên object
  string tfPrefix = "ltf_";
  if(slot == 0) tfPrefix = "htf_";
  else if(slot == 1) tfPrefix = "mtf_";

  string basePrefix = SwingObjPrefix + "MSS_" + IntegerToString(slot) + "_";

  // Xóa object MSS cũ cho slot này
  int total = ObjectsTotal(0);
  for(int i = total - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringLen(nm) >= StringLen(basePrefix))
      if(StringSubstr(nm, 0, StringLen(basePrefix)) == basePrefix)
        ObjectDelete(0, nm);
  }

  if(!info.found) {
    PrintFormat("Error: DrawMss: no MSS found for slot=%d, nothing to draw", slot);
    return;
  }

  if(info.sweep_time == 0 || info.break_time == 0) {
    PrintFormat("Error: DrawMss: invalid MSSInfo for slot=%d (sweep_time=%d break_time=%d)", slot, info.sweep_time, info.break_time);
    return;
  }

  // object names (có tiền tố tfPrefix)
  string nm_sweep_ray = basePrefix + tfPrefix + "SWEEP_RAY";
  string nm_key_ray   = basePrefix + tfPrefix + "KEY_RAY";
  string nm_sweep_txt = basePrefix + tfPrefix + "SWEEP_TXT";
  string nm_key_txt   = basePrefix + tfPrefix + "KEY_TXT";

  // style
  int col_sweep = clrMagenta; // màu sweep (tím)
  int col_key   = clrOrange;  // màu key/break
  int width_line = 2;
  int font_sweep = SwingMarkerFontSize + 2;
  int font_key   = SwingMarkerFontSize;

  datetime bar_secs = (datetime)PeriodSeconds(timeframe);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // --- SWEEP RAY ---
  // End of sweep ray is the sweep bar (info.sweep_time, info.sweep_price)
  datetime end_sweep_time = info.sweep_time;
  double   end_sweep_price = info.sweep_price;
  if(end_sweep_time == 0) end_sweep_time = iTime(symbol, timeframe, 0);
  if(end_sweep_price == 0.0) end_sweep_price = (info.direction == 1 ? SwingLowPriceTF[slot][0] : SwingHighPriceTF[slot][0]);

  // Start of sweep ray must be the swing bar that was swept:
  // - bullish (direction==1): start from SwingLow index 0 (l0)
  // - bearish (direction==-1): start from SwingHigh index 0 (h0)
  datetime start_sweep_time = end_sweep_time;
  double   start_sweep_price = end_sweep_price;

  // ưu tiên dùng swing gốc đã lưu trong info (nếu có)
  if(info.swept_swing_time != 0 && info.swept_swing_price != 0.0)
  {
    start_sweep_time  = info.swept_swing_time;
    start_sweep_price = info.swept_swing_price;
  }
  else
  {
    // fallback: dùng current Swing arrays nếu info không có
    if(info.direction == 1)
    {
      if(SwingLowTimeTF[slot][0] != 0 && SwingLowPriceTF[slot][0] != 0.0)
      {
        start_sweep_time  = SwingLowTimeTF[slot][0];
        start_sweep_price = SwingLowPriceTF[slot][0];
      }
    }
    else if(info.direction == -1)
    {
      if(SwingHighTimeTF[slot][0] != 0 && SwingHighPriceTF[slot][0] != 0.0)
      {
        start_sweep_time  = SwingHighTimeTF[slot][0];
        start_sweep_price = SwingHighPriceTF[slot][0];
      }
    }
  }

  // Draw sweep ray from start_sweep -> sweep bar (end_sweep)
  if(!ObjectCreate(0, nm_sweep_ray, OBJ_TREND, 0,
                   start_sweep_time, start_sweep_price,
                   end_sweep_time,   end_sweep_price))
    PrintFormat("DrawMss: Cannot create %s", nm_sweep_ray);

  ObjectSetInteger(0, nm_sweep_ray, OBJPROP_COLOR, col_sweep);
  ObjectSetInteger(0, nm_sweep_ray, OBJPROP_WIDTH, width_line);
  ObjectSetInteger(0, nm_sweep_ray, OBJPROP_STYLE, STYLE_SOLID);
  ObjectSetInteger(0, nm_sweep_ray, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, nm_sweep_ray, OBJPROP_BACK, true);

  // sweep label (ở giữa đoạn)
  datetime mid_sweep = (datetime)(((long)start_sweep_time + (long)end_sweep_time)/2);
  if(!ObjectCreate(0, nm_sweep_txt, OBJ_TEXT, 0, mid_sweep, end_sweep_price))
    PrintFormat("DrawMss: Cannot create %s", nm_sweep_txt);
  else
  {
    ObjectSetString(0, nm_sweep_txt, OBJPROP_TEXT,
                    StringFormat("%sSweep: %s", tfPrefix, DoubleToString(end_sweep_price, _Digits)));
    ObjectSetInteger(0, nm_sweep_txt, OBJPROP_COLOR, col_sweep);
    ObjectSetInteger(0, nm_sweep_txt, OBJPROP_FONTSIZE, font_sweep);
    ObjectSetInteger(0, nm_sweep_txt, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm_sweep_txt, OBJPROP_BACK, true);
  }

  // --- KEY / BREAKER RAY ---
  // Start of key ray should be the broken swing bar (sh0 for bullish breaker, sl0 for bearish breaker)
  datetime start_key_time = info.break_time;
  double   start_key_price = info.key_level;

  // ưu tiên dùng broken swing gốc đã lưu trong info
  if(info.broken_swing_time != 0 && info.broken_swing_price != 0.0)
  {
    start_key_time  = info.broken_swing_time;
    start_key_price = info.broken_swing_price;
  }
  else
  {
    // fallback: dùng current Swing arrays
    if(info.direction == 1)
    {
      if(SwingHighTimeTF[slot][0] != 0 && SwingHighPriceTF[slot][0] != 0.0)
      {
        start_key_time  = SwingHighTimeTF[slot][0];
        start_key_price = SwingHighPriceTF[slot][0];
      }
    }
    else if(info.direction == -1)
    {
      if(SwingLowTimeTF[slot][0] != 0 && SwingLowPriceTF[slot][0] != 0.0)
      {
        start_key_time  = SwingLowTimeTF[slot][0];
        start_key_price = SwingLowPriceTF[slot][0];
      }
    }
  }

  // End of key ray: use close price of breaker bar (info.break_time). If not available fallback to key_level
  double end_key_price = info.key_level;
  datetime end_key_time = info.break_time;
  if(end_key_time != 0)
  {
    int idxBreak = iBarShift(symbol, timeframe, end_key_time, false);
    if(idxBreak >= 0)
    {
      double closeBreak = iClose(symbol, timeframe, idxBreak);
      if(closeBreak != 0.0) end_key_price = closeBreak;
      // set end_key_time to the exact time of that bar (safe)
      end_key_time = iTime(symbol, timeframe, idxBreak);
    }
    else
    {
      // fallback to current bar time + 1
      datetime t0 = iTime(symbol, timeframe, 0);
      end_key_time = (t0 != 0) ? (datetime)((long)t0 + (long)bar_secs) : TimeCurrent();
    }
  }
  else
  {
    // if no break_time, extend to current + 1 bar
    datetime t0 = iTime(symbol, timeframe, 0);
    end_key_time = (t0 != 0) ? (datetime)((long)t0 + (long)bar_secs) : TimeCurrent();
  }

  // Draw key ray from start_key -> breaker close (end_key)
  if(!ObjectCreate(0, nm_key_ray, OBJ_TREND, 0,
                   start_key_time, start_key_price,
                   end_key_time,   end_key_price))
    PrintFormat("DrawMss: Cannot create %s", nm_key_ray);

  ObjectSetInteger(0, nm_key_ray, OBJPROP_COLOR, col_key);
  ObjectSetInteger(0, nm_key_ray, OBJPROP_WIDTH, width_line);
  ObjectSetInteger(0, nm_key_ray, OBJPROP_STYLE, STYLE_DOT);
  ObjectSetInteger(0, nm_key_ray, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, nm_key_ray, OBJPROP_BACK, true);

  // key label (ở giữa đoạn)
  datetime mid_key = (datetime)(((long)start_key_time + (long)end_key_time)/2);
  if(!ObjectCreate(0, nm_key_txt, OBJ_TEXT, 0, mid_key, end_key_price))
    PrintFormat("DrawMss: Cannot create %s", nm_key_txt);
  else
  {
    ObjectSetString(0, nm_key_txt, OBJPROP_TEXT,
                    StringFormat("%sBreak: %s", tfPrefix, DoubleToString(info.key_level, _Digits)));
    ObjectSetInteger(0, nm_key_txt, OBJPROP_COLOR, col_key);
    ObjectSetInteger(0, nm_key_txt, OBJPROP_FONTSIZE, font_key);
    ObjectSetInteger(0, nm_key_txt, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, nm_key_txt, OBJPROP_BACK, true);
  }

  if(PrintToExperts)
  {
    PrintFormat("DrawMss: [%s] SWEEP start=%s price=%.5f -> sweepAt=%s price=%.5f | KEY start=%s price=%.5f -> breakerAt=%s price=%.5f",
                tfPrefix,
                TimeToString(start_sweep_time, TIME_DATE|TIME_MINUTES), start_sweep_price,
                TimeToString(end_sweep_time, TIME_DATE|TIME_MINUTES), end_sweep_price,
                TimeToString(start_key_time, TIME_DATE|TIME_MINUTES), start_key_price,
                TimeToString(end_key_time, TIME_DATE|TIME_MINUTES), end_key_price);
  }
}

// Hàm tiện ích chuyển giá trị xu hướng thành chuỗi
string TrendToString(int trend)
{
  if(trend==1) return "UPTREND";
  if(trend==-1) return "DOWNTREND";
  return "SIDEWAY";
}

// Cập nhật TrendTF[slot] dựa trên 2 swing gần nhất (không gọi UpdateSwings bên trong)
// Bổ sung: phát hiện sớm (provisional) dựa trên các nến đóng gần nhất nếu swing chưa hoàn chỉnh
void UpdateTrendForSlot(int slot, ENUM_TIMEFRAMES timeframe, string symbol)
{
  // mặc định giữ trend hiện tại (không reset về 0 ngay lập tức để tránh flicker)
  int oldTrend = TrendTF[slot];

  // Tolerances / thresholds
  double pip = GetPipSize(symbol);
  double provisionalThresh = (double)ProvisionalBreakPips * pip;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // Nếu không có đủ dữ liệu swing, ta vẫn sẽ thử provisional detection
  bool haveTwoSwings = (SwingHighCountTF[slot] >= 2 && SwingLowCountTF[slot] >= 2);

  // Lấy giá swing (index 0 = nearest, 1 = older). Có thể = 0 nếu chưa có.
  double sh0 = (SwingHighCountTF[slot] >= 1) ? SwingHighPriceTF[slot][0] : 0.0;
  double sh1 = (SwingHighCountTF[slot] >= 2) ? SwingHighPriceTF[slot][1] : 0.0;
  double sl0 = (SwingLowCountTF[slot] >= 1) ? SwingLowPriceTF[slot][0] : 0.0;
  double sl1 = (SwingLowCountTF[slot] >= 2) ? SwingLowPriceTF[slot][1] : 0.0;

  int newTrend = oldTrend; // default giữ trend cũ nếu không xác định được

  // 1) Rule "cứng" nếu có đủ 2 swings (như trước)
  if(haveTwoSwings)
  {
    if(sh0 > sh1 && sl0 > sl1) newTrend = 1;      // uptrend
    else if(sh0 < sh1 && sl0 < sl1) newTrend = -1; // downtrend
    else newTrend = 0; // không rõ
  }
  else
  {
    // nếu chưa có đủ swings, tạm giữ oldTrend (sẽ có chance bị override bởi provisional)
    newTrend = oldTrend;
  }

  // 2) Provisional / early detection:
  // Nếu swing "cứng" không xác định được (newTrend == 0) hoặc chúng ta thiếu swings,
  // thử kiểm tra xem last closed candle(s) đã đóng vượt sh0/sl0 chưa => áp provisional.
  // Lấy last closed candle close (index 1)
  double lastClosedClose = iClose(symbol, timeframe, 1);
  if(lastClosedClose == 0.0) lastClosedClose = iClose(symbol, timeframe, 0); // fallback

  int provisionalTrend = 0;
  if(sh0 != 0.0 && lastClosedClose > sh0 + provisionalThresh)
    provisionalTrend = 1;
  else if(sl0 != 0.0 && lastClosedClose < sl0 - provisionalThresh)
    provisionalTrend = -1;

  if(provisionalTrend != 0)
  {
    // Nếu chúng ta có provisionalTrend, xác nhận bằng số nến đóng liên tiếp (ProvisionalConsecCloses)
    int countClosers = 0;
    for(int i = 1; i <= ProvisionalConsecCloses; i++)
    {
      double c = iClose(symbol, timeframe, i);
      if(c == 0.0) break;
      if(provisionalTrend == 1)
      {
        if(c > sh0 + provisionalThresh) countClosers++;
        else break;
      }
      else // provisionalTrend == -1
      {
        if(c < sl0 - provisionalThresh) countClosers++;
        else break;
      }
    }

    if(countClosers >= ProvisionalConsecCloses)
    {
      // Áp provisional nếu: (a) không có trend cứng (newTrend==0) hoặc (b) thiếu swings (haveTwoSwings==false)
      // hoặc bạn muốn provisional override cả khi newTrend khác (cẩn trọng) - ở đây ta chỉ override khi newTrend == 0 hoặc không đủ swings
      if(!haveTwoSwings || newTrend == 0)
      {
        newTrend = provisionalTrend;
        if(PrintToExperts)
          PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisionalTrend applied=%d (sh0=%.5f sl0=%.5f lastClose=%.5f thresh=%.5f count=%d)",
                      slot, EnumToString(timeframe), newTrend, sh0, sl0, lastClosedClose, provisionalThresh, countClosers);
      }
      else
      {
        // Nếu bạn muốn provisional override ngay cả khi haveTwoSwings==true && newTrend != 0,
        // uncomment dòng dưới đây (cẩn thận: có thể gây false positives)
        // newTrend = provisionalTrend;
        if(PrintToExperts)
          PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisional candidate=%d but two-swing trend exists=%d -> not applied",
                      slot, EnumToString(timeframe), provisionalTrend, newTrend);
      }
    }
    else
    {
      if(PrintToExperts)
        PrintFormat("UpdateTrendForSlot slot=%d tf=%s: provisional candidate=%d NOT confirmed, consecutive closes=%d (required %d)",
                    slot, EnumToString(timeframe), provisionalTrend, countClosers, ProvisionalConsecCloses);
    }
  }

  // Ghi kết quả vào biến global TrendTF
  TrendTF[slot] = newTrend;

  if(PrintToExperts)
    PrintFormat("UpdateTrendForSlot slot=%d tf=%s -> TrendTF=%d (haveTwoSwings=%s sh0=%.5f sh1=%.5f sl0=%.5f sl1=%.5f lastClose=%.5f)",
                slot, EnumToString(timeframe), TrendTF[slot], (haveTwoSwings ? "true":"false"),
                sh0, sh1, sl0, sl1, lastClosedClose);
}

//+------------------------------------------------------------------+
//| FindFVG - tìm Fair Value Gaps trên timeframe cho symbol         |
//| symbol: chuỗi symbol (Symbol())                                  |
//| timeframe: ENUM_TIMEFRAMES (ví dụ PERIOD_H1)                     |
//| lookback: số nến đóng (ví dụ 200)                                |
//| returns: số FVG tìm được (và ghi vào mảng global FVG_*)           |
//+------------------------------------------------------------------+
int FindFVG(string symbol, ENUM_TIMEFRAMES timeframe, int lookback)
{
  // reset kết quả cũ
  ArrayFree(FVG_top); ArrayFree(FVG_bottom); ArrayFree(FVG_timeA); ArrayFree(FVG_timeC); ArrayFree(FVG_type);
  FVG_count = 0;

  // total closed bars available
  int total = iBars(symbol, timeframe);
  if(total < 5) return 0;

  // lấy số nến tối đa quét (chỉ nến đóng: index >=1)
  int maxScan = MathMin(lookback, total - 3); // cần ít nhất 3 bar cho một triple
  if(maxScan <= 0) return 0;

  // tolerance nhỏ theo pip để tránh noise
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // quét: i = index của bar C (mới nhất trong triple), i từ 1..maxScan
  // triple: A = i+2 (older), B = i+1 (middle), C = i (newer) --- tất cả là nến đã đóng
  for(int i = 1; i <= maxScan; i++)
  {
    int idxA = i + 2;
    int idxB = i + 1;
    int idxC = i;

    if(idxA > total - 1) break; // không đủ bars

    // lấy giá High/Low (dùng râu để FVG)
    double highA = iHigh(symbol, timeframe, idxA);
    double lowA  = iLow(symbol, timeframe, idxA);
    double highC = iHigh(symbol, timeframe, idxC);
    double lowC  = iLow(symbol, timeframe, idxC);

    if(highA == 0 || lowA == 0 || highC == 0 || lowC == 0) continue; // skip nếu dữ liệu thiếu

    // --- Bullish FVG: low(C) > high(A) ---
    if(lowC > highA + tol)
    {
      double top = lowC;
      double bottom = highA;
      // tránh trùng lặp: nếu đã có zone với top/bottom tương tự -> skip
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVG_top[k] - top) <= tol && MathAbs(FVG_bottom[k] - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        // append
        ArrayResize(FVG_top, FVG_count+1);
        ArrayResize(FVG_bottom, FVG_count+1);
        ArrayResize(FVG_timeA, FVG_count+1);
        ArrayResize(FVG_timeC, FVG_count+1);
        ArrayResize(FVG_type, FVG_count+1);

        FVG_top[FVG_count] = top;
        FVG_bottom[FVG_count] = bottom;
        FVG_timeA[FVG_count] = iTime(symbol, timeframe, idxA);
        FVG_timeC[FVG_count] = iTime(symbol, timeframe, idxC);
        FVG_type[FVG_count] = 1;
        FVG_count++;
      }
      continue; // không cần kiểm tra bearish nếu đã bullish cho triple này
    }

    // --- Bearish FVG: high(C) < low(A) ---
    if(highC < lowA - tol)
    {
      double top = lowA;    // top > bottom
      double bottom = highC;
      bool dup = false;
      for(int k = 0; k < FVG_count; k++)
      {
        if(MathAbs(FVG_top[k] - top) <= tol && MathAbs(FVG_bottom[k] - bottom) <= tol) { dup = true; break; }
      }
      if(!dup)
      {
        ArrayResize(FVG_top, FVG_count+1);
        ArrayResize(FVG_bottom, FVG_count+1);
        ArrayResize(FVG_timeA, FVG_count+1);
        ArrayResize(FVG_timeC, FVG_count+1);
        ArrayResize(FVG_type, FVG_count+1);

        FVG_top[FVG_count] = top;
        FVG_bottom[FVG_count] = bottom;
        FVG_timeA[FVG_count] = iTime(symbol, timeframe, idxA);
        FVG_timeC[FVG_count] = iTime(symbol, timeframe, idxC);
        FVG_type[FVG_count] = -1;
        FVG_count++;
      }
    }
  }

  return FVG_count;
}

//+------------------------------------------------------------------+
//| Make ARGB color with alpha (0..255)                              |
//+------------------------------------------------------------------+
uint MakeARGB(int a, uint clr)
{
  if(a < 0) a = 0; if(a > 255) a = 255;
  return ((uint)a << 24) | (clr & 0x00FFFFFF);
}

//+------------------------------------------------------------------+
//| DrawFVG: vẽ tất cả FVG đã tìm được cho symbol & timeframe        |
//| symbol: chuỗi symbol (ví dụ Symbol())                            |
//| timeframe: ENUM_TIMEFRAMES (ví dụ MiddleTF)                      |
//| startFromCBar: nếu true thì vẽ start time = FVG_timeC (mặc định) |
//+------------------------------------------------------------------+
void DrawFVG(string symbol, ENUM_TIMEFRAMES timeframe, bool startFromCBar = true)
{
  if(!ShowSwingMarkers) return;
  // prefix object để dễ xóa
  string prefix = SwingObjPrefix + "FVG_";

  // Xóa các FVG cũ (theo prefix)
  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, prefix, 0) == 0)
      ObjectDelete(0, nm);
  }

  // Nếu không có FVG nào thì return
  if(FVG_count <= 0) return;

  // Thời gian bar (giây) — dùng kiểu datetime để không gây cảnh báo cast
  datetime bar_secs = (datetime)PeriodSeconds(timeframe);

  // Tolerance cho việc detect touch
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol = (point > 0.0) ? point * 0.5 : 0.0;

  // Mỗi FVG: xác định thời điểm kết thúc (time2) khi price chạm zone, hoặc thời điểm hiện tại
  for(int k = 0; k < FVG_count; k++)
  {
    double top = FVG_top[k];
    double bottom = FVG_bottom[k];
    datetime timeC = FVG_timeC[k]; // bar C (mới hơn) - dùng làm start
    datetime timeA = FVG_timeA[k];

    // start time: chọn timeC (bar C) hoặc timeA tùy flag
    datetime start_time = startFromCBar ? timeC : timeA;

    // tìm bar sau timeC (index nhỏ hơn) mà chạm zone (quét forward)
    // xác định index của bar C
    int idxC = iBarShift(symbol, timeframe, timeC, false);
    if(idxC == -1) idxC = 0; // fallback

    bool touched = false;
    datetime end_time = TimeCurrent(); // fallback -> hiện tại

    // quét các bar mới hơn (idx = idxC-1, idxC-2, ..., 0)
    for(int idx = idxC - 1; idx >= 0; idx--)
    {
      double highM = iHigh(symbol, timeframe, idx);
      double lowM  = iLow(symbol, timeframe, idx);
      if(highM == 0 || lowM == 0) continue;

      // Nếu bar này *chạm* zone: nghĩa là phạm vi bar overlap zone
      if(lowM <= top + tol && highM >= bottom - tol)
      {
        touched = true;
        end_time = iTime(symbol, timeframe, idx);
        break;
      }
    }

    // Nếu không tìm thấy bar chạm, set end_time = thời điểm đóng bar hiện tại của timeframe
    if(!touched)
    {
      // lấy time của bar index 0 (nến đóng gần nhất)
      datetime t0 = iTime(symbol, timeframe, 0);
      if(t0 != 0) end_time = t0 + bar_secs; // kéo tới đầu nến hiện tại + 1 bar để dễ nhìn
      else end_time = TimeCurrent();
    }

    // chuẩn hoá: nếu end_time <= start_time thì kéo end_time = start_time + 1 bar
    if(end_time <= start_time) end_time = (datetime)( (long)start_time + (long)bar_secs );

    // Tạo object rectangle name
    string obj = prefix + IntegerToString(k);

    // MQL5 rectangle: ObjectCreate(..., OBJ_RECTANGLE, 0, time1, price1, time2, price2)
    // Tôi đặt (time1= start_time, price1= top) và (time2 = end_time, price2 = bottom)
    // (hàm sẽ tự vẽ vùng giữa top & bottom và thời gian start->end)
    if(!ObjectCreate(0, obj, OBJ_RECTANGLE, 0, start_time, top, end_time, bottom))
    {
      PrintFormat("DrawFVG: Không thể tạo rectangle %s", obj);
      continue;
    }

    // Set properties: không selectable, show in background
    ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, obj, OBJPROP_HIDDEN, false);
    ObjectSetInteger(0, obj, OBJPROP_BACK, true);

    // Màu: bullish = xanh mờ, bearish = đỏ mờ
    uint fill_alpha = 80; // 0..255 (0 trong suốt, 255 đặc)
    uint border_alpha = 0; // border trong suốt

    uint color_fill;
    if(FVG_type[k] == 1) // bullish
    {
      color_fill = MakeARGB((int)fill_alpha, clrDodgerBlue);
    }
    else // bearish
    {
      color_fill = MakeARGB((int)fill_alpha, clrCrimson);
    }

    uint col_border = MakeARGB((int)border_alpha, clrBlack);

    // Gán màu (một số terminal dùng OBJPROP_COLOR cho fill khi màu có alpha)
    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)col_border);
    // Một số terminal/phiên bản chấp nhận OBJPROP_FILL - nếu không có, property sẽ bị bỏ qua
    // Cố gắng set cả những thuộc tính khả dĩ:
    ObjectSetInteger(0, obj, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, obj, OBJPROP_WIDTH, 1);
    // OBJPROP_COLOR đã set cho border; set màu fill bằng property OBJPROP_BACKGROUND_COLOR nếu có
    // Một số build MQL5 hỗ trợ OBJPROP_BACKCOLOR (không chuẩn), ta thử set tên sau (nếu không hợp lệ compiler sẽ báo)
    // Dùng ObjectSetInteger/Set to attempt; nếu compiler báo lỗi bạn có thể xóa những dòng thử nghiệm này.
    #ifdef __MQL5__
    // try to set fill via OBJPROP_COLOR with alpha (already set), also attempt OBJPROP_COLOR by ObjectSetInteger above
    #endif

    // Set fill by using ObjectSetInteger for OBJPROP_COLOR (again) - terminals usually honor alpha channel
    ObjectSetInteger(0, obj, OBJPROP_COLOR, (int)color_fill);

    // Nếu terminal hỗ trợ OBJPROP_FILL (some do), bật nó:
    // Note: if your compiler complains about OBJPROP_FILL, remove the following line.
    // ObjectSetInteger(0, obj, OBJPROP_FILL, 1);

    // Done for this zone
  } // end for FVG
}

// ------------------------------------------------------------
// UpdateLabel: vẽ label cho 1 timeframe bất kỳ
// labelName  : tên object label muốn hiển thị
// timeframe  : timeframe cần hiển thị (HighTF / MiddleTF / LowTF ...)
// trend      : giá trị trend 1 / 0 / -1
// ------------------------------------------------------------
// ------------------------------------------------------------
// UpdateLabel: vẽ label cho 1 timeframe bất kỳ (không còn hardcode)
// labelName  : tên object label muốn hiển thị (ví dụ "LBL_HTF", "LBL_MTF")
// timeframe  : timeframe cần hiển thị (HighTF / MiddleTF / ...)
// trend      : giá trị trend 1 / 0 / -1
// ------------------------------------------------------------
void UpdateLabel(string labelName, ENUM_TIMEFRAMES timeframe, int trend)
{
    if(!ShowSwingMarkers) return;

    string txt = StringFormat("%s: %s", EnumToString(timeframe), TrendToString(trend));

    // vị trí chung (corner + distance mặc định)
    int corner = CORNER_LEFT_UPPER;
    int xdist  = 10;
    int ydist_default = 20;
    int ydist = ydist_default;

    // nếu timeframe giống MiddleTF (khung nhỏ hơn) -> dịch xuống thêm 1 hàng
    // bạn có thể tinh chỉnh offset_down tuỳ ý (ví dụ 20 px)
    int offset_down = 30;
    if (timeframe == MiddleTF) ydist = ydist_default + offset_down;
    else if(timeframe == LowTF) ydist = ydist_default + offset_down * 2;


    // Nếu object đã tồn tại -> cập nhật text và giữ vị trí
    if(ObjectFind(0, labelName) >= 0)
    {
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);
        // cập nhật màu (giữ vị trí)
        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
    else
    {
        // Tạo label mới với vị trí xác định
        if(!ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0))
        {
            Print("UpdateLabel: Không thể tạo object label: ", labelName);
            return;
        }
        ObjectSetInteger(0, labelName, OBJPROP_CORNER, corner);
        ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, xdist);
        ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, ydist);
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, SwingMarkerFontSize);
        ObjectSetString(0, labelName, OBJPROP_TEXT, txt);

        // Set màu theo trend
        if(trend == 1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrLime);
        else if(trend == -1) ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        else ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGray);
    }
}

// Trả true nếu bar đóng mới xuất hiện (dựa vào iTime(...,1))
bool IsNewClosedBar(string symbol, ENUM_TIMEFRAMES tf, int slot)
{
  datetime t = iTime(symbol, tf, 1); // time of last closed bar
  if(t == -1 || t == 0) return false;
  if(t != lastClosedBarTime[slot])
  {
    lastClosedBarTime[slot] = t;
    return true;
  }
  return false;
}

// Tính FVG cho MiddleTF chỉ khi bar C (hoặc bar 1) thay đổi
void EnsureFVGUpToDate(string symbol, ENUM_TIMEFRAMES tf, int lookback)
{
  if(tf != MiddleTF) return; // chỉ cache cho MiddleTF (theo EA bạn)
  datetime currentClosed = iTime(symbol, tf, 1);
  if(currentClosed == -1 || currentClosed == 0) return;
  if(currentClosed != lastFVGBarTime)
  {
    // bar vừa thay -> recompute FVG
    FindFVG(symbol, tf, lookback);
    lastFVGBarTime = currentClosed;
    if(PrintToExperts) PrintFormat("EnsureFVGUpToDate: recomputed FVG at %s", TimeToString(currentClosed, TIME_DATE|TIME_MINUTES));
  }
}

// requireFVG     : có cần FVG (true/false) truyền vào DetectMSSOnSlot
// minBreakPips.. : các tham số truyền xuống DetectMSSOnSlot (mặc định hợp lý)
void ProcessMSSForSlot(string sym, ENUM_TIMEFRAMES tf, int slot, bool enabled,
                       bool requireFVG = false,
                       double minBreakPips = 10.0,
                       int minConsec = 2,
                       int lookbackBarsForSweep = 50,
                       int fvgLookback = 200)
{
  if(!enabled) return;

  // Gọi DetectMSSOnSlot với tham số truyền vào
  MSSInfo info = DetectMSSOnSlot(sym, tf, slot, minBreakPips, minConsec, lookbackBarsForSweep, fvgLookback, requireFVG);

  if(info.found)
  {
    // Vẽ MSS & sweep
    DrawMss(sym, tf, info, slot);

    // TODO: thêm logic order/alert nếu bạn muốn
    // Ví dụ: SendNotification / Alert / PlaceOrder...
  }
}

void HandleLogicForTimeframe(string sym, ENUM_TIMEFRAMES tf, int slot, bool detectMSS,
                                     int swingRange, bool requireFVG,
                                     double minBreakPips, int minConsec,
                                     int lookbackBarsForSweep, int fvgLookback)
{
  UpdateSwings(sym, tf, slot, swingRange);
  UpdateTrendForSlot(slot, tf, sym);
  if(tf == MiddleTF) EnsureFVGUpToDate(sym, MiddleTF, fvgLookback);
  ProcessMSSForSlot(sym, tf, slot, detectMSS, requireFVG, minBreakPips, minConsec, lookbackBarsForSweep, fvgLookback);

  if(ShowSwingMarkers)
  {
    DrawSwingsOnChart(tf);
    if(tf == MiddleTF)
      DrawFVG(sym, MiddleTF, true);
  }

  UpdateLabel((tf == HighTF) ? "LBL_HTF" : (tf == MiddleTF) ? "LBL_MTF" : "LBL_LTF", tf, TrendTF[slot]);
}

void OnTick()
{
  string sym = Symbol();

  if(IsNewClosedBar(sym, HighTF, 0)) {
    HandleLogicForTimeframe(sym, HighTF, 0, DetectMSS_HTF, htfSwingRange, false, 10.0, 2, 50, FVGLookback);
  }

  if(IsNewClosedBar(sym, MiddleTF, 1)) {
    HandleLogicForTimeframe(sym, MiddleTF, 1, DetectMSS_MTF, mtfSwingRange, true, 10.0, 2, 50, FVGLookback);
  }

  if(IsNewClosedBar(sym, LowTF, 2)) {
    HandleLogicForTimeframe(sym, LowTF, 2, DetectMSS_LTF, ltfSwingRange, false, 10.0, 2, 50, FVGLookback);
  }
}

int OnInit()
{
  string sym = Symbol();
  HandleLogicForTimeframe(sym, HighTF, 0, false, htfSwingRange, false, 10.0, 2, 50, FVGLookback);
  HandleLogicForTimeframe(sym, MiddleTF, 1, false, mtfSwingRange, true, 10.0, 2, 50, FVGLookback);
  HandleLogicForTimeframe(sym, LowTF, 2, false, ltfSwingRange, false, 10.0, 2, 50, FVGLookback);

  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  // Xoá 3 label
  if(ObjectFind(0, "LBL_HTF") >= 0) ObjectDelete(0, "LBL_HTF");
  if(ObjectFind(0, "LBL_MTF") >= 0) ObjectDelete(0, "LBL_MTF");
  if(ObjectFind(0, "LBL_LTF") >= 0) ObjectDelete(0, "LBL_LTF");

  // Xóa tất cả object dùng tiền tố SwingObjPrefix (bao gồm htf_/mtf_/ltf_ và FVG)
  int tot = ObjectsTotal(0);
  for(int i = tot - 1; i >= 0; i--)
  {
    string nm = ObjectName(0, i);
    if(StringFind(nm, SwingObjPrefix, 0) == 0)
      ObjectDelete(0, nm);
  }
}