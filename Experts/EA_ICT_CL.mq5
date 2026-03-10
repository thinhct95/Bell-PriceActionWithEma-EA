//+------------------------------------------------------------------+
//| ICT EA – FVG Edition  (MQL5)  v4.3                               |
//| Architecture : BiasTF(D1) + MiddleTF(H1) + TriggerTF(M5)       |
//| State Machine: IDLE → WAIT_TOUCH → WAIT_TRIGGER → IN_TRADE      |
//|                                                                  |
//| Flow tổng thể:                                                   |
//|   1. D1 bias (UP/DOWN) đồng thuận H1 trend                     |
//|   2. H1 FVG thuận xu hướng → chờ price retrace vào FVG          |
//|   3. Giá touch H1 FVG → chờ M5 MSS xác nhận đảo chiều          |
//|   4. M5 MSS = swing break thuận chiều H1:                       |
//|      - H1 UP  → close > tH0 (phá swing high) = bull MSS        |
//|      - H1 DOWN → close < tL0 (phá swing low)  = bear MSS       |
//|      v4.3: MSS chỉ detect khi WAIT_TRIGGER, không vẽ/detect khác |
//|   5. Entry = limit tại swing level vừa bị phá (tH0 hoặc tL0)   |
//|   6. SL = swing đối diện (tL0 cho buy, tH0 cho sell)           |
//|   7. TP = Entry ± 2R                                            |
//|                                                                  |
//| Drawing: objects KHÔNG BAO GIỜ bị xóa, chỉ update              |
//+------------------------------------------------------------------+
#property copyright "Bell's ICT EA"  // Bản quyền EA
#property version   "4.30"             // Phiên bản

#define MAX_FVG_POOL 30               // Số FVG tối đa trong pool

//====================================================
// LAYER 1 – Config + Types (no dependencies)
//====================================================
#include "EA_ICT_CL/Config.mqh"       // Inputs và cấu hình
#include "EA_ICT_CL/State.mqh"        // Enums, structs (EAState, BiasContext, FVGRecord...)

//====================================================
// LAYER 2 – Utility modules (depend on types + inputs)
//====================================================
#include "EA_ICT_CL/Utils.mqh"        // Clamp, RoundToStep, IsNewBar
#include "EA_ICT_CL/Logging.mqh"      // LogPrint, LogPrintF
#include "EA_ICT_CL/Market.mqh"       // GetBid, GetAsk, GetPoint, IsTradeAllowedNow
#include "EA_ICT_CL/Indicators.mqh"   // CopyBufferSafe, CopyTimeSafe
#include "EA_ICT_CL/Sessions.mqh"     // IsHourInRange, GetUTCHour
#include "EA_ICT_CL/Filters.mqh"      // Filter_MaxSpreadPoints
#include "EA_ICT_CL/Risk.mqh"         // NormalizeVolume, LotsFromRiskMoneyAndSLPoints
#include "EA_ICT_CL/Orders.mqh"       // NormalizePrice, BuildOrderComment
#include "EA_ICT_CL/Swing.mqh"        // MyBarShift, IsSwingHighAt, ScanSwingStructure, ResolveTrendFromSwings
#include "EA_ICT_CL/Trailing.mqh"     // Placeholder trailing/BE

//====================================================
// GLOBALS
//====================================================
EAState          g_State       = EA_IDLE;   // Trạng thái EA hiện tại
BlockReason      g_BlockReason = BLOCK_NONE; // Lý do chặn trade (session/daily loss/bias...)

BiasContext      g_Bias;              // D1 bias (UP/DOWN/SIDEWAY/NONE)
TFTrendContext   g_MiddleTrend;        // H1 swing + trend + MSS
TFTrendContext   g_TriggerTrend;       // M5 swing + trend
DailyRiskContext g_DailyRisk;          // Balance đầu ngày, limit hit

FVGRecord  g_FVGPool[MAX_FVG_POOL];    // Pool các FVG đã quét
int        g_FVGCount      = 0;       // Số FVG trong pool
int        g_NextFVGId     = 0;        // ID gán cho FVG mới
int        g_ActiveFVGIdx  = -1;      // Chỉ số FVG đang theo dõi (-1 = không có)
int        g_TradeBarIndex = -1;      // Bar index khi vào lệnh (dùng cho timeout...)

