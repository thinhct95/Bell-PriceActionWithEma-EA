//+------------------------------------------------------------------+
//|  EA_Trend_Structure_EMA50.mq5                                    |
//|  Tác giả: Bell Hyperpush                                          |
//|  Mục tiêu:                                                       |
//|  - Xác định xu hướng theo 2 yếu tố:                              |
//|    (1) Giá nằm trên/dưới EMA50                                   |
//|    (2) Cấu trúc đỉnh-đáy HH-HL hoặc LH-LL                       |
//|  - Vẽ marker xu hướng & đỉnh đáy lên biểu đồ                     |
//|  - Có tùy chỉnh SwingDepth để điều chỉnh độ nhạy tìm swing       |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

// ================== INPUTS =========================================
#define TrendTF PERIOD_M5 // timeframe dùng cho xu hướng (mặc định M5)
// #define SwingDepth 5      // Độ sâu swing để xác định đỉnh/đáy (mặc định = 5)

input int EMA_Period   = 50;     // Chu kỳ EMA
input int LookbackBars = 20;     // Số nến để quét tìm đỉnh/đáy
input int SwingDepth = 5;      // Độ sâu để xác định swing (mặc định = 3)
input bool VisualizeEMAs = true; // Hiển thị EMA lên chart hay không

// ================== ENUMS =========================================
enum TREND_RESULT { TREND_NEUTRAL = 0, TREND_UP, TREND_DOWN, TREND_SIDEWAY };

// ================== BIẾN TOÀN CỤC ================================
int handleEMA = INVALID_HANDLE;

// ================== HÀM TIỆN ÍCH ================================
string TrendToStr(TREND_RESULT t)
{
   switch(t)
   {
      case TREND_UP:       return "UPTREND";
      case TREND_DOWN:     return "DOWNTREND";
      case TREND_SIDEWAY:  return "SIDEWAY";
      default:             return "NEUTRAL";
   }
}

