//+------------------------------------------------------------------+
//|  EA_Trend_EMA50_EMA200_v1.1.mq5                                 |
//|  Tác giả: Bell Hyperpush                                         |
//|  Mục đích:                                                       |
//|  - Xác định xu hướng bằng EMA50 & EMA200 (theo TrendTF)          |
//|  - In ra khi xu hướng thay đổi, vẽ marker lên chart              |
//|  - Tùy chọn hiển thị EMA trên biểu đồ                            |
//+------------------------------------------------------------------+
#property copyright "Bell Hyperpush"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

#define TrendTF PERIOD_M5 // Test
#define EntryTF PERIOD_M5 // Test

int handleEMAFast = INVALID_HANDLE;
int handleEMASlow = INVALID_HANDLE;

// ================== INPUTS =========================================
// input ENUM_TIMEFRAMES TrendTF = PERIOD_M15;   // khung thời gian dùng để lọc xu hướng
// input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;   // khung thời gian để tìm điểm vào
input int EMA_Fast = 50;                     // EMA nhanh
input int EMA_Slow = 200;                    // EMA chậm
input double RiskPercent = 1.0;              // rủi ro % equity mỗi lệnh
input double TP_Multiplier = 2.0;            // tỉ lệ TP = Risk * multiplier
input int MaxOpenPositions = 2;              // tối đa số lệnh mở
input bool VisualizeEMAs = true;             // có vẽ EMA lên chart không
input int TrendShift = 1;                    // đọc nến đóng (tránh nến đang chạy)

// ================== ENUMS & UTILITIES ==============================
enum EMA_COND     { EMA_INSUFFICIENT = 0, EMA_UPTREND, EMA_DOWNTREND, EMA_NEUTRAL };
enum TREND_RESULT { TREND_NEUTRAL = 0, TREND_UPTREND, TREND_DOWNTREND, TREND_SIDEWAY_RESULT };

string TrendResultToString(const TREND_RESULT t) {
   switch(t) {
      case TREND_UPTREND:       return "UPTREND";
      case TREND_DOWNTREND:     return "DOWNTREND";
      case TREND_SIDEWAY_RESULT:return "SIDEWAY";
      default:                  return "NEUTRAL";
   }
}

// ================== XÁC ĐỊNH XU HƯỚNG =============================
TREND_RESULT GetTrendDirection() 
{
   int shift = TrendShift;
   double emaFast = 0.0, emaSlow = 0.0;
   double buf[];

   // --- Copy EMA buffers từ khung TrendTF ---
   if(handleEMAFast != INVALID_HANDLE)
      if(CopyBuffer(handleEMAFast, 0, shift, 1, buf) > 0) emaFast = buf[0];
   if(handleEMASlow != INVALID_HANDLE)
      if(CopyBuffer(handleEMASlow, 0, shift, 1, buf) > 0) emaSlow = buf[0];

   double priceClose = iClose(_Symbol, TrendTF, shift);
   TREND_RESULT trendEnum = TREND_NEUTRAL;

   if(priceClose <= 0.0 || emaFast <= 0.0 || emaSlow <= 0.0)
      trendEnum = TREND_NEUTRAL;
   else if(emaFast > emaSlow)
      trendEnum = TREND_UPTREND;
   else if(emaFast < emaSlow)
      trendEnum = TREND_DOWNTREND;
   else
      trendEnum = TREND_SIDEWAY_RESULT;

   // --- Debug log ---
   PrintFormat("[TREND DEBUG] %s | EMA%d=%.5f | EMA%d=%.5f | Close=%.5f | => %s",
               TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
               EMA_Fast, emaFast, EMA_Slow, emaSlow, priceClose,
               TrendResultToString(trendEnum));

   return trendEnum;
}

// ================== VẼ MARKER XU HƯỚNG =============================
void DrawTrendChangeMarker(TREND_RESULT trend)
{
   string name = "TrendChange_" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   double price = iClose(_Symbol, TrendTF, 1);
   datetime barTime = iTime(_Symbol, TrendTF, 1);

   color c = clrWhite;
   string label = "";

   if(trend == TREND_UPTREND)       { c = clrLime;   label = "↑ UPTREND";  }
   else if(trend == TREND_DOWNTREND){ c = clrRed;    label = "↓ DOWNTREND"; }
   else if(trend == TREND_SIDEWAY_RESULT) { c = clrYellow; label = "→ SIDEWAY"; }

   ObjectCreate(0, name, OBJ_TEXT, 0, barTime, price);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   // ObjectSetDouble(0, name, OBJPROP_YDISTANCE, 10); // tránh chữ đè lên nến
}

// ================== VÒNG LẶP CHÍNH =================================
void OnTick()
{
   static TREND_RESULT lastTrend = TREND_NEUTRAL;
   static datetime lastLogTime = 0;

   TREND_RESULT trend = GetTrendDirection();

   // Nếu trend mới khác trend cũ → in log & đánh dấu
   if(trend != lastTrend && lastTrend != TREND_NEUTRAL) 
   {
      string msg = StringFormat("TREND CHANGED: %s → %s",
                                TrendResultToString(lastTrend),
                                TrendResultToString(trend));
      Print(msg);
      Comment("Current Trend: ", TrendResultToString(trend));
      DrawTrendChangeMarker(trend);
   }

   lastTrend = trend;

   // Cập nhật comment mỗi phút
   if(TimeCurrent() - lastLogTime >= 60) {
      Comment("Current Trend: ", TrendResultToString(trend));
      lastLogTime = TimeCurrent();
   }
}

// ================== KHỞI TẠO & KẾT THÚC ===========================
int OnInit()
{
   Sleep(500);

   handleEMAFast = iMA(_Symbol, TrendTF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(_Symbol, TrendTF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEMAFast == INVALID_HANDLE || handleEMASlow == INVALID_HANDLE) {
      Print("Failed to create EMA handles. Err=", GetLastError());
      return(INIT_FAILED);
   }

   PrintFormat("Init: EA=%s | EMA_Fast=%d | EMA_Slow=%d | TF=%s",
               __FILE__, EMA_Fast, EMA_Slow, EnumToString(TrendTF));

   if(VisualizeEMAs) {
      long chart_id = ChartID();
      bool ok1 = ChartIndicatorAdd(chart_id, 0, handleEMAFast);
      bool ok2 = ChartIndicatorAdd(chart_id, 0, handleEMASlow);
      if(!ok1 || !ok2)
         Print("Warning: ChartIndicatorAdd failed. Err=", GetLastError());
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(handleEMAFast != INVALID_HANDLE) IndicatorRelease(handleEMAFast);
   if(handleEMASlow != INVALID_HANDLE) IndicatorRelease(handleEMASlow);
   Comment(""); // clear chart comment
}
