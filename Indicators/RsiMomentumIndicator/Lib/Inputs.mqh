//+------------------------------------------------------------------+
//| Inputs.mqh                                                       |
//| Toàn bộ input parameters của RsiMomentumIndicator.               |
//| Được include từ RsiMomentumIndicator.mq5 (thư mục Lib/).         |
//+------------------------------------------------------------------+
#ifndef RSIMOM_INPUTS_MQH
#define RSIMOM_INPUTS_MQH

input group "Chỉ báo"
input int   InpRSIPeriod    = 14;
input int   InpEMA9Period   = 9;
input int   InpWMA45Period  = 45;
input int   InpEMATrendPeriod = 200;

input group "Bộ lọc trend"
input int   InpTrendConfirmBars = 1;   // số nến liên tiếp phải đóng cùng phía EMA200

input group "Bộ lọc RSI"
input double InpRSIOverbought = 70.0;   // RSI ≥ ngưỡng này → bỏ qua tín hiệu BUY
input double InpRSIOversold   = 30.0;   // RSI ≤ ngưỡng này → bỏ qua tín hiệu SELL

input group "Bộ lọc EMA9 vs WMA45 (chống nhiễu)"
input int    InpEma9PersistBars = 3;    // EMA9 phải ở cùng phía WMA45 N nến liên tiếp (gồm cả bar signal); 0 hoặc 1 = tắt

input group "Mũi tên giao cắt"
input color InpArrowUpColor   = clrLime;     // màu mũi tên khi RSI cắt lên WMA45
input color InpArrowDownColor = clrTomato;   // màu mũi tên khi RSI cắt xuống WMA45
input int   InpArrowOffsetPts = 30;          // khoảng cách mũi tên so với đỉnh/đáy nến (points)
input int   InpArrowSize      = 1;           // kích thước mũi tên

input group "Panel thông tin"
input bool  InpShowPanel = true;

input group "Cảnh báo / Notification (khi có entry mới)"
input bool   InpAlertPush   = true;     // Push lên app MT5 trên điện thoại (cần MetaQuotes ID)
input bool   InpAlertPopup  = true;     // Popup Alert() trên MT5 Desktop
input bool   InpAlertSound  = true;     // Phát âm thanh khi có signal
input string InpSoundBuy    = "alert.wav";   // file âm thanh BUY  (Sounds/ hoặc đường dẫn đầy đủ)
input string InpSoundSell   = "alert2.wav";  // file âm thanh SELL
input bool   InpAlertEmail  = false;    // Gửi email (cần cấu hình SMTP ở Tools→Options→Email)
input bool   InpAlertOnBar0 = false;    // Cảnh báo NGAY trên bar đang chạy (false = chỉ cảnh báo khi bar đóng)

#endif // RSIMOM_INPUTS_MQH
