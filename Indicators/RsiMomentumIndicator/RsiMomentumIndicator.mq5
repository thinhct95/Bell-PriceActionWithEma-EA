//+------------------------------------------------------------------+
//| RsiMomentumIndicator.mq5                                         |
//| Hiển thị trong cửa sổ phụ: RSI14, EMA9(RSI), WMA45(RSI)         |
//| Trên chart chính: mũi tên giao cắt (EMA200 chỉ tính nội bộ).     |
//| Panel góc trên-phải: trend, giá trị RSI / EMA9 / WMA45           |
//|                                                                  |
//| Source code được tách thành các module trong thư mục Lib/:       |
//|   Inputs.mqh       — input parameters                            |
//|   State.mqh        — buffers, handles, constants, alert state    |
//|   Handles.mqh      — tạo/giải phóng indicator handle             |
//|   Panel.mqh        — panel thông tin góc trên-phải               |
//|   Alerts.mqh       — Push/Popup/Sound/Email khi có entry         |
//|   SignalScan.mqh   — phát hiện cross + vẽ arrow                  |
//|   Diagnostics.mqh  — log chẩn đoán lần đầu                       |
//+------------------------------------------------------------------+
#property copyright   "RsiMomentumIndicator"
#property version     "1.10"
#property indicator_separate_window
#property indicator_buffers 6
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
//| Modules — thứ tự include theo dependency                         |
//+------------------------------------------------------------------+
#include "Lib/Inputs.mqh"
#include "Lib/State.mqh"
#include "Lib/Handles.mqh"
#include "Lib/Panel.mqh"
#include "Lib/Alerts.mqh"
#include "Lib/SignalScan.mqh"
#include "Lib/Diagnostics.mqh"

//+------------------------------------------------------------------+
//| Khởi tạo indicator                                               |
//+------------------------------------------------------------------+
int OnInit()
{
  // Reset state notification (tránh re-fire alert cũ khi đổi TF / reload)
  g_lastAlertBuyBar  = 0;
  g_lastAlertSellBar = 0;
  g_firstCalc        = true;

  // Đăng ký buffer — đặt AS_SERIES để [0] = nến hiện tại
  SetIndexBuffer(0, buf_RSI,    INDICATOR_DATA);
  SetIndexBuffer(1, buf_EMA9,   INDICATOR_DATA);
  SetIndexBuffer(2, buf_WMA45,  INDICATOR_DATA);
  SetIndexBuffer(3, buf_Signal, INDICATOR_CALCULATIONS); // ẩn — phục vụ EA
  SetIndexBuffer(4, buf_EMA200, INDICATOR_CALCULATIONS); // ẩn — EMA200 cho EA
  SetIndexBuffer(5, buf_Trend,  INDICATOR_CALCULATIONS); // ẩn — trend cho EA

  ArraySetAsSeries(buf_RSI,    true);
  ArraySetAsSeries(buf_EMA9,   true);
  ArraySetAsSeries(buf_WMA45,  true);
  ArraySetAsSeries(buf_Signal, true);
  ArraySetAsSeries(buf_EMA200, true);
  ArraySetAsSeries(buf_Trend,  true);

  IndicatorSetString (INDICATOR_SHORTNAME, StringFormat("RsiMom(%d)", InpRSIPeriod));
  IndicatorSetInteger(INDICATOR_DIGITS, 2);

  if (!Handles_CreateAll()) return INIT_FAILED;

  Panel_CreateAll();

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Dọn dẹp khi gỡ indicator                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  Handles_ReleaseAll();

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
  {
    static datetime lastWarn = 0;
    if (TimeCurrent() - lastWarn > 30)
    {
      PrintFormat("[RsiMom] Source not ready yet: RSI=%d EMA9=%d WMA45=%d EMA200=%d (rates_total=%d)",
                  rsiBars, ema9Bars, wmaBars, ema200Bars, rates_total);
      lastWarn = TimeCurrent();
    }
    return 0; // chưa có dữ liệu — return 0 để MT5 retry ngay
  }

  // Chỉ copy số bar mà TẤT CẢ source (incl. EMA200) đã tính xong
  // → tránh CopyBuffer EMA200 fail giữa chừng làm buf_EMA200/buf_Trend stale
  const int srcMin = MathMin(MathMin(MathMin(rsiBars, ema9Bars), wmaBars), ema200Bars);
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

  // ── Phát hiện cross + vẽ arrow ───────────────────────────────────
  SignalScan_Run(barsToScan, rates_total, need, trendN,
                 timeArr, highArr, lowArr, closeArr, ema200Arr);

  // ── Bắn alert nếu có signal MỚI trên bar đã đóng ─────────────────
  Alerts_CheckAndFire(timeArr, closeArr, ema200Arr, need, rates_total);

  // ── Cập nhật panel thông tin (góc trên-phải) ─────────────────────
  Panel_Update(closeArr, ema200Arr, trendN, rates_total);

  ChartRedraw(0);

  // ── Diagnostic: log lần đầu OnCalculate hoàn thành full ──────────
  Diagnostics_FirstPass(rates_total, copyN, trendN, need, closeArr);

  // Return số bar thật sự đã xử lý — nếu copyN < rates_total thì lần sau MT5
  // sẽ scan tiếp phần còn lại (do chênh prev_calculated)
  return copyN;
}
//+------------------------------------------------------------------+
