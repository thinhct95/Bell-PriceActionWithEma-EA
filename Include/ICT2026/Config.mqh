//+------------------------------------------------------------------+
//| Config.mqh — ICT 2026 input parameters (single source of truth)  |
//+------------------------------------------------------------------+
//| Tất cả `input` của EA gom vào file này, chia thành 8 groups:     |
//|   1) Daily Bias        — TF, swing range, fib                    |
//|   2) Intraday Structure — TF (default H1), pivot, recent bars    |
//|   3) Test mode         — InpOnlyStatsMode (skip render cho tester)|
//|   4) Display panel     — panel font, position                    |
//|   5) Chart draw        — bias/intra/confirm swing labels         |
//|   6) Confirm swing (M5)— InpConfirmTf (M5), swing range, lookback|
//|   7) Low TF / FVG      — InpFvgTf (H1), ATR period, gap filters, |
//|                            PD toggle / overlap %, large bypass,   |
//|                            tiered touch (Pure/Mixed),             |
//|                            draw top-N + price-near (v1.180)      |
//|   8) MSS / Trade       — risk %, SL/TP spread mults, min RR,     |
//|                            partial close, BE@N×R, pending timeout,|
//|                            require intraday aligned (v1.181),    |
//|                            max limit distance (v1.184),          |
//|                            one-position, EOD cancel              |
//|                                                                   |
//| Lưu ý: KHÔNG đặt logic ở đây; chỉ khai báo `input`. Default values|
//| phải tương đương "production safe" — user mới chỉ cần tắt/bật là  |
//| chạy ổn.                                                          |
//|                                                                   |
//| Khi thêm input mới: cập nhật README mục [Input](#inputs) +       |
//| changelog v1.x trong cùng commit.                                 |
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

input group "══ Test mode ══"
input bool            InpOnlyStatsMode    = false;     // true = skip toàn bộ render/draw + journal verbose (chạy tester nhanh, chỉ in stats cuối)

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
input int             InpConfirmSwingRange    = 2;          // M5 swing strength: N bar mỗi bên (5-bar fractal khi =2)
input int             InpConfirmSwingLookback = 80;
input int             InpBodyBreakSpreadMult  = 10;         // Body break: thân nến đóng vượt level ≥ N × spread (siết chặt BOS/CHoCH, MSS confirm, H1 invalidate)
input int             InpConfirmRecentBars    = 40;

input group "══ Low TF / iTF FVG ══"
input ENUM_TIMEFRAMES InpLowTf                = PERIOD_M5;   // Low TF trend (tương lai)
input ENUM_TIMEFRAMES InpFvgTf                = PERIOD_H1;   // Quét FVG (mặc định = Intraday)
input int             InpFvgLookbackBars      = 60;          // Bar quét FVG (full / khi Allow bật)
input int             InpFvgScanBarsPerUpdate = 40;          // Mỗi nến mới: quét lại N bar gần nhất
input int             InpFvgAtrPeriod         = 14;          // ATR cho lọc kích thước gap
input double          InpFvgMinGapATRPct      = 12.0;        // H1 only: gap tối thiểu (% ATR, 0=tắt)
input double          InpFvgMinGapPoints      = 0.0;         // H1 only: gap tối thiểu (giá)
input double          InpFvgMinGapVsBarPct    = 25.0;        // H1 only: gap >= % range nến B (0=tắt)
input double          InpFvgUsedFillPct       = 25.0;        // % lấp FVG → Used
input bool            InpFvgPdEnabled         = true;        // Bật/tắt điều kiện Premium/Discount toàn cục (false = chấp nhận FVG bất kể vùng)
input double          InpFvgPdMinOverlapPct   = 0.0;         // POI filter: % chiều cao FVG nằm trong Premium/Discount (0=chấp nhận bất kỳ overlap > 0)
input double          InpFvgTouchFillPure     = 25.0;        // Touch threshold khi FVG nằm hẳn trong vùng PD đúng chiều (bear→Premium, bull→Discount)
input double          InpFvgTouchFillMixed    = 50.0;        // Touch threshold khi FVG straddle equilibrium (overlap cả Premium & Discount)
input int             InpFvgExpireDays        = 3;           // Xóa Available sau N ngày
input int             InpFvgMaxZones          = 24;          // Số FVG tối đa trên chart
input bool            InpDrawFvgZones         = true;        // Vẽ FVG + Premium/Discount
input color           InpFvgBullColor         = clrLimeGreen;   // Bull FVG
input color           InpFvgBearColor         = clrRed;         // Bear FVG
input color           InpFvgUsedColor         = clrDimGray;     // Used FVG
input color           InpPdPremiumColor       = clrMaroon;
input color           InpPdDiscountColor      = clrDarkGreen;
input int             InpDrawMaxRecentPerState = 3;            // FVG/PD: vẽ tối đa N gần nhất cho mỗi state (Used / Available)
input double          InpDrawNearAtrMult       = 2.0;          // FVG khác chỉ vẽ khi giá cách ≤ N × ATR(FvgTf) (0=không vẽ "near", >0=vẽ thêm)

