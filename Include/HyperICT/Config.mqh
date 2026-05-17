//+------------------------------------------------------------------+
//| Config.mqh                                                       |
//| Tham số input map spec → runtime                                 |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • InpHtf = H1 mặc định (§ HTF trend)                             |
//|  • InpSwingRange — pivot §1.4 P2 & xác nhận đỉnh/đáy sau phá Key |
//|  • InpFibMinRatio = 0.382 — chỉ tiên quyết trend (§ đầu)         |
//|  • InpSwingLookback — quét đủ H0–L1 lúc lock snapshot            |
//|  • Màu / alpha — §1.3 vẽ vùng cung-cầu                          |
//| CHƯA CÓ: trading, session, LTF                                   |
//+------------------------------------------------------------------+
#ifndef HYPERICT_CONFIG_MQH
#define HYPERICT_CONFIG_MQH

#include <HyperICT/Types.mqh>

input group "══ HTF Structure ══"
input ENUM_TIMEFRAMES InpHtf              = PERIOD_H1;  // §1: timeframe cấu trúc HTF
input int             InpSwingRange       = 3;        // §1.4: số nến mỗi bên pivot (confirm đỉnh/đáy)
input int             InpSwingLookback    = 400;      // quét swing lúc lock ban đầu
input double          InpFibMinRatio      = 0.382;    // § tiên quyết: H1→L0 vs L1→H1 (chỉ lúc lock trend)

input group "══ Hiển thị ══"
input bool            InpDrawSwings       = true;     // §1.3 label H0–L1
input bool            InpDrawZones        = true;     // §1.3 rectangle Key LV1/L2
input bool            InpDrawPanel        = true;
input uchar           InpZoneFillAlpha    = 72;
input color           InpClrBullHi      = clrDodgerBlue;
input color           InpClrBullLo      = clrDeepSkyBlue;
input color           InpClrBearHi      = clrOrangeRed;
input color           InpClrBearLo      = clrGold;
input color           InpClrSupply      = C'140,50,55';  // vùng cung @ L0
input color           InpClrDemand      = C'35,110,55'; // vùng cầu @ H0
input int             InpLabelFontSize   = 9;
input int             InpPanelX          = 12;
input int             InpPanelY          = 28;

input group "══ Debug ══"
input bool            InpDebug            = false;

const string HICT_OBJ_PFX = "HICT_";

#endif // HYPERICT_CONFIG_MQH
