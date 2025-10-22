//+------------------------------------------------------------------+
//|  EA_Trend_EMA50_EMA200.mq5                                 |
//|  Phiên bản: 1.0                                                  |
//|  Mục đích:                                                       |
//|  - Xác định xu hướng bằng EMA50 & EMA200 (m15)                    |
//|  - Vào lệnh trên M5 khi có tín hiệu: 2 đáy / 2 đỉnh / nến nhấn chìm |
//|  - Rủi ro cố định: 1% Equity mỗi lệnh                            |
//|  - Giới hạn tối đa 2 lệnh mở cùng lúc                            |
//|  - Tùy chọn hiển thị EMA lên biểu đồ                              |
//+------------------------------------------------------------------+
#property copyright "Bell Hyperpush"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;
int handleEMAFast = INVALID_HANDLE;
int handleEMASlow = INVALID_HANDLE;

// ================== INPUTS =========================================
input ENUM_TIMEFRAMES TrendTF = PERIOD_H1;   // khung thời gian dùng để lọc xu hướng
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;   // khung thời gian để tìm điểm vào
input int EMA_Fast = 50;                     // EMA nhanh
input int EMA_Slow = 200;                    // EMA chậm
input double RiskPercent = 1.0;              // rủi ro % equity cho mỗi lệnh
input double TP_Multiplier = 2.0;            // tỉ lệ TP = Risk * multiplier
input int MaxOpenPositions = 2;              // tối đa 2 lệnh mở
input double DoubleTolerancePoints = 30;     // dung sai giữa 2 đáy/đỉnh
input int MinBarsBetweenDouble = 4;          // khoảng cách tối thiểu giữa 2 đáy/đỉnh
input int SL_Pips_Default = 40;              // SL mặc định (points)
input int Slippage = 10;                     // trượt giá tối đa
input bool VisualizeEMAs = true;             // có vẽ EMA lên chart không
input int TrendShift = 1;                    // shift dùng để đọc nến đóng (tránh nến đang hình thành)
input int StructureRecentOffset = 1;         // offset cho nến recent khi kiểm tra cấu trúc (high1/low1)
input int StructurePrevOffset = 2;           // offset cho nến trước đó khi kiểm tra cấu trúc (high2/low2)

// ================== FUNCTIONS =====================================

// ----- Enums for EMA and trend result (avoid hard-coded strings) -----
enum EMA_COND     { EMA_INSUFFICIENT = 0, EMA_UPTREND, EMA_DOWNTREND, EMA_NEUTRAL };
enum TREND_RESULT { TREND_NEUTRAL = 0, TREND_UPTREND, TREND_DOWNTREND, TREND_SIDEWAY_RESULT };

string EmaConditionToString(const int e) {
   switch(e) {
      case EMA_UPTREND: return "EMA Uptrend";
      case EMA_DOWNTREND: return "EMA Downtrend";
      case EMA_NEUTRAL: return "EMA Neutral";
      default: return "EMA InsufficientData";
   }
}

string TrendResultToString(const int r) {
   switch(r) {
      case TREND_UPTREND: return "UPTREND";
      case TREND_DOWNTREND: return "DOWNTREND";
      case TREND_SIDEWAY_RESULT: return "SIDEWAY";
      default: return "NEUTRAL";
   }
}

// Xác định xu hướng hiện tại
string GetTrendDirection() {
   int shift = TrendShift; // tránh dùng nến đang chạy (mặc định = 1)
   double emaFast = 0.0;
   double emaSlow = 0.0;
   double buf[];

   // read EMA50 value by copying buffer from handle
   if(handleEMAFast != INVALID_HANDLE) {
      if(CopyBuffer(handleEMAFast, 0, shift, 1, buf) > 0) emaFast = buf[0];
   }
   
   // read EMA200 value by copying buffer from handle
   if(handleEMASlow != INVALID_HANDLE) {
      if(CopyBuffer(handleEMASlow, 0, shift, 1, buf) > 0) emaSlow = buf[0];
   }
   double priceClose = iClose(_Symbol, TrendTF, shift);

   int emaEnum = EMA_INSUFFICIENT;
   int trendEnum = TREND_NEUTRAL;

   // --- B2: Kiểm tra EMA (an toàn: đảm bảo dữ liệu hợp lệ)
   if(priceClose <= 0.0 || emaFast <= 0.0 || emaSlow <= 0.0) {
      emaEnum = EMA_INSUFFICIENT;
      trendEnum = TREND_NEUTRAL;
   }
   else if(emaFast > emaSlow ) {  // && priceClose > emaFast
      emaEnum = EMA_UPTREND;
      trendEnum = TREND_UPTREND;
   }
   else if(emaFast < emaSlow) { // && priceClose < emaFast
      emaEnum = EMA_DOWNTREND;
      trendEnum = TREND_DOWNTREND;
   }
   else {
      emaEnum = EMA_NEUTRAL;
      trendEnum = TREND_SIDEWAY_RESULT;
   }

   // --- Log chi tiết (debug)
   PrintFormat("[TREND DEBUG] === %s ===", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   // print the EMA periods and their current values instead of hard-coded labels
   PrintFormat("EMA%d=%.5f | EMA%d=%.5f | PriceClose=%.5f", EMA_Fast, emaFast, EMA_Slow, emaSlow, priceClose);
   PrintFormat("EMA: %s | => TREND: %s", EmaConditionToString(emaEnum), TrendResultToString(trendEnum));

   return TrendResultToString(trendEnum);
}


// ================== VÒNG LẶP CHÍNH ================================
void OnTick()
{
   static datetime lastCheck = 0;

   // chỉ check 1 lần mỗi phút
   if(TimeCurrent() - lastCheck >= 60) {
      string trend = GetTrendDirection();
      Comment("Current Trend (", EnumToString(TrendTF), "): ", trend);
      lastCheck = TimeCurrent();
   }
}


// ================== KHỞI TẠO & KẾT THÚC ===========================
int OnInit() {
   Sleep(500); // đợi chart visual load hoàn tất

   handleEMAFast  = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEMAFast == INVALID_HANDLE || handleEMASlow == INVALID_HANDLE) {
      Print("Failed to create EMA handles. Err=", GetLastError());
      return(INIT_FAILED);
   }

   // Diagnostic: print which EA file is running and the active EMA periods (helps detect .set overrides)
   PrintFormat("Init: EA=%s EMA_Fast=%d EMA_Slow=%d handles=(%d,%d)", __FILE__, EMA_Fast, EMA_Slow, handleEMAFast, handleEMASlow);

   if(VisualizeEMAs) {
      long chart_id = ChartID();
      bool ok1 = ChartIndicatorAdd(chart_id, 0, handleEMAFast);
      bool ok2 = ChartIndicatorAdd(chart_id, 0, handleEMASlow);

      if(!ok1 || !ok2)
         Print("Warning: ChartIndicatorAdd failed. Err=", GetLastError());
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if(handleEMAFast  != INVALID_HANDLE) IndicatorRelease(handleEMAFast);
   if(handleEMASlow != INVALID_HANDLE) IndicatorRelease(handleEMASlow);
}
