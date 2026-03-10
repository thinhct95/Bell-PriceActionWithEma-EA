#ifndef EA_ICT_CL__CONFIG_MQH
#define EA_ICT_CL__CONFIG_MQH

// Module: Config
// This file now hosts EA inputs. Keep other types (enums/structs/globals) in the .mq5
// until you intentionally migrate them to State/Config to avoid redefinition.

//====================================================
// INPUTS
//====================================================
input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_D1;  // Bias TF (HTF)
input ENUM_TIMEFRAMES InpMiddleTF        = PERIOD_H1;  // FVG + trend TF (MTF)
input ENUM_TIMEFRAMES InpTriggerTF       = PERIOD_M5;  // Entry confirmation (LTF)

input double InpRiskPercent              = 1.0;        // Risk % per trade
input double InpRiskReward               = 2.0;        // TP/SL ratio
input double InpMaxDailyLossPct          = 3.0;        // Max daily loss %

input int    InpLondonStartHour          = 8;          // London open (UTC)
input int    InpLondonEndHour            = 17;         // London close (UTC)
input int    InpNYStartHour              = 13;         // NY open (UTC)
input int    InpNYEndHour                = 22;         // NY close (UTC)

input int    InpSwingRange               = 3;          // Bars each side for swing confirm
input int    InpSwingLookback            = 50;         // MiddleTF swing scan bars
input int    InpTriggerSwingLookback     = 30;         // TriggerTF swing scan bars

input int    InpFVGMaxAliveMin           = 4320;       // Max FVG lifetime (min) = 72h (cả PENDING + TOUCHED)
input int    InpFVGScanBars              = 50;         // MiddleTF bars to scan for FVGs
input double InpFVGMinBodyPct            = 60.0;       // Mid-candle min body %
input int    InpMSSMinDepthPts           = 30;         // MSS min swing depth (points): |tH0-tL0| phải >= giá trị này

input long   InpMagicNumber              = 20250308;   // EA magic number
input int    InpSlippage                 = 5;          // Max slippage (points)

input bool   InpDebugLog                 = true;       // Journal logging
input bool   InpDebugDraw                = true;       // Chart drawing

#endif // EA_ICT_CL__CONFIG_MQH

