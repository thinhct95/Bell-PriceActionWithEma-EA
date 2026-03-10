#ifndef EA_ICT_CL__CONFIG_MQH
#define EA_ICT_CL__CONFIG_MQH  // Tránh include trùng

// Module: Config – toàn bộ input của EA

//====================================================
// INPUTS
//====================================================
input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_D1;  // Timeframe xác định bias (D1)
input ENUM_TIMEFRAMES InpMiddleTF        = PERIOD_H1;  // TF quét FVG + trend (H1)
input ENUM_TIMEFRAMES InpTriggerTF       = PERIOD_M5;  // TF xác nhận entry bằng MSS (M5)

input double InpRiskPercent              = 1.0;        // % balance risk mỗi lệnh
input double InpRiskReward               = 2.0;        // Tỷ lệ R:R (TP = entry ± R*riskDist)
input double InpMaxDailyLossPct          = 3.0;        // % lỗ tối đa trong ngày → dừng trade

input int    InpLondonStartHour          = 8;          // Giờ mở London (UTC)
input int    InpLondonEndHour            = 17;         // Giờ đóng London (UTC)
input int    InpNYStartHour               = 13;         // Giờ mở NY (UTC)
input int    InpNYEndHour                 = 22;        // Giờ đóng NY (UTC)

input int    InpSwingRange               = 3;          // Số nến mỗi bên để xác nhận swing high/low
input int    InpSwingLookback             = 50;        // Số bar quét swing trên MiddleTF (H1)
input int    InpTriggerSwingLookback     = 30;         // Số bar quét swing trên TriggerTF (M5)

input int    InpFVGMaxAliveMin           = 4320;       // Thời gian sống FVG tối đa (phút), 4320 = 72h
input int    InpFVGScanBars              = 50;        // Số bar H1 quét tìm FVG
input double InpFVGMinBodyPct            = 60.0;      // Nến giữa FVG: body % tối thiểu (strong candle)
input int    InpMSSMinDepthPts           = 30;        // Độ sâu swing M5 tối thiểu (point) mới chấp nhận MSS

input long   InpMagicNumber              = 20250308;  // Magic number cho lệnh EA
input int    InpSlippage                 = 5;         // Slippage tối đa (point) khi gửi lệnh

input bool   InpDebugLog                 = true;      // Bật log ra Journal
input bool   InpDebugDraw                = true;      // Bật vẽ swing/FVG/order/debug panel

#endif // EA_ICT_CL__CONFIG_MQH

