//+------------------------------------------------------------------+
//| RsiMomentumIndicator.mq5                                         |
//| Hiển thị trong cửa sổ phụ: RSI14, EMA9(RSI), WMA45(RSI)         |
//| Hiển thị trên chart chính: EMA200 + mũi tên đánh dấu giao cắt   |
//| Panel góc trên-phải: trend, giá trị RSI / EMA9 / WMA45           |
//+------------------------------------------------------------------+
#property copyright   "RsiMomentumIndicator"
#property version     "1.00"
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_minimum 0
#property indicator_maximum 100

// --- Buffer 0: RSI14 ---
#property indicator_label1  "RSI(14)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrMediumOrchid
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// --- Buffer 1: EMA9 trên RSI ---
#property indicator_label2  "EMA9 on RSI"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDarkOrange
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

// --- Buffer 2: WMA45 trên RSI ---
#property indicator_label3  "WMA45 on RSI"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDodgerBlue
#property indicator_style3  STYLE_SOLID
#property indicator_width3  2

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Chỉ báo"
input int   InpRSIPeriod    = 14;
input int   InpEMA9Period   = 9;
input int   InpWMA45Period  = 45;
input int   InpEMA200Period = 200;

input group "Bộ lọc trend"
input int   InpTrendConfirmBars = 2;   // số nến liên tiếp phải đóng cùng phía EMA200

input group "Bộ lọc RSI"
input double InpRSIOverbought = 70.0;   // RSI ≥ ngưỡng này → bỏ qua tín hiệu BUY
input double InpRSIOversold   = 30.0;   // RSI ≤ ngưỡng này → bỏ qua tín hiệu SELL

input group "Mũi tên giao cắt"
input color InpArrowUpColor   = clrLime;     // màu mũi tên khi RSI cắt lên WMA45
input color InpArrowDownColor = clrTomato;   // màu mũi tên khi RSI cắt xuống WMA45
input int   InpArrowOffsetPts = 30;          // khoảng cách mũi tên so với đỉnh/đáy nến (points)
input int   InpArrowSize      = 2;           // kích thước mũi tên

input group "Panel thông tin"
input bool  InpShowPanel = true;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
double buf_RSI[];
double buf_EMA9[];
double buf_WMA45[];

int h_RSI    = INVALID_HANDLE;
int h_EMA9   = INVALID_HANDLE;
int h_WMA45  = INVALID_HANDLE;
int h_EMA200 = INVALID_HANDLE;

const string OBJ_PREFIX  = "RsiMom_";
const string LBL_TITLE   = OBJ_PREFIX + "title";
const string LBL_TREND   = OBJ_PREFIX + "trend";
const string LBL_RSI_VAL = OBJ_PREFIX + "rsi";
const string LBL_EMA9VAL = OBJ_PREFIX + "ema9";
const string LBL_WMA45VAL= OBJ_PREFIX + "wma45";

//+------------------------------------------------------------------+
//| Tạo một OBJ_LABEL trên chart chính                               |
//+------------------------------------------------------------------+
void CreateLabel(const string name, const string text, const color clr,
                 const int x, const int y, const int fontSize = 9)
{
  if (ObjectFind(0, name) >= 0) return;
  ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
  ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
  ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fontSize);
  ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
  ObjectSetInteger(0, name, OBJPROP_BACK,       false);
  ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
  ObjectSetString (0, name, OBJPROP_TEXT,       text);
}

