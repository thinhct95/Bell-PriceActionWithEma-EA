//+------------------------------------------------------------------+
//| Config.mqh — ICT 2026 inputs                                     |
//+------------------------------------------------------------------+
#ifndef ICT2026_CONFIG_MQH
#define ICT2026_CONFIG_MQH

#include <ICT2026/Types.mqh>

input group "══ Daily Bias ══"
input ENUM_TIMEFRAMES InpBiasTf           = PERIOD_D1;   // TF xác định Daily Bias
input int             InpSwingRange       = 2;           // Pivot: nến mỗi bên
input int             InpSwingLookback    = 300;         // Quét swing lịch sử
input double          InpFibMinRatio      = 0.382;       // Fib tối thiểu (0 = tắt)
input bool            InpRequireFib       = false;       // Bắt buộc Fib OK cho structural

input group "══ Intraday Structure ══"
input ENUM_TIMEFRAMES InpIntradayTf           = PERIOD_H1;   // TF intraday (mặc định H1)
input int             InpIntradaySwingRange   = 2;           // Pivot intraday
input int             InpIntradaySwingLookback = 120;        // Lookback quét pivot H1
input int             InpIntradayRecentBars    = 80;         // Chỉ dùng pivot trong N bar gần nhất

input group "══ Hiển thị ══"
input bool            InpDrawPanel        = true;      // Panel bias góc trên trái
input int             InpPanelX           = 12;
input int             InpPanelY           = 28;
input int             InpPanelFontSize    = 10;
input int             InpPanelLineSpacing = 22;      // Khoảng cách mỗi dòng (pixel)

input group "══ Vẽ trên chart ══"
input bool            InpDrawChartLabels      = true;    // Bật vẽ label swing trên chart
input bool            InpDrawBiasSwingLabels  = true;    // bH0–bL1 (theo TF chart)
input bool            InpDrawIntraSwingLabels = true;    // iH0–iL1 (theo TF chart)
input bool            InpDrawConfirmLabels    = true;    // H0–L1 confirm (theo TF chart)
input int             InpChartLabelFontSize   = 9;

input group "══ Confirm swing (M5) ══"
input ENUM_TIMEFRAMES InpConfirmTf            = PERIOD_M5;  // TF confirmation (tương lai)
input int             InpConfirmSwingRange    = 2;
input int             InpConfirmSwingLookback = 80;
input int             InpConfirmRecentBars    = 40;

input group "══ Low TF / iTF FVG ══"
input ENUM_TIMEFRAMES InpLowTf                = PERIOD_M5;   // Low TF trend (tương lai)
input ENUM_TIMEFRAMES InpFvgTf                = PERIOD_H1;   // Quét FVG (mặc định = Intraday)
input int             InpFvgLookbackBars      = 60;          // Bar quét FVG (full / khi Allow bật)
input int             InpFvgScanBarsPerUpdate = 40;          // Mỗi nến mới: quét lại N bar gần nhất
input int             InpFvgAtrPeriod         = 14;          // ATR cho lọc kích thước gap
input double          InpFvgMinGapATRPct      = 12.0;        // Gap tối thiểu (% ATR, 0=tắt)
input double          InpFvgMinGapPoints      = 0.0;         // Gap tối thiểu (giá, 0=chỉ ATR)
input double          InpFvgMinGapVsBarPct    = 25.0;        // Gap >= % range nến giữa B (0=tắt)
input double          InpFvgUsedFillPct       = 38.2;        // % lấp FVG → Used
input int             InpFvgExpireDays        = 3;           // Xóa Available sau N ngày
input int             InpFvgMaxZones          = 24;          // Số FVG tối đa trên chart
input bool            InpDrawFvgZones         = true;        // Vẽ FVG + Premium/Discount
input color           InpFvgBullColor         = clrLimeGreen;   // Bull FVG
input color           InpFvgBearColor         = clrRed;         // Bear FVG
input color           InpFvgUsedColor         = clrDimGray;     // Used FVG
input color           InpPdPremiumColor       = clrMaroon;
input color           InpPdDiscountColor      = clrDarkGreen;

input group "══ MSS / Entry (Confirm TF) ══"
input double          InpMssH1MinFillPct      = 38.2;        // Retest FVG H1 (POI): % lấp tối thiểu trên H1
input double          InpMssEntryFillPct      = 38.2;        // M5 FVG: % lấp để sẵn sàng entry
input int             InpMssConfirmLookback   = 80;          // Lookback pivot CHoCH trên Confirm TF
input int             InpMssConfirmFvgBars    = 40;          // Quét M5 FVG sau CHoCH
input double          InpMssMaxDistGapPct    = 75.0;       // MSS: buffer quanh H1 FVG (% chiều cao gap)
input double          InpMssMaxDistAtrMult    = 1.25;        // MSS: thêm buffer (× ATR H1)
input double          InpMssExtraBelowGapPct  = 100.0;      // Bear: thêm % gap dưới lower (MSS dưới FVG)
input double          InpMssExtraAboveGapPct  = 100.0;      // Bull: thêm % gap trên upper
input int             InpMssMaxM5BarsAfterTouch = 0;        // MSS: max M5 bar sau chạm H1 (0=không giới hạn)
input bool            InpDrawConfirmFvg       = true;        // Vẽ FVG Confirm TF (màu nhạt)
input bool            InpDrawMssChoch         = true;        // Vẽ MSS sau H1 chạm FVG (CHoCH/H0)
input bool            InpMssLogJournal          = true;        // Log lý do chặn vào Experts journal

input group "══ MSS Trade ══"
input bool            InpMssTradeEnabled      = true;        // Đặt lệnh limit MSS
input ulong           InpMssMagic             = 202604;      // Magic number
input double          InpMssRiskPct           = 1.0;         // R % balance mỗi lệnh
input double          InpMssSlAtrMult           = 0.5;         // SL: buffer ngoài H0/L0 M5 (× ATR M5)
input double          InpMssMinRR              = 2.0;         // TP tối thiểu (× risk entry→SL)
input int             InpMssPendingExpireHours  = 24;         // Hết hạn pending (giờ, 0=không)
input bool            InpMssOnePosition         = true;        // Một position/pending MSS

input group "══ Debug ══"
input bool            InpDebug            = true;

#endif