OrderPlan        g_OrderPlan;          // Kế hoạch lệnh (entry, SL, TP, lot)
ulong            g_PendingTicket = 0;  // Ticket lệnh pending đã gửi

const string PREFIX_SWING_MIDDLE   = "SwingMiddle_";   // Tiền tố object H1 swing
const string PREFIX_SWING_TRIGGER  = "SwingTrigger_";  // Tiền tố object M5 swing
const string PREFIX_MSS_MARKER     = "MSSMarker_";    // Tiền tố marker MSS
const string PREFIX_FVG_POOL       = "FVGPool_";      // Tiền tố hình FVG
const string PREFIX_ORDER_VISUAL   = "OrderVisual_";  // Tiền tố vùng Entry/SL/TP
const string PREFIX_DEBUG_PANEL    = "DebugPanel_";  // Tiền tố panel debug góc trái

//====================================================
// LAYER 3 – Logic modules (depend on globals)
//====================================================
#include "EA_ICT_CL/Contexts.mqh"     // UpdateBiasContext, UpdateTFTrendContext, UpdateAllContexts
#include "EA_ICT_CL/Guards.mqh"       // IsSessionAllowed, EvaluateGuards
#include "EA_ICT_CL/Signals_BOS_FVG_OB.mqh"  // ScanAndRegisterFVGs, UpdateFVGStatuses, GetBestActiveFVGIdx
#include "EA_ICT_CL/Trade.mqh"        // BuildOrderPlan, ExecuteLimitOrder
#include "EA_ICT_CL/StateMachine.mqh" // TransitionTo, RunStateMachine, OnStateIdle...
#include "EA_ICT_CL/Drawing.mqh"      // DrawVisuals, DrawFVGPool, DrawContextDebug...

//+------------------------------------------------------------------+
//|  EA LIFECYCLE                                                     |
//+------------------------------------------------------------------+

int OnInit()
{
  ZeroMemory(g_Bias); ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);  // Xóa context
  ZeroMemory(g_DailyRisk); ZeroMemory(g_OrderPlan);                            // Xóa risk + order plan
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);             // Xóa toàn bộ pool FVG
  g_FVGCount = 0; g_NextFVGId = 0;                                            // Reset đếm FVG
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1; g_PendingTicket = 0;              // Không FVG active, không pending
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;                               // State = IDLE, không block

  UpdateAllContexts();   // Cập nhật D1 bias, H1/M5 trend, daily risk
  ScanAndRegisterFVGs(); // Quét H1 và đăng ký FVG vào pool
  DrawVisuals();        // Vẽ swing, FVG, debug panel (nếu bật)

  PrintFormat("✅ ICT EA v4.3 | Bias=%s | H1=%s | M5=%s | Pool=%d",
    EnumToString(g_Bias.bias), EnumToString(g_MiddleTrend.trend),
    EnumToString(g_TriggerTrend.trend), g_FVGCount);
  return INIT_SUCCEEDED;  // Khởi tạo thành công
}

void OnTick()
{
  UpdateAllContexts();   // Mỗi tick: cập nhật bias, H1/M5 swing, daily risk, MSS (nếu WAIT_TRIGGER)
  if (EvaluateGuards())  // Kiểm tra session, daily loss, bias, alignment
    RunStateMachine();  // Chạy state machine (Idle/WaitTouch/WaitTrigger/InTrade)
  else if (g_State != EA_IDLE)
    ResetToIdle(EnumToString(g_BlockReason));  // Đang không IDLE mà fail guard → reset về IDLE
  if (InpDebugDraw) DrawVisuals();  // Vẽ lại nếu bật debug draw
}

void OnDeinit(const int reason)
{
  ObjectsDeleteAll(0, PREFIX_SWING_MIDDLE);   // Xóa toàn bộ object H1 swing
  ObjectsDeleteAll(0, PREFIX_SWING_TRIGGER);  // Xóa toàn bộ object M5 swing
  ObjectsDeleteAll(0, PREFIX_DEBUG_PANEL);    // Xóa panel debug (FVG/order objects giữ lại theo thiết kế)
  ChartRedraw(0);  // Vẽ lại chart
  PrintFormat("ICT EA v4.3 deinit | reason=%d | pool=%d", reason, g_FVGCount);  // Log thoát
}
