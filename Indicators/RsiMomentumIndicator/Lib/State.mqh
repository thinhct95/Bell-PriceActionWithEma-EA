//+------------------------------------------------------------------+
//| State.mqh                                                        |
//| Buffer plot (RSI, EMA9, WMA45) + mảng nội bộ cho alert/diag.    |
//| KHÔNG chứa logic — chỉ khai báo.                                 |
//+------------------------------------------------------------------+
#ifndef RSIMOM_STATE_MQH
#define RSIMOM_STATE_MQH

//+------------------------------------------------------------------+
//| Buffers hiển thị (plot) + mảng làm việc nội bộ                  |
//+------------------------------------------------------------------+
double buf_RSI[];
double buf_EMA9[];
double buf_WMA45[];
double buf_Signal[];   // nội bộ — +1 BUY, -1 SELL, 0 none (Alerts)
double buf_EMA200[];   // nội bộ — snapshot EMA200 theo bar (diag)
double buf_Trend[];    // nội bộ — +1 UP, -1 DOWN, 0 RANGE (diag)

//+------------------------------------------------------------------+
//| Indicator handles                                                |
//+------------------------------------------------------------------+
int h_RSI    = INVALID_HANDLE;
int h_EMA9   = INVALID_HANDLE;
int h_WMA45  = INVALID_HANDLE;
int h_EMA200 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Hằng số tên object                                               |
//+------------------------------------------------------------------+
const string OBJ_PREFIX  = "RsiMom_";
const string LBL_TITLE   = OBJ_PREFIX + "title";
const string LBL_TREND   = OBJ_PREFIX + "trend";
const string LBL_RSI_VAL = OBJ_PREFIX + "rsi";
const string LBL_EMA9VAL = OBJ_PREFIX + "ema9";
const string LBL_WMA45VAL= OBJ_PREFIX + "wma45";

//+------------------------------------------------------------------+
//| State notification — chống bắn trùng cùng 1 bar                  |
//| Lưu time của bar đã alert riêng cho mỗi hướng để không miss      |
//| tín hiệu ngược chiều trên cùng 1 bar (hiếm nhưng có thể).        |
//+------------------------------------------------------------------+
datetime g_lastAlertBuyBar  = 0;
datetime g_lastAlertSellBar = 0;
bool     g_firstCalc        = true;   // bỏ qua alert ở lần OnCalculate đầu (tránh spam history)

#endif // RSIMOM_STATE_MQH
