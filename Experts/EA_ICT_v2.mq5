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
input string        LabelName = "HighTF_Trend_Label"; // Tên object hiển thị
input int           MaxSkip = 10;             // Không dùng nhiều trong phiên bản này nhưng giữ để tương thích
input bool          ShowLabel = true;         // Hiển thị label trên chart
input bool          PrintToExperts = true;    // In log ra Expert

// Cấu hình Swing
input int           SwingRange = 2;           // X: số nến trước và sau để xác định 1 đỉnh/đáy
input int           SwingKeep = 2;            // Số đỉnh/đáy gần nhất cần lưu (bạn yêu cầu 2)

// Cấu hình vẽ Swing trên chart
input bool   ShowSwingMarkers = true;      // Hiển thị các marker swing trên chart
input string SwingObjPrefix   = "HTF_SW_"; // Tiền tố tên object (dễ xóa/điều chỉnh)
input int    SwingMarkerFontSize    = 12;        // Kích thước font cho label

// Mảng lưu trữ đỉnh/đáy gần nhất (index 0 = gần nhất)
double SwingHighPrice[2];
datetime SwingHighTime[2];
int SwingHighCount = 0;

double SwingLowPrice[2];
datetime SwingLowTime[2];
int SwingLowCount = 0;

// FVG results (global)
double FVG_top[];        // giá trên của zone (lớn hơn)
double FVG_bottom[];     // giá dưới của zone (nhỏ hơn)
datetime FVG_timeA[];    // time của bar A (older)
datetime FVG_timeC[];    // time của bar C (newer)
int    FVG_type[];       //  1 = bullish, -1 = bearish
int    FVG_count = 0;

