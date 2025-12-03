//+------------------------------------------------------------------+
//| EA: HighTF Trend Detector (v2 - Swing High/Low)                  |
//| Mục đích: Xác định xu hướng trên khung thời gian lớn theo logic  |
//| Người tạo: ChatGPT (mã mẫu)                                      |
//+------------------------------------------------------------------+
#property copyright "ChatGPT"
#property version   "2.00"
#property strict

input ENUM_TIMEFRAMES HighTF = PERIOD_D1;    // Khung thời gian cao
input ENUM_TIMEFRAMES MiddleTF = PERIOD_H1;  // Khung thời gian trung bình (dùng để tìm FVG)
input ENUM_TIMEFRAMES LowTF = PERIOD_M5;    // Khung thời gian thấp (Tìm điểm vào lệnh)

input string        LabelName = "HighTF_Trend_Label"; // Tên object hiển thị
input int           MaxSkip = 10;             // Không dùng nhiều trong phiên bản này nhưng giữ để tương thích
input bool          ShowLabel = true;         // Hiển thị label trên chart
input bool          PrintToExperts = true;    // In log ra Expert

// Cấu hình Swing
input int           htfSwingRange = 1;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           mtfSwingRange = 2;        // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           ltfSwingRange = 3;        // X: số nến trước và sau để xác định 1 đỉnh/đáy

input int           SwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

// Cấu hình vẽ Swing trên chart
input bool   ShowSwingMarkers = true;      // Hiển thị các marker swing trên chart
input string SwingObjPrefix   = "Swing_"; // Tiền tố tên object (dễ xóa/điều chỉnh)
input int    SwingMarkerFontSize    = 10;        // Kích thước font cho label

// --- multi-TF swing storage (slots) ---
// slot 0 = HighTF, slot 1 = MiddleTF, slot 2 = LowTF
// dimension: [slot][index]  (index 0 = nearest, 1 = older)
double SwingHighPriceTF[3][2];
datetime SwingHighTimeTF[3][2];
int    SwingHighCountTF[3];

double SwingLowPriceTF[3][2];
datetime SwingLowTimeTF[3][2];
int    SwingLowCountTF[3];


// FVG results (global)
double FVG_top[];        // giá trên của zone (lớn hơn)
double FVG_bottom[];     // giá dưới của zone (nhỏ hơn)
datetime FVG_timeA[];    // time của bar A (older)
datetime FVG_timeC[];    // time của bar C (newer)
int    FVG_type[];       //  1 = bullish, -1 = bearish
int    FVG_count = 0;

//+------------------------------------------------------------------+
//| CalculateTrendFromSwings - phiên bản nhận symbol và timeframe    |
//| symbol: symbol để lấy giá và truyền vào UpdateSwings             |
//| TimeframeSwingRange: khung thời gian dùng để tìm swing (HighTF / MiddleTF ...) |
//| Trả về: 1 = Uptrend, -1 = Downtrend, 0 = Sideway                 |
//+------------------------------------------------------------------+
int CalculateTrendFromSwings(string symbol, ENUM_TIMEFRAMES TimeframeSwingRange)
{
  // Map timeframe -> slot
  int slot = 0; // default 0=HTF
  if(TimeframeSwingRange == MiddleTF) slot = 1;
  else if (TimeframeSwingRange == LowTF) slot = 2;

  // Cập nhật swings cho slot tương ứng
  UpdateSwings(symbol, TimeframeSwingRange, slot);

  // Kiểm tra đủ swings
  if(SwingHighCountTF[slot] < 2 || SwingLowCountTF[slot] < 2)
  {
    if(PrintToExperts) PrintFormat("CalculateTrendFromSwings(%s,%s): Không đủ swing (slot=%d H=%d L=%d)", symbol, EnumToString(TimeframeSwingRange), slot, SwingHighCountTF[slot], SwingLowCountTF[slot]);
    return 0;
  }

  double sh0 = SwingHighPriceTF[slot][0];
  double sh1 = SwingHighPriceTF[slot][1];
  double sl0 = SwingLowPriceTF[slot][0];
  double sl1 = SwingLowPriceTF[slot][1];

  // Lấy giá hiện tại
  MqlTick tick;
  if(!SymbolInfoTick(symbol, tick))
  {
     if(PrintToExperts) PrintFormat("CalculateTrendFromSwings: Không lấy được tick của %s", symbol);
     return 0;
  }
  double currentPrice = tick.bid;
  if(currentPrice == 0.0)
  {
    if(tick.last > 0) currentPrice = tick.last;
    else if(tick.ask > 0) currentPrice = tick.ask;
    else { if(PrintToExperts) PrintFormat("CalculateTrendFromSwings: Không lấy được giá cho %s", symbol); return 0; }
  }

  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol   = (point > 0 ? point * 0.5 : 0.0);

  // Logic xác định trend (theo spec của bạn)
  if(sh1 < sh0 && sl1 < sl0)
  {
    if(currentPrice > sl0 + tol) return 1;
    if(currentPrice < sl0 - tol) return -1;
    return 0;
  }

  if(sh1 > sh0 && sl1 > sl0)
  {
    if(currentPrice < sh0 - tol) return -1;
    if(currentPrice > sh0 + tol) return 1;
    return 0;
  }

  return 0;
}

