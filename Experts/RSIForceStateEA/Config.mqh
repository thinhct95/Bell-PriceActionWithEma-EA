#ifndef RSI_FORCE_STATE_EA__CONFIG_MQH
#define RSI_FORCE_STATE_EA__CONFIG_MQH

// ============================================================
// All EA inputs grouped by responsibility for clarity in MT5 UI
// ============================================================

input group "General"
input long            InpMagicNumber                 = 26050901;
input bool            InpDebugLog                    = true;

input group "Trend Filter (EMA200 on Close)"
input int             InpEMA200Period                = 200;
input bool            InpUseATRTrendBuffer           = false;     // false = % buffer, true = ATR buffer
input double          InpTrendBufferPercent          = 0.10;      // % EMA200 dead-zone (when ATR buffer off)
input double          InpTrendBufferATRMult          = 0.20;      // ATR multiplier for dead-zone (when ATR buffer on)
input bool            InpSkipFlatEMA200              = true;
input double          InpFlatEMA_ATRMult             = 0.05;      // EMA200 considered flat if |delta| < ATR*this

input group "ATR (used by trend buffer + SL)"
input int             InpATRPeriod                   = 14;

input group "Force Indicators (RSI + 2 MAs computed on RSI)"
input int             InpRSIPeriod                   = 14;
input int             InpRSI_EMA9Period              = 9;         // EMA tinh tren RSI
input int             InpRSI_WMA45Period             = 45;        // WMA tinh tren RSI
input int             InpSlopeLookbackBars           = 3;         // bars de check slope dong nhat
input int             InpMinBarsBetweenCrosses       = 10;        // toi thieu N bar khong cross truoc khi nhan tin hieu

input group "Sideway / No-Trade Filters"
input bool            InpUseRSISidewayFilter         = true;
input int             InpSidewayLookbackBars         = 8;
input double          InpSidewayRSILow               = 45.0;
input double          InpSidewayRSIHigh              = 55.0;

input group "Entry & Pending Order"
input int             InpSignalBarShift              = 1;         // 1 = nen vua dong (khuyen nghi)
input int             InpPendingMaxAliveBars         = 5;         // huy pending sau N bar khong khop
input int             InpWatchingMaxBars             = 10;        // huy WATCHING neu khong co trigger sau N bar
input bool            InpInvalidateIfCrossBack       = true;      // huy pending khi RSI cross nguoc lai

input group "Stop Loss"
enum ENUM_SL_MODE
{
  SL_SWING  = 0, // theo swing extreme gan nhat
  SL_ATR    = 1, // theo ATR
  SL_HYBRID = 2  // chon SL rong hon giua swing va ATR
};
input ENUM_SL_MODE    InpStopLossMode                = SL_HYBRID;
input int             InpSwingLookbackBars           = 20;
input double          InpSL_ATRMult                  = 1.2;
input int             InpSL_SwingBufferPoints        = 20;        // them buffer ngoai swing extreme

input group "Risk & Trade Management"
input double          InpRiskPercent                 = 1.0;
input double          InpRiskRewardRatio             = 2.0;       // TP = entry +/- R*RR
input double          InpPartialCloseAtR             = 1.5;       // dong 1 phan khi dat R nay
input double          InpPartialClosePercent         = 50.0;      // phan tram dong khi dat partial R

input group "Visualization"
input bool            InpVisualize                   = true;      // bat tat toan bo overlay
input bool            InpAttachIndicators            = true;      // tu add EMA200 vao chart + RSI/EMA9/WMA45 vao subwindow
input bool            InpShowDashboard               = true;      // panel goc tren-trai
input bool            InpShowStatsPanel              = true;      // panel goc duoi-trai
input bool            InpShowTradeLevels             = true;      // ve Entry/SL/TP TradingView style
input int             InpStatsLookbackDays           = 60;        // chi quet history N ngay gan nhat cho stats
input color           InpColorTrendUp                = clrLime;
input color           InpColorTrendDown              = clrTomato;
input color           InpColorTrendNone              = clrSilver;
input color           InpColorEntry                  = clrDodgerBlue;
input color           InpColorSL                     = clrTomato;
input color           InpColorTP                     = clrLime;

#endif