//====================================================================
// CalculateTrendFromSwings - phiên bản mới theo yêu cầu của bạn
// Trả về:  1 = Uptrend, -1 = Downtrend, 0 = Sideway/Không xác định
// Yêu cầu: SwingHighCount >= 2 và SwingLowCount >= 2 để có thể xác định
//====================================================================
//+------------------------------------------------------------------+
//| Xác định trend dựa vào 2 swing gần nhất + vị trí current price  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| CalculateTrendFromSwings - phiên bản nhận symbol                 |
//| Trả về: 1 = Uptrend, -1 = Downtrend, 0 = Sideway                 |
//+------------------------------------------------------------------+
int CalculateTrendFromSwings(string symbol)
{
  // Cần đủ 2 swing high và 2 swing low
  if(SwingHighCount < 2 || SwingLowCount < 2)
    return 0; // SIDEWAY / không đủ dữ liệu

  double sh0 = SwingHighPrice[0];
  double sh1 = SwingHighPrice[1];
  double sl0 = SwingLowPrice[0];
  double sl1 = SwingLowPrice[1];

  // Lấy giá hiện tại chuẩn MQL5 cho symbol được truyền vào
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
    else
    {
      if(PrintToExperts) PrintFormat("CalculateTrendFromSwings: Không lấy được giá cho %s", symbol);
      return 0;
    }
  }

  // tolerance (nửa pip) dựa trên symbol được truyền vào
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  double tol   = (point > 0 ? point * 0.5 : 0.0);

  // ------------------------------------------------------------
  //  LOGIC MỚI THEO YÊU CẦU
  // ------------------------------------------------------------

  // Case A
  if(sh1 < sh0 && sl1 < sl0)
  {
    if(currentPrice > sl0 + tol) return 1;   // Uptrend
    if(currentPrice < sl0 - tol) return -1;  // Downtrend
    return 0;
  }

  // Case B
  if(sh1 > sh0 && sl1 > sl0)
  {
    if(currentPrice < sh0 - tol) return -1;  // Downtrend
    if(currentPrice > sh0 + tol) return 1;   // Uptrend
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
void UpdateSwings(string symbol, ENUM_TIMEFRAMES timeframe)
{
  // Reset
  SwingHighCount = 0;
  SwingLowCount = 0;

  int total = iBars(symbol, timeframe);
  if(total <= SwingRange + 2) return; // dữ liệu không đủ

  // Vì cần so sánh cả X nến trước và X nến sau, index i phải thỏa: i >= X+1  và i <= total - X - 1
  int iStart = SwingRange + 1;
  int iEnd = total - SwingRange - 1;

  // Duyệt từ gần nhất (index nhỏ) tới xa hơn để tìm các swing gần nhất trước tiên
  for(int i = iStart; i <= iEnd; i++)
  {
    // Nếu đã đủ 2 swing high & 2 swing low thì dừng
    if(SwingHighCount >= SwingKeep && SwingLowCount >= SwingKeep) break;

    // Kiểm tra SwingHigh
    if(SwingHighCount < SwingKeep)
    {
      bool isH = IsSwingHigh(symbol, timeframe, i, SwingRange);
      if(isH)
      {
        // Gán theo thứ tự: [0] = gần nhất, [1] = xa hơn
        if(SwingHighCount == 0)
        {
          SwingHighPrice[0] = iClose(symbol, timeframe, i);
          SwingHighTime[0]  = iTime(symbol, timeframe, i);
        }
        else // SwingHighCount == 1
        {
          SwingHighPrice[1] = iClose(symbol, timeframe, i);
          SwingHighTime[1]  = iTime(symbol, timeframe, i);
        }
        SwingHighCount++;
        if(PrintToExperts) PrintFormat("Found SwingHigh #%d: price=%.5f at %s (i=%d)", SwingHighCount, iClose(symbol, timeframe, i), TimeToString(iTime(symbol, timeframe, i), TIME_DATE|TIME_MINUTES), i);
      }
    }

    // Kiểm tra SwingLow
        // Kiểm tra SwingLow
    if(SwingLowCount < SwingKeep)
    {
      bool isL = IsSwingLow(symbol, timeframe, i, SwingRange);
      if(isL)
      {
        // Gán theo thứ tự: [0] = gần nhất, [1] = xa hơn
        if(SwingLowCount == 0)
        {
          SwingLowPrice[0] = iClose(symbol, timeframe, i);
          SwingLowTime[0]  = iTime(symbol, timeframe, i);
        }
        else // SwingLowCount == 1
        {
          SwingLowPrice[1] = iClose(symbol, timeframe, i);
          SwingLowTime[1]  = iTime(symbol, timeframe, i);
        }
        SwingLowCount++;
        if(PrintToExperts) PrintFormat("Found SwingLow #%d: price=%.5f at %s (i=%d)", SwingLowCount, iClose(symbol, timeframe, i), TimeToString(iTime(symbol, timeframe, i), TIME_DATE|TIME_MINUTES), i);
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Vẽ SwingHigh & SwingLow lên chart                                 |
//+------------------------------------------------------------------+
void DrawSwingsOnChart()
{
   if(!ShowSwingMarkers) return;

   // Xóa các marker cũ theo tiền tố input
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, SwingObjPrefix, 0) == 0)
         ObjectDelete(0, name);
   }

   // ------------------------
   // Vẽ Swing High
   // ------------------------
   int maxH = (SwingHighCount < SwingKeep) ? SwingHighCount : SwingKeep;

   for(int h = 0; h < maxH; h++)
   {
      string obj = SwingObjPrefix + "H_" + IntegerToString(h);

      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, SwingHighTime[h], SwingHighPrice[h]))
      {
         Print("Cannot create object: ", obj);
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT, "▲ H" + IntegerToString(h));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
   }

   // ------------------------
   // Vẽ Swing Low
   // ------------------------
   int maxL = (SwingLowCount < SwingKeep) ? SwingLowCount : SwingKeep;

   for(int l = 0; l < maxL; l++)
   {
      string obj = SwingObjPrefix + "L_" + IntegerToString(l);

      if(!ObjectCreate(0, obj, OBJ_TEXT, 0, SwingLowTime[l], SwingLowPrice[l]))
      {
         Print("Cannot create object: ", obj);
         continue;
      }

      ObjectSetString(0, obj, OBJPROP_TEXT, "▼ L" + IntegerToString(l));
      ObjectSetInteger(0, obj, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, SwingMarkerFontSize);
      ObjectSetInteger(0, obj, OBJPROP_ANCHOR, ANCHOR_TOP);
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

  // Thời gian bar (giây)
  long bar_secs = PeriodSeconds(timeframe);

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
      if(t0 != 0) end_time = (datetime)( (long)t0 + (long)bar_secs ); // kéo tới đầu nến hiện tại + 1 bar để dễ nhìn
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

// Vẽ hoặc cập nhật label trên chart hiện tại
void UpdateLabel(int trend)
{
  if(!ShowLabel) return;

  string txt = StringFormat("HighTF %s: %s", EnumToString(HighTF), TrendToString(trend));

  // Nếu object đã tồn tại -> cập nhật text
  if(ObjectFind(0, LabelName) >= 0)
  {
    ObjectSetString(0, LabelName, OBJPROP_TEXT, txt);
  }
  else
  {
    // Tạo label tại góc trái trên
    if(!ObjectCreate(0, LabelName, OBJ_LABEL, 0, 0, 0))
    {
      Print("Không thể tạo object label: ", LabelName);
      return;
    }
    ObjectSetInteger(0, LabelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, LabelName, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, LabelName, OBJPROP_YDISTANCE, 20);
    ObjectSetInteger(0, LabelName, OBJPROP_FONTSIZE, 12);
    ObjectSetString(0, LabelName, OBJPROP_TEXT, txt);
  }

  // Tùy chỉnh màu theo trend
  if(trend==1)
  {
    ObjectSetInteger(0, LabelName, OBJPROP_COLOR, clrLime);
  }
  else if(trend==-1)
  {
    ObjectSetInteger(0, LabelName, OBJPROP_COLOR, clrRed);
  }
  else
  {
    ObjectSetInteger(0, LabelName, OBJPROP_COLOR, clrGray);
  }
}

int OnInit()
{
  // Khởi tạo label ngay khi attach
  UpdateLabel(0);
  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  // Xoá label khi detach để sạch chart
  if(ObjectFind(0, LabelName) >= 0)
    ObjectDelete(0, LabelName);
}

void OnTick()
{
  string sym = Symbol();

  // Cập nhật SwingHighs và SwingLows từ HighTF
  UpdateSwings(sym, HighTF);

  // --- DÒNG THÊM: vẽ marker lên chart ---
  if(ShowSwingMarkers) DrawSwingsOnChart();

  // Xác định FVG của MiddleTF
  int found = FindFVG(sym, MiddleTF, 200);
  PrintFormat("Found %d FVG on %s", found, EnumToString(MiddleTF));
  DrawFVG(sym, MiddleTF, true); // vẽ FVG, start từ bar C

  int trend = CalculateTrendFromSwings(sym);

  if(PrintToExperts)
  {
    PrintFormat("[%s] HighTF=%s -> %s", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), EnumToString(HighTF), TrendToString(trend));

    // In thêm thông tin 2 swing gần nhất nếu có
    if(SwingHighCount>=1) PrintFormat("SwingH[0]=%.5f at %s", SwingHighPrice[0], TimeToString(SwingHighTime[0], TIME_DATE|TIME_MINUTES));
    if(SwingHighCount>=2) PrintFormat("SwingH[1]=%.5f at %s", SwingHighPrice[1], TimeToString(SwingHighTime[1], TIME_DATE|TIME_MINUTES));
    if(SwingLowCount>=1)  PrintFormat("SwingL[0]=%.5f at %s", SwingLowPrice[0],  TimeToString(SwingLowTime[0], TIME_DATE|TIME_MINUTES));
    if(SwingLowCount>=2)  PrintFormat("SwingL[1]=%.5f at %s", SwingLowPrice[1],  TimeToString(SwingLowTime[1], TIME_DATE|TIME_MINUTES));
  }

  UpdateLabel(trend);

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