// Kiểm tra 1 bar tại index i có phải SwingHigh không (dùng giá đóng cửa theo yêu cầu)
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES timeframe, int i, int X)
{
  double ci = iClose(symbol, timeframe, i);
  if(ci==0) return false;

  // So sánh với X nến trước (chỉ xét nến đóng)
  for(int j=1; j<=X; j++)
  {
    double cprev = iClose(symbol, timeframe, i - j);
    if(cprev==0) return false; // dữ liệu không đủ
    if(cprev >= ci) // nếu có nến nào đóng bằng hoặc cao hơn -> không phải SwingHigh
      return false;
  }
  // So sánh với X nến sau (các nến cũ hơn, index tăng)
  for(int k=1; k<=X; k++)
  {
    double cnext = iClose(symbol, timeframe, i + k);
    if(cnext==0) return false;
    if(cnext >= ci)
      return false;
  }
  return true;
}

// Kiểm tra 1 bar tại index i có phải SwingLow không
bool IsSwingLow(string symbol, ENUM_TIMEFRAMES timeframe, int i, int X)
{
  double ci = iClose(symbol, timeframe, i);
  if(ci==0) return false;

  for(int j=1; j<=X; j++)
  {
    double cprev = iClose(symbol, timeframe, i - j);
    if(cprev==0) return false;
    if(cprev <= ci) // có nến đóng bằng hoặc thấp hơn -> không phải swing low
      return false;
  }
  for(int k=1; k<=X; k++)
  {
    double cnext = iClose(symbol, timeframe, i + k);
    if(cnext==0) return false;
    if(cnext <= ci)
      return false;
  }
  return true;
}

// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ SwingKeep phần tử gần nhất)
// UpdateSwings vào slot (0 = HighTF, 1 = MiddleTF)
// Cập nhật mảng SwingHighPrice/Time và SwingLowPrice/Time (giữ SwingKeep phần tử gần nhất)
// UpdateSwings vào slot (0 = HighTF, 1 = MiddleTF)
void UpdateSwings(string symbol, ENUM_TIMEFRAMES timeframe, int slot, int SwingRange = 1)
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
        double ci = iClose(symbol, timeframe, i);
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
        double ci2 = iClose(symbol, timeframe, i);
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
  string inChartSwingPrefix = "h_";

  if(timeframe == MiddleTF) {
    slot = 1;
    inChartSwingPrefix = "m_";
  } else if (timeframe == LowTF) {
    slot = 2;
    inChartSwingPrefix = "l_";
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

      ObjectSetString(0, obj, OBJPROP_TEXT,  "▲ " + inChartSwingPrefix +"H" + IntegerToString(h));
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

// Hàm tiện ích chuyển giá trị xu hướng thành chuỗi
string TrendToString(int trend)
{
  if(trend==1) return "UPTREND";
  if(trend==-1) return "DOWNTREND";
  return "SIDEWAY";
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
    if(!ShowLabel) return;

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

int OnInit()
{
  // Khởi tạo 3 label cho 3 timeframe
  UpdateLabel("LBL_HTF", HighTF, 0);
  UpdateLabel("LBL_MTF", MiddleTF, 0);
  UpdateLabel("LBL_LTF", LowTF, 0);

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

void OnTick()
{
  string sym = Symbol();

  // Cập nhật swings cho cả 2 timeframe vào slot tương ứng
  UpdateSwings(sym, HighTF,   0, htfSwingRange);
  UpdateSwings(sym, MiddleTF, 1, mtfSwingRange);
  UpdateSwings(sym, LowTF,    2, ltfSwingRange);

  // Vẽ marker cho từng timeframe (prefix sẽ thêm "MTF_" cho middle)
  if(ShowSwingMarkers)
  {
    DrawSwingsOnChart(HighTF);
    DrawSwingsOnChart(MiddleTF);
    DrawSwingsOnChart(LowTF);
  }


  // Xác định FVG của MiddleTF
  int found = FindFVG(sym, MiddleTF, 200);
  PrintFormat("Found %d FVG on %s", found, EnumToString(MiddleTF));
  DrawFVG(sym, MiddleTF, true); // vẽ FVG, start từ bar C

  // Tính trend từ swings
  int htfTrend = CalculateTrendFromSwings(sym, HighTF);
  int mtfTrend = CalculateTrendFromSwings(sym, MiddleTF);
  int ltfTrend = CalculateTrendFromSwings(sym, LowTF);

  if(PrintToExperts)
  {
    PrintFormat("[%s] HighTF=%s -> %s", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), EnumToString(HighTF), TrendToString(htfTrend));

    // In thêm thông tin 2 htf swings gần nhất
    if(SwingHighCountTF[0]>=1) PrintFormat("HTF SwingH[0]=%.5f at %s", SwingHighPriceTF[0][0], TimeToString(SwingHighTimeTF[0][0], TIME_DATE|TIME_MINUTES));
    if(SwingHighCountTF[0]>=2) PrintFormat("HTF SwingH[1]=%.5f at %s", SwingHighPriceTF[0][1], TimeToString(SwingHighTimeTF[0][1], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[0]>=1)  PrintFormat("HTF SwingL[0]=%.5f at %s", SwingLowPriceTF[0][0],  TimeToString(SwingLowTimeTF[0][0], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[0]>=2)  PrintFormat("HTF SwingL[1]=%.5f at %s", SwingLowPriceTF[0][1],  TimeToString(SwingLowTimeTF[0][1], TIME_DATE|TIME_MINUTES));

    // In thông tin middle timeframe swings
    if(SwingHighCountTF[1]>=1) PrintFormat("MTF_SwingH[0]=%.5f at %s", SwingHighPriceTF[1][0], TimeToString(SwingHighTimeTF[1][0], TIME_DATE|TIME_MINUTES));
    if(SwingHighCountTF[1]>=2) PrintFormat("MTF_SwingH[1]=%.5f at %s", SwingHighPriceTF[1][1], TimeToString(SwingHighTimeTF[1][1], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[1]>=1)  PrintFormat("MTF_SwingL[0]=%.5f at %s", SwingLowPriceTF[1][0], TimeToString(SwingLowTimeTF[1][0], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[1]>=2)  PrintFormat("MTF_SwingL[1]=%.5f at %s", SwingLowPriceTF[1][1], TimeToString(SwingLowTimeTF[1][1], TIME_DATE|TIME_MINUTES));

    // In thông tin low timeframe swings
    if(SwingHighCountTF[2]>=1) PrintFormat("LTF_SwingH[0]=%.5f at %s", SwingHighPriceTF[2][0], TimeToString(SwingHighTimeTF[2][0], TIME_DATE|TIME_MINUTES));
    if(SwingHighCountTF[2]>=2) PrintFormat("LTF_SwingH[1]=%.5f at %s", SwingHighPriceTF[2][1], TimeToString(SwingHighTimeTF[2][1], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[2]>=1)  PrintFormat("LTF_SwingL[0]=%.5f at %s", SwingLowPriceTF[2][0], TimeToString(SwingLowTimeTF[2][0], TIME_DATE|TIME_MINUTES));
    if(SwingLowCountTF[2]>=2)  PrintFormat("LTF_SwingL[1]=%.5f at %s", SwingLowPriceTF[2][1], TimeToString(SwingLowTimeTF[2][1], TIME_DATE|TIME_MINUTES));

  }

  UpdateLabel("LBL_HTF", HighTF, htfTrend);
  UpdateLabel("LBL_MTF", MiddleTF, mtfTrend);
  UpdateLabel("LBL_LTF", LowTF, ltfTrend);

  // Nơi để thêm logic entry/exit dựa trên trend
}

//+------------------------------------------------------------------+
// Ghi chú:
// - Tôi đã triển khai logic xác định SwingHigh/SwingLow dùng GIÁ ĐÓNG (close)
//   theo đúng yêu cầu: 1 đỉnh khi giá đóng của cây đó lớn hơn giá đóng của
//   X cây nến trước và X cây nến sau.
// - SwingKeep = 2 nên EA lưu 2 đỉnh và 2 đáy gần nhất; index 0 là gần nhất.
// - Trend xác định: Uptrend nếu SwingHigh[0] > SwingHigh[1] && SwingLow[0] > SwingLow[1].
//   Downtrend nếu SwingHigh[0] < SwingHigh[1] && SwingLow[0] < SwingLow[1].
// - Nếu phần mô tả Downtrend của bạn có sai sót (như biểu thức bị lẫn) tôi
//   đã hiểu và áp dụng dạng đối ngược logic Uptrend ở trên.
// - Label vẫn giữ nguyên như bạn yêu cầu.
//+------------------------------------------------------------------+