void UpdateLabel(const string name, const string text, const color clr)
{
  if (ObjectFind(0, name) < 0) return;
  ObjectSetString (0, name, OBJPROP_TEXT,  text);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Khởi tạo indicator                                               |
//+------------------------------------------------------------------+
int OnInit()
{
  // Đăng ký buffer — đặt AS_SERIES để [0] = nến hiện tại
  SetIndexBuffer(0, buf_RSI,   INDICATOR_DATA);
  SetIndexBuffer(1, buf_EMA9,  INDICATOR_DATA);
  SetIndexBuffer(2, buf_WMA45, INDICATOR_DATA);

  ArraySetAsSeries(buf_RSI,   true);
  ArraySetAsSeries(buf_EMA9,  true);
  ArraySetAsSeries(buf_WMA45, true);

  IndicatorSetString (INDICATOR_SHORTNAME, StringFormat("RsiMom(%d)", InpRSIPeriod));
  IndicatorSetInteger(INDICATOR_DIGITS, 2);

  // Tạo handles chỉ báo
  h_RSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
  if (h_RSI == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle RSI"); return INIT_FAILED; }

  // EMA9 và WMA45 tính trên dữ liệu của h_RSI (buffer 0 của RSI)
  h_EMA9 = iMA(_Symbol, _Period, InpEMA9Period, 0, MODE_EMA, h_RSI);
  if (h_EMA9 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle EMA9(RSI)"); return INIT_FAILED; }

  h_WMA45 = iMA(_Symbol, _Period, InpWMA45Period, 0, MODE_LWMA, h_RSI);
  if (h_WMA45 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle WMA45(RSI)"); return INIT_FAILED; }

  h_EMA200 = iMA(_Symbol, _Period, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
  if (h_EMA200 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle EMA200"); return INIT_FAILED; }

  // Gắn EMA200 lên cửa sổ chính (window 0) của chart hiện tại
  if (!ChartIndicatorAdd(ChartID(), 0, h_EMA200))
    PrintFormat("[RsiMom] Không thể gắn EMA200 lên chart (err=%d)", GetLastError());

  // Tạo panel thông tin (góc trên-phải chart chính)
  if (InpShowPanel)
  {
    CreateLabel(LBL_TITLE,    "─ RSI MOMENTUM ─",   clrWhite,         10, 14, 10);
    CreateLabel(LBL_TREND,    "Trend : ---",          clrSilver,        10, 34, 9);
    CreateLabel(LBL_RSI_VAL,  "RSI   : ---",          clrMediumOrchid,  10, 51, 9);
    CreateLabel(LBL_EMA9VAL,  "EMA9  : ---",          clrDarkOrange,    10, 68, 9);
    CreateLabel(LBL_WMA45VAL, "WMA45 : ---",          clrDodgerBlue,    10, 85, 9);
  }

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Dọn dẹp khi gỡ indicator                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if (h_RSI   != INVALID_HANDLE) IndicatorRelease(h_RSI);
  if (h_EMA9  != INVALID_HANDLE) IndicatorRelease(h_EMA9);
  if (h_WMA45 != INVALID_HANDLE) IndicatorRelease(h_WMA45);
  if (h_EMA200 != INVALID_HANDLE) IndicatorRelease(h_EMA200);

  // Xóa tất cả object do indicator tạo ra (mũi tên + panel)
  ObjectsDeleteAll(0, OBJ_PREFIX);
  ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Tính toán chỉ báo mỗi tick                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
  const int minBars = InpWMA45Period + InpRSIPeriod + 5;
  if (rates_total < minBars) return 0;

  // Đảm bảo các source indicator đã tính xong (quan trọng khi cold-start
  // hoặc khi thị trường đóng — không có tick để retry)
  const int rsiBars    = BarsCalculated(h_RSI);
  const int ema9Bars   = BarsCalculated(h_EMA9);
  const int wmaBars    = BarsCalculated(h_WMA45);
  const int ema200Bars = BarsCalculated(h_EMA200);
  if (rsiBars <= 0 || ema9Bars <= 0 || wmaBars <= 0 || ema200Bars <= 0)
    return 0; // chưa có dữ liệu — return 0 để MT5 retry ngay

  // Chỉ copy số bar mà tất cả source đã tính xong (tránh return giữa chừng)
  const int srcMin = MathMin(MathMin(rsiBars, ema9Bars), wmaBars);
  const int copyN  = MathMin(srcMin, rates_total);
  if (copyN < minBars) return 0;

  // Đổ dữ liệu vào indicator buffer (AS_SERIES=true, [0]=nến hiện tại)
  if (CopyBuffer(h_RSI,   0, 0, copyN, buf_RSI)   <= 0) return 0;
  if (CopyBuffer(h_EMA9,  0, 0, copyN, buf_EMA9)  <= 0) return 0;
  if (CopyBuffer(h_WMA45, 0, 0, copyN, buf_WMA45) <= 0) return 0;

  // Số nến cần quét để phát hiện giao cắt mới
  int barsToScan = (prev_calculated == 0)
                   ? rates_total - 2
                   : (rates_total - prev_calculated + 2);
  barsToScan = MathMin(barsToScan, rates_total - 2);

  // Sao chép time, high, low, close và EMA200 để phát hiện giao cắt + lọc trend
  // +InpTrendConfirmBars vì cần check N nến liên tiếp đóng cùng phía EMA200
  // CLAMP need ≤ copyN để CopyTime/CopyClose không bao giờ "thiếu" — first call
  // có barsToScan = rates_total-2 sẽ cho need lớn hơn rates_total nếu không clamp.
  const int trendN = MathMax(1, InpTrendConfirmBars);
  const int need   = MathMin(barsToScan + 2 + trendN, copyN);
  datetime timeArr[];
  double   highArr[], lowArr[], closeArr[], ema200Arr[];
  ArraySetAsSeries(timeArr,   true);
  ArraySetAsSeries(highArr,   true);
  ArraySetAsSeries(lowArr,    true);
  ArraySetAsSeries(closeArr,  true);
  ArraySetAsSeries(ema200Arr, true);

  if (CopyTime  (_Symbol, _Period, 0, need, timeArr)         < need) return prev_calculated;
  if (CopyHigh  (_Symbol, _Period, 0, need, highArr)         < need) return prev_calculated;
  if (CopyLow   (_Symbol, _Period, 0, need, lowArr)          < need) return prev_calculated;
  if (CopyClose (_Symbol, _Period, 0, need, closeArr)        < need) return prev_calculated;
  if (CopyBuffer(h_EMA200, 0, 0,            need, ema200Arr) < need) return prev_calculated;

  const double arrowOffset = InpArrowOffsetPts * _Point;

  // Phát hiện giao cắt RSI vs WMA45, chỉ vẽ khi khớp với trend EMA200
  for (int i = barsToScan; i >= 1; i--)
  {
    if (i + 1 >= rates_total)  continue;
    if (i + trendN >= need)    continue; // ngoài phạm vi mảng cục bộ (timeArr/closeArr/ema200Arr)
    if (ema200Arr[i] <= 0.0)   continue; // EMA200 chưa tính đủ bars

    const bool crossUp   = (buf_RSI[i+1] <= buf_WMA45[i+1]) && (buf_RSI[i] > buf_WMA45[i]);
    const bool crossDown = (buf_RSI[i+1] >= buf_WMA45[i+1]) && (buf_RSI[i] < buf_WMA45[i]);

    if (!crossUp && !crossDown) continue;

    // Lọc theo trend EMA200: cần N nến LIÊN TIẾP gần nhất đều đóng cùng phía
    // Quét từ nến tín hiệu i → i+N-1
    bool trendUp   = true;
    bool trendDown = true;
    for (int k = 0; k < trendN; k++)
    {
      const int idx = i + k;
      if (ema200Arr[idx] <= 0.0) { trendUp = false; trendDown = false; break; }
      if (closeArr[idx] <= ema200Arr[idx]) trendUp   = false;
      if (closeArr[idx] >= ema200Arr[idx]) trendDown = false;
      if (!trendUp && !trendDown) break;
    }

    // Vị trí EMA9 vs WMA45 — kiểm tra "lực mua/bán mới bắt đầu chiếm ưu thế"
    //   BUY:  EMA9 vẫn dưới WMA45 (lực mua chỉ vừa nhú lên qua RSI cross)
    //   SELL: EMA9 vẫn trên WMA45 (lực bán chỉ vừa nhú xuống)
    const bool ema9BelowWma = (buf_EMA9[i] < buf_WMA45[i]);
    const bool ema9AboveWma = (buf_EMA9[i] > buf_WMA45[i]);

    // Slope EMA9 — phải đang hướng cùng chiều với tín hiệu
    const bool ema9SlopeUp   = (buf_EMA9[i] > buf_EMA9[i+1]);
    const bool ema9SlopeDown = (buf_EMA9[i] < buf_EMA9[i+1]);

    // Lọc RSI extreme — không mua đỉnh, không bán đáy
    //   RSI ≥ overbought  → bỏ tín hiệu BUY
    //   RSI ≤ oversold    → bỏ tín hiệu SELL
    const bool rsiOkBuy  = (buf_RSI[i] < InpRSIOverbought);
    const bool rsiOkSell = (buf_RSI[i] > InpRSIOversold);

    // Tín hiệu hợp lệ khi đủ 5 điều kiện
    const bool validBuy  = crossUp   && trendUp   && ema9BelowWma && ema9SlopeUp   && rsiOkBuy;
    const bool validSell = crossDown && trendDown && ema9AboveWma && ema9SlopeDown && rsiOkSell;

    if (!validBuy && !validSell) continue;

    // Dùng timestamp làm tên duy nhất để tránh tạo trùng object
    const string arrowName = OBJ_PREFIX + "CR_" + IntegerToString((int)timeArr[i]);
    if (ObjectFind(0, arrowName) >= 0) continue;

    if (validBuy)
    {
      // Mũi tên lên (↑) đặt dưới đáy nến — tín hiệu BUY trong uptrend
      // ANCHOR_TOP: điểm anchor là đỉnh icon → arrow nằm xuôi xuống dưới price
      // → tip ↑ ở phía trên, sát đáy nến (cách lowArr[i] một khoảng arrowOffset)
      const double price = lowArr[i] - arrowOffset;
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE,  233);
      ObjectSetInteger(0, arrowName, OBJPROP_ANCHOR,     ANCHOR_TOP);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR,      InpArrowUpColor);
      ObjectSetInteger(0, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, arrowName, OBJPROP_TOOLTIP,
                       StringFormat("BUY signal\n%s\nRSI=%.2f  EMA9=%.2f (slope+)  WMA45=%.2f\nEMA200=%.5f (Uptrend)",
                                    TimeToString(timeArr[i], TIME_DATE|TIME_MINUTES),
                                    buf_RSI[i], buf_EMA9[i], buf_WMA45[i], ema200Arr[i]));
    }
    else // validSell
    {
      // Mũi tên xuống (↓) đặt trên đỉnh nến — tín hiệu SELL trong downtrend
      // ANCHOR_BOTTOM: điểm anchor là đáy icon → arrow nằm ngược lên trên price
      // → tip ↓ ở phía dưới, sát đỉnh nến (cách highArr[i] một khoảng arrowOffset)
      const double price = highArr[i] + arrowOffset;
      ObjectCreate(0, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE,  234);
      ObjectSetInteger(0, arrowName, OBJPROP_ANCHOR,     ANCHOR_BOTTOM);
      ObjectSetInteger(0, arrowName, OBJPROP_COLOR,      InpArrowDownColor);
      ObjectSetInteger(0, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (0, arrowName, OBJPROP_TOOLTIP,
                       StringFormat("SELL signal\n%s\nRSI=%.2f  EMA9=%.2f (slope-)  WMA45=%.2f\nEMA200=%.5f (Downtrend)",
                                    TimeToString(timeArr[i], TIME_DATE|TIME_MINUTES),
                                    buf_RSI[i], buf_EMA9[i], buf_WMA45[i], ema200Arr[i]));
    }
  }

  // Cập nhật panel thông tin (dùng nến vừa đóng = index 1)
  // closeArr và ema200Arr đã được copy ở trên — dùng lại luôn
  if (InpShowPanel && rates_total > trendN + 1 && ema200Arr[1] > 0.0)
  {
    // Áp dụng cùng quy tắc N nến liên tiếp cho panel hiển thị
    bool panelTrendUp   = true;
    bool panelTrendDown = true;
    for (int k = 0; k < trendN; k++)
    {
      const int idx = 1 + k;
      if (ema200Arr[idx] <= 0.0) { panelTrendUp = false; panelTrendDown = false; break; }
      if (closeArr[idx] <= ema200Arr[idx]) panelTrendUp   = false;
      if (closeArr[idx] >= ema200Arr[idx]) panelTrendDown = false;
    }

    string trendTxt;
    color  trendClr;
    if      (panelTrendUp)   { trendTxt = StringFormat("Trend :  UPTREND   (%d closes > EMA200)", trendN); trendClr = InpArrowUpColor; }
    else if (panelTrendDown) { trendTxt = StringFormat("Trend :  DOWNTREND (%d closes < EMA200)", trendN); trendClr = InpArrowDownColor; }
    else                     { trendTxt = "Trend :  RANGE / SWITCHING";                                    trendClr = clrSilver; }

    UpdateLabel(LBL_TREND,    trendTxt,                                               trendClr);
    UpdateLabel(LBL_RSI_VAL,  StringFormat("RSI   : %6.2f", buf_RSI[1]),  clrMediumOrchid);
    UpdateLabel(LBL_EMA9VAL,  StringFormat("EMA9  : %6.2f", buf_EMA9[1]), clrDarkOrange);
    UpdateLabel(LBL_WMA45VAL, StringFormat("WMA45 : %6.2f", buf_WMA45[1]),clrDodgerBlue);
  }

  ChartRedraw(0);
  // Return số bar thật sự đã xử lý — nếu copyN < rates_total thì lần sau MT5
  // sẽ scan tiếp phần còn lại (do chênh prev_calculated)
  return copyN;
}

//+------------------------------------------------------------------+
