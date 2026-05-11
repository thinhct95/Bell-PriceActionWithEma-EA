//+------------------------------------------------------------------+
//| Alerts.mqh                                                       |
//| Hệ thống cảnh báo entry mới: Push (mobile), Alert popup, Sound,  |
//| Email. Tự chống bắn trùng cùng 1 bar.                            |
//+------------------------------------------------------------------+
#ifndef RSIMOM_ALERTS_MQH
#define RSIMOM_ALERTS_MQH

//+------------------------------------------------------------------+
//| Bắn cảnh báo khi có signal mới                                   |
//|   - isBuy=true  → BUY, false → SELL                              |
//|   - barTime    = thời gian của bar có signal                     |
//|   - price      = giá tham chiếu (close của bar đó)               |
//|   Đi kèm 4 kênh: Push (mobile), Alert popup, Sound, Email        |
//+------------------------------------------------------------------+
void FireSignalAlert(const bool   isBuy,
                     const datetime barTime,
                     const double price,
                     const double rsiVal,
                     const double ema9Val,
                     const double wma45Val,
                     const double ema200Val)
{
  const string dir    = isBuy ? "BUY"  : "SELL";
  const string tf     = EnumToString((ENUM_TIMEFRAMES)_Period);
  // Lược TFM2/TFM5… → M2/M5… cho gọn
  const string tfTxt  = StringSubstr(tf, 7);  // bỏ tiền tố "PERIOD_"
  const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

  // Tin nhắn ngắn cho push notification (giới hạn 255 ký tự, mobile thường cắt sớm)
  const string pushMsg = StringFormat("[RsiMom] %s %s %s @ %s | RSI=%.1f EMA9=%.1f WMA45=%.1f",
                                      dir, _Symbol, tfTxt,
                                      DoubleToString(price, digits),
                                      rsiVal, ema9Val, wma45Val);

  // Tin nhắn dài cho Alert popup + email
  const string fullMsg = StringFormat("RsiMom %s signal\n%s %s @ %s\nRSI=%.2f  EMA9=%.2f  WMA45=%.2f\nEMA200=%s  (trend khớp)\nBar: %s",
                                      dir, _Symbol, tfTxt,
                                      DoubleToString(price, digits),
                                      rsiVal, ema9Val, wma45Val,
                                      DoubleToString(ema200Val, digits),
                                      TimeToString(barTime, TIME_DATE|TIME_MINUTES));

  // 1) Push lên điện thoại (cần đã đăng ký MetaQuotes ID ở Tools→Options→Notifications)
  if (InpAlertPush)
  {
    if (!SendNotification(pushMsg))
      PrintFormat("[RsiMom] SendNotification FAILED (err=%d) — kiểm tra MetaQuotes ID trong Options",
                  GetLastError());
  }

  // 2) Popup Alert trên desktop
  if (InpAlertPopup)
    Alert(pushMsg);

  // 3) Âm thanh
  if (InpAlertSound)
  {
    const string snd = isBuy ? InpSoundBuy : InpSoundSell;
    if (StringLen(snd) > 0)
      PlaySound(snd);
  }

  // 4) Email (cần cấu hình SMTP ở Tools→Options→Email)
  if (InpAlertEmail)
  {
    const string subj = StringFormat("RsiMom %s %s %s", dir, _Symbol, tfTxt);
    SendMail(subj, fullMsg);
  }

  // Vẫn log ra journal để dễ debug
  Print("[RsiMom] >>> ", pushMsg);
}

//+------------------------------------------------------------------+
//| Kiểm tra bar [1] (hoặc bar [0] nếu InpAlertOnBar0) và bắn alert  |
//| nếu có signal mới. Tự skip lần OnCalculate đầu tiên (load history)|
//+------------------------------------------------------------------+
void Alerts_CheckAndFire(const datetime &timeArr[],
                         const double   &closeArr[],
                         const double   &ema200Arr[],
                         const int       need,
                         const int       rates_total)
{
  // Lần đầu chạy — chỉ ghi nhận bar hiện tại để không bắn alert cho lịch sử
  if (g_firstCalc)
  {
    if (need > 1)
    {
      g_lastAlertBuyBar  = timeArr[1];
      g_lastAlertSellBar = timeArr[1];
    }
    g_firstCalc = false;
    return;
  }

  // Bar đang xét (1 = đã đóng, 0 = đang chạy)
  const int alertShift = InpAlertOnBar0 ? 0 : 1;

  if (alertShift >= need || alertShift + 1 >= rates_total) return;

  const datetime alertBarTime = timeArr[alertShift];

  if (buf_Signal[alertShift] > 0.5 && alertBarTime != g_lastAlertBuyBar)
  {
    FireSignalAlert(true, alertBarTime, closeArr[alertShift],
                    buf_RSI[alertShift], buf_EMA9[alertShift],
                    buf_WMA45[alertShift], ema200Arr[alertShift]);
    g_lastAlertBuyBar = alertBarTime;
  }
  else if (buf_Signal[alertShift] < -0.5 && alertBarTime != g_lastAlertSellBar)
  {
    FireSignalAlert(false, alertBarTime, closeArr[alertShift],
                    buf_RSI[alertShift], buf_EMA9[alertShift],
                    buf_WMA45[alertShift], ema200Arr[alertShift]);
    g_lastAlertSellBar = alertBarTime;
  }
}

#endif // RSIMOM_ALERTS_MQH
