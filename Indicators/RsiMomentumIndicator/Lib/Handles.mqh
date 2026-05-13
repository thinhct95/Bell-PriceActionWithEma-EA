//+------------------------------------------------------------------+
//| Handles.mqh                                                      |
//| Tạo / giải phóng handle RSI, EMA9/WMA45 trên RSI, EMA200(close). |
//| EMA200 chỉ CopyBuffer — không ChartIndicatorAdd.               |
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