// ================================================================
// HÀM: VẼ MARKER XU HƯỚNG (vẽ text báo hướng giá trên chart)
// ================================================================
void DrawTrendMarker(TREND_RESULT trend)
{
   string name = "TrendMarker_" + TimeToString(TimeCurrent(), TIME_SECONDS);
   double price = iClose(_Symbol, TrendTF, 1);
   datetime barTime = iTime(_Symbol, TrendTF, 1);

   color c = clrWhite;
   string label = "";

   if(trend == TREND_UP)         { c = clrLime;   label = "↑ UPTREND";  }
   else if(trend == TREND_DOWN)  { c = clrRed;    label = "↓ DOWNTREND"; }
   else if(trend == TREND_SIDEWAY){ c = clrYellow; label = "→ SIDEWAY"; }

   ObjectCreate(0, name, OBJ_TEXT, 0, barTime, price);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

// ================================================================
// HÀM: VẼ MARKER ĐỈNH / ĐÁY (đánh dấu swing)
// ================================================================
void DrawSwingMarker(datetime t, double price, bool isHigh)
{
   string name = (isHigh ? "High_" : "Low_") + TimeToString(t, TIME_SECONDS);
   string text = isHigh ? "▲ High" : "▼ Low";
   color c = isHigh ? clrRed : clrDodgerBlue;

   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

// ================================================================
// HÀM: TÌM ĐỈNH / ĐÁY GẦN NHẤT TRONG LookbackBars nến
// - Sử dụng SwingDepth để quy định khoảng kiểm tra (càng lớn càng "mượt")
// ================================================================
bool FindRecentSwing(double &lastHigh, datetime &timeHigh, double &lastLow, datetime &timeLow)
{
   int bars = MathMin(LookbackBars, Bars(_Symbol, TrendTF));
   if(bars < SwingDepth * 2 + 1) return false;

   double highPrev = 0.0, lowPrev = 0.0;
   datetime tHighPrev = 0, tLowPrev = 0;

   // Duyệt qua các nến trong vùng quan sát
   for(int i = SwingDepth; i < bars - SwingDepth; i++)
   {
      double h = iHigh(_Symbol, TrendTF, i);
      double l = iLow(_Symbol, TrendTF, i);

      bool isSwingHigh = true;
      bool isSwingLow  = true;

      // Kiểm tra SwingDepth nến hai bên
      for(int j = i - SwingDepth; j <= i + SwingDepth; j++)
      {
         if(j == i) continue;
         if(iHigh(_Symbol, TrendTF, j) > h) isSwingHigh = false;
         if(iLow(_Symbol, TrendTF, j) < l)  isSwingLow  = false;
         if(!isSwingHigh && !isSwingLow) break;
      }

      // Nếu là đỉnh rõ ràng
      if(isSwingHigh)
      {
         highPrev = h;
         tHighPrev = iTime(_Symbol, TrendTF, i);
         DrawSwingMarker(tHighPrev, highPrev, true);
         // chỉ lấy đỉnh gần nhất → break
         break;
      }

      // Nếu là đáy rõ ràng
      if(isSwingLow)
      {
         lowPrev = l;
         tLowPrev = iTime(_Symbol, TrendTF, i);
         DrawSwingMarker(tLowPrev, lowPrev, false);
         break;
      }
   }

   lastHigh = highPrev;
   timeHigh = tHighPrev;
   lastLow  = lowPrev;
   timeLow  = tLowPrev;

   return (highPrev > 0 && lowPrev > 0);
}

// ================================================================
// HÀM: XÁC ĐỊNH XU HƯỚNG (dựa trên EMA và cấu trúc swing)
// ================================================================
TREND_RESULT GetTrendDirection()
{
   double ema = 0.0;
   double emaBuf[];

   // Lấy giá trị EMA gần nhất
   if(handleEMA != INVALID_HANDLE)
      if(CopyBuffer(handleEMA, 0, 1, 1, emaBuf) > 0)
         ema = emaBuf[0];

   double price = iClose(_Symbol, TrendTF, 1);

   // Tìm đỉnh/đáy gần nhất
   double high1 = 0.0, low1 = 0.0;
   datetime timeHigh1 = 0, timeLow1 = 0;
   FindRecentSwing(high1, timeHigh1, low1, timeLow1);

   // ==================
   // Logic xu hướng cơ bản:
   // - Giá > EMA và đỉnh cao hơn đáy → Uptrend
   // - Giá < EMA và đáy thấp hơn đỉnh → Downtrend
   // - Còn lại → Sideway
   // ==================
   if(price > ema && high1 > low1)
      return TREND_UP;
   else if(price < ema && low1 < high1)
      return TREND_DOWN;
   else
      return TREND_SIDEWAY;
}

// ================================================================
// HÀM: VÒNG LẶP CHÍNH
// ================================================================
void OnTick()
{
   static TREND_RESULT lastTrend = TREND_NEUTRAL;

   TREND_RESULT trend = GetTrendDirection();

   // Chỉ báo thay đổi xu hướng khi có sự chuyển trạng thái
   if(trend != lastTrend && trend != TREND_NEUTRAL)
   {
      PrintFormat("[TREND] %s → %s", TrendToStr(lastTrend), TrendToStr(trend));
      DrawTrendMarker(trend);
      Comment("Current Trend: ", TrendToStr(trend));
   }

   lastTrend = trend;
}

// ================================================================
// KHỞI TẠO
// ================================================================
int OnInit()
{
   // Tạo handle EMA
   handleEMA = iMA(_Symbol, TrendTF, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEMA == INVALID_HANDLE)
   {
      Print("Error creating EMA handle: ", GetLastError());
      return(INIT_FAILED);
   }

   if(VisualizeEMAs)
      ChartIndicatorAdd(ChartID(), 0, handleEMA);

   Print("EA Initialized.");
   return(INIT_SUCCEEDED);
}

// ================================================================
// GIẢI PHÓNG
// ================================================================
void OnDeinit(const int reason)
{
   if(handleEMA != INVALID_HANDLE)
      IndicatorRelease(handleEMA);
   Comment("");
}
