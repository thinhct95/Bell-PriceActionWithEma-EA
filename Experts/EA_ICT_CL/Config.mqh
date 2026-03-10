#ifndef EA_ICT_CL__CONFIG_MQH
#define EA_ICT_CL__CONFIG_MQH

input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_D1;
input ENUM_TIMEFRAMES InpMiddleTF        = PERIOD_H1;
input ENUM_TIMEFRAMES InpTriggerTF       = PERIOD_M5;

input double InpRiskPercent              = 1.0;
input double InpRiskReward               = 2.0;
input double InpMaxDailyLossPct          = 3.0;

input int    InpLondonStartHour          = 8;
input int    InpLondonEndHour            = 17;
input int    InpNYStartHour              = 13;
input int    InpNYEndHour                = 22;

input int    InpSwingRange               = 2;
input int    InpSwingLookback            = 50;
input int    InpTriggerSwingLookback     = 30;

input int    InpFVGMaxAliveMin           = 4320;
input int    InpFVGScanBars               = 50;
input double InpFVGMinBodyPct            = 60.0;
input int    InpMSSMinDepthPts           = 30;

input long   InpMagicNumber              = 20250308;
input int    InpSlippage                 = 5;

input bool   InpDebugLog                 = true;
input bool   InpDebugDraw                = true;

#endif
