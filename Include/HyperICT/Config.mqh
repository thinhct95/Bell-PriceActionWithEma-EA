//+------------------------------------------------------------------+
//| Config.mqh — inputs & hằng số                                    |
//+------------------------------------------------------------------+
#ifndef HYPERICT_CONFIG_MQH
#define HYPERICT_CONFIG_MQH

#include <HyperICT/Types.mqh>

input group "══ HTF Structure ══"
input ENUM_TIMEFRAMES InpHtf              = PERIOD_H1;
input int             InpSwingRange       = 3;
input int             InpSwingLookback    = 400;
input double          InpFibMinRatio      = 0.382;

input group "══ Hiển thị ══"
input bool            InpDrawSwings       = true;
input bool            InpDrawZones        = true;
input bool            InpDrawPanel        = true;
input uchar           InpZoneFillAlpha    = 72;
input color           InpClrBullHi      = clrDodgerBlue;
input color           InpClrBullLo      = clrDeepSkyBlue;
input color           InpClrBearHi      = clrOrangeRed;
input color           InpClrBearLo      = clrGold;
input color           InpClrSupply      = C'140,50,55';
input color           InpClrDemand      = C'35,110,55';
input int             InpLabelFontSize   = 9;
input int             InpPanelX          = 12;
input int             InpPanelY          = 28;

input group "══ Debug ══"
input bool            InpDebug            = false;

const string HICT_OBJ_PFX = "HICT_";

#endif // HYPERICT_CONFIG_MQH
