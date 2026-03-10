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
#property copyright "Bell's ICT EA"
#property version   "4.30"

#define MAX_FVG_POOL 30

//====================================================
// LAYER 1 – Config + Types (no dependencies)
//====================================================
#include "EA_ICT_CL/Config.mqh"
#include "EA_ICT_CL/State.mqh"

//====================================================
// LAYER 2 – Utility modules (depend on types + inputs)
//====================================================
#include "EA_ICT_CL/Utils.mqh"
#include "EA_ICT_CL/Logging.mqh"
#include "EA_ICT_CL/Market.mqh"
#include "EA_ICT_CL/Indicators.mqh"
#include "EA_ICT_CL/Sessions.mqh"
#include "EA_ICT_CL/Filters.mqh"
#include "EA_ICT_CL/Risk.mqh"
#include "EA_ICT_CL/Orders.mqh"
#include "EA_ICT_CL/Swing.mqh"
#include "EA_ICT_CL/Trailing.mqh"

//====================================================
// GLOBALS
//====================================================
EAState          g_State       = EA_IDLE;
BlockReason      g_BlockReason = BLOCK_NONE;

BiasContext      g_Bias;
TFTrendContext   g_MiddleTrend;
TFTrendContext   g_TriggerTrend;
DailyRiskContext g_DailyRisk;

FVGRecord  g_FVGPool[MAX_FVG_POOL];
int        g_FVGCount      = 0;
int        g_NextFVGId     = 0;
int        g_ActiveFVGIdx  = -1;
int        g_TradeBarIndex = -1;

OrderPlan        g_OrderPlan;
ulong            g_PendingTicket = 0;

const string PREFIX_SWING_MIDDLE   = "SwingMiddle_";   // H1 swing arrows/labels
const string PREFIX_SWING_TRIGGER  = "SwingTrigger_";  // M5 swing arrows/labels
const string PREFIX_MSS_MARKER     = "MSSMarker_";    // MSS break markers
const string PREFIX_FVG_POOL       = "FVGPool_";      // FVG rectangles
const string PREFIX_ORDER_VISUAL   = "OrderVisual_";  // Entry/SL/TP visualization
const string PREFIX_DEBUG_PANEL    = "DebugPanel_";   // Top-left info labels

//====================================================
// LAYER 3 – Logic modules (depend on globals)
//====================================================
#include "EA_ICT_CL/Contexts.mqh"
#include "EA_ICT_CL/Guards.mqh"
#include "EA_ICT_CL/Signals_BOS_FVG_OB.mqh"
#include "EA_ICT_CL/Trade.mqh"
#include "EA_ICT_CL/StateMachine.mqh"
#include "EA_ICT_CL/Drawing.mqh"

//+------------------------------------------------------------------+
//|  EA LIFECYCLE                                                     |
//+------------------------------------------------------------------+

int OnInit()
{
  ZeroMemory(g_Bias); ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);
  ZeroMemory(g_DailyRisk); ZeroMemory(g_OrderPlan);
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);
  g_FVGCount = 0; g_NextFVGId = 0;
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1; g_PendingTicket = 0;
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;

  UpdateAllContexts();
  ScanAndRegisterFVGs();
  DrawVisuals();

  PrintFormat("✅ ICT EA v4.3 | Bias=%s | H1=%s | M5=%s | Pool=%d",
    EnumToString(g_Bias.bias), EnumToString(g_MiddleTrend.trend),
    EnumToString(g_TriggerTrend.trend), g_FVGCount);
  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts();
  if (EvaluateGuards())
    RunStateMachine();
  else if (g_State != EA_IDLE)
    ResetToIdle(EnumToString(g_BlockReason));
  if (InpDebugDraw) DrawVisuals();
}

void OnDeinit(const int reason)
{
  ObjectsDeleteAll(0, PREFIX_SWING_MIDDLE);
  ObjectsDeleteAll(0, PREFIX_SWING_TRIGGER);
  ObjectsDeleteAll(0, PREFIX_DEBUG_PANEL);
  ChartRedraw(0);
  PrintFormat("ICT EA v4.3 deinit | reason=%d | pool=%d", reason, g_FVGCount);
}
