//+------------------------------------------------------------------+
//| ICT EA – FVG Edition  (MQL5)  v4.3                               |
//| Architecture : MiddleTF(H1) + TriggerTF(M5)                     |
//| State Machine: IDLE → WAIT_TOUCH → WAIT_TRIGGER → IN_TRADE      |
//|                                                                  |
//| Flow tổng thể:                                                   |
//|   1. H1 trend xác định hướng, tìm FVG thuận xu hướng            |
//|   2. Giá touch H1 FVG → chờ M5 MSS xác nhận                    |
//|   3. M5 MSS = swing break thuận chiều H1:                       |
//|      - H1 UP  → close > tH0 (phá swing high) = bull MSS        |
//|      - H1 DOWN → close < tL0 (phá swing low)  = bear MSS       |
//|   4. Entry = limit tại swing level vừa bị phá (tH0 hoặc tL0)   |
//|   5. SL = swing đối diện (tL0 cho buy, tH0 cho sell)           |
//|   6. TP = Entry ± 2R                                            |
//+------------------------------------------------------------------+
#property copyright "Bell's ICT EA"
#property version   "4.30"

#define MAX_FVG_POOL 30

#include "EA_ICT_CL/Config.mqh"
#include "EA_ICT_CL/State.mqh"

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

EAState          g_State       = EA_IDLE;
BlockReason      g_BlockReason = BLOCK_NONE;

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

const string PREFIX_SWING_MIDDLE   = "SwingMiddle_";
const string PREFIX_SWING_TRIGGER  = "SwingTrigger_";
const string PREFIX_MSS_MARKER     = "MSSMarker_";
const string PREFIX_FVG_POOL       = "FVGPool_";
const string PREFIX_ORDER_VISUAL   = "OrderVisual_";
const string PREFIX_DEBUG_PANEL    = "DebugPanel_";
const string PREFIX_SESSION        = "Session_";

#include "EA_ICT_CL/Contexts.mqh"
#include "EA_ICT_CL/Guards.mqh"
#include "EA_ICT_CL/Signals_BOS_FVG_OB.mqh"
#include "EA_ICT_CL/Trade.mqh"
#include "EA_ICT_CL/StateMachine.mqh"
#include "EA_ICT_CL/Drawing.mqh"

/** Initializes globals, contexts, FVG pool and first draw. */
int OnInit()
{
  ZeroMemory(g_MiddleTrend); ZeroMemory(g_TriggerTrend);
  ZeroMemory(g_DailyRisk); ZeroMemory(g_OrderPlan);
  for (int i = 0; i < MAX_FVG_POOL; i++) ZeroMemory(g_FVGPool[i]);
  g_FVGCount = 0; g_NextFVGId = 0;
  g_ActiveFVGIdx = -1; g_TradeBarIndex = -1; g_PendingTicket = 0;
  g_State = EA_IDLE; g_BlockReason = BLOCK_NONE;

  UpdateAllContexts();
  ScanAndRegisterFVGs();
  DrawVisuals();

  PrintFormat("✅ ICT EA v4.3 | H1=%s | M5=%s | Pool=%d",
    EnumToString(g_MiddleTrend.trend),
    EnumToString(g_TriggerTrend.trend), g_FVGCount);
  return INIT_SUCCEEDED;
}

/** Each tick: update contexts, run guards and state machine, optionally redraw. */
void OnTick()
{
  UpdateAllContexts();
  if (EvaluateGuards())
    RunStateMachine();
  else if (g_State != EA_IDLE)
    ResetToIdle(EnumToString(g_BlockReason));
  if (InpDebugDraw) DrawVisuals();
}

/** Removes swing, session, debug panel objects and redraws chart. */
void OnDeinit(const int reason)
{
  ObjectsDeleteAll(0, PREFIX_SWING_MIDDLE);
  ObjectsDeleteAll(0, PREFIX_SWING_TRIGGER);
  ObjectsDeleteAll(0, PREFIX_SESSION);
  ObjectsDeleteAll(0, PREFIX_DEBUG_PANEL);
  ChartRedraw(0);
  PrintFormat("ICT EA v4.3 deinit | reason=%d | pool=%d", reason, g_FVGCount);
}