input group "══ MSS / Entry (Confirm TF) ══"
input bool            InpMssH1RetestWickOnly   = true;        // (legacy, bỏ qua) Retest = giá chạm FVG
input double          InpMssH1MinFillPct      = 25.0;        // Vẽ mức % tham khảo trên chart (không chặn retest)
input double          InpMssEntryFillPct      = 25.0;        // M5 FVG: % lấp để sẵn sàng entry
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
input int             InpMssSlSpreadMult        = 8;           // SL buffer = N × spread (cộng ra ngoài max(H0,H1)/min(L0,L1))
input int             InpMssTpSpreadMult        = 16;          // TP buffer = N × spread (chốt trước iL0/iH0 để dễ khớp)
input double          InpMssMinRR              = 2.0;         // Ngưỡng RR: nếu TP@iL0/iH0 < ngưỡng → dùng TP cố định = entry ± risk × InpMssMinRR (= 2R), ngược lại TP tại iL0/iH0
input double          InpMssPartialClosePct    = 50.0;        // % volume chốt khi giá đạt swing iL0/iH0 (TP gồng xa hơn) — sau đó dời SL về BE (0=tắt)
input bool            InpMssBeEnabled           = false;       // Bật/tắt dời SL về entry khi giá đi được N×R (mặc định tắt)
input double          InpMssBeAtRR              = 2.0;         // Ngưỡng N×R để kích hoạt dời BE (chỉ áp dụng khi InpMssBeEnabled=true)
input int             InpMssPendingExpireHours  = 1;          // Hết hạn pending limit (giờ): hủy + reset → WAIT_FVG_TOUCH (0=không timeout)
input double          InpMssMaxLimitDistAtrMult = 3.0;        // Cap khoảng cách limit-giá theo bội số ATR(FvgTf). >cap ⇒ không đặt / cancel limit hiện có (tránh limit chết). 0 = tắt
input bool            InpMssCancelStaleLimit    = true;       // Cancel pending + reset state khi giá rời xa entry vượt cap (mark FVG used để chọn POI khác)
input bool            InpMssCancelLimitWhenTpReached = true;  // Nếu giá chạm TP TRƯỚC khi limit khớp ⇒ cancel limit + reset (không đợi hồi nữa)
input bool            InpMssRequireIntradayAligned = false;    // Bắt buộc Intraday cùng chiều Bias mới entry? false=cho phép entry dù Intraday ngược/None (tránh miss setup khi trend chuyển muộn)
input bool            InpMssOnePosition         = true;        // Một position/pending MSS
input bool            InpMssCancelPendingEod    = true;        // Hủy pending cuối phiên Mỹ (nếu chưa khớp)
input int             InpMssEodHour             = 23;          // Giờ EOD theo SERVER time (24h, vd EET broker = 23h ≈ 16:00 ET DST)
input int             InpMssEodMinute           = 0;           // Phút EOD

input group "══ Debug ══"
input bool            InpDebug            = true;

#endif
