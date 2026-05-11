//+------------------------------------------------------------------+
//| Handles.mqh                                                      |
//| Tạo / giải phóng indicator handles (RSI, EMA9/RSI, WMA45/RSI,    |
//| EMA200) và attach EMA200 lên main chart window.                   |
//+------------------------------------------------------------------+
#ifndef RSIMOM_HANDLES_MQH
#define RSIMOM_HANDLES_MQH

//+------------------------------------------------------------------+
//| Tạo tất cả indicator handle. Trả về true nếu thành công.         |
//+------------------------------------------------------------------+
bool Handles_CreateAll()
{
  // RSI(close)
  h_RSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
  if (h_RSI == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle RSI"); return false; }

  // EMA9 và WMA45 tính trên dữ liệu của h_RSI (buffer 0 của RSI)
  h_EMA9 = iMA(_Symbol, _Period, InpEMA9Period, 0, MODE_EMA, h_RSI);
  if (h_EMA9 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle EMA9(RSI)"); return false; }

  h_WMA45 = iMA(_Symbol, _Period, InpWMA45Period, 0, MODE_LWMA, h_RSI);
  if (h_WMA45 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle WMA45(RSI)"); return false; }

  h_EMA200 = iMA(_Symbol, _Period, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
  if (h_EMA200 == INVALID_HANDLE)
    { Print("[RsiMom] Không tạo được handle EMA200"); return false; }

  // Gắn EMA200 lên cửa sổ chính (window 0) của chart hiện tại
  if (!ChartIndicatorAdd(ChartID(), 0, h_EMA200))
    PrintFormat("[RsiMom] Không thể gắn EMA200 lên chart (err=%d)", GetLastError());

  return true;
}

//+------------------------------------------------------------------+
//| Giải phóng tất cả indicator handle                                |
//+------------------------------------------------------------------+
void Handles_ReleaseAll()
{
  if (h_RSI    != INVALID_HANDLE) IndicatorRelease(h_RSI);
  if (h_EMA9   != INVALID_HANDLE) IndicatorRelease(h_EMA9);
  if (h_WMA45  != INVALID_HANDLE) IndicatorRelease(h_WMA45);
  if (h_EMA200 != INVALID_HANDLE) IndicatorRelease(h_EMA200);
}

#endif // RSIMOM_HANDLES_MQH
