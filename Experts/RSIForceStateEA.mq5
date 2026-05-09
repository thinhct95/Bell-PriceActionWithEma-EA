//+------------------------------------------------------------------+
//| RSIForceStateEA - pullback by RSI/EMA9/WMA45 force, EMA200 trend |
//| State machine: NO_TRADE -> WATCHING -> PENDING_ORDER -> IN_TRADE |
//+------------------------------------------------------------------+
#property copyright "RSI Force State EA"
#property version   "1.30"
#property strict

// ---- Layer 1: inputs + value types + indicator buffers/handles ----
#include "RSIForceStateEA/Config.mqh"
#include "RSIForceStateEA/State.mqh"
#include "RSIForceStateEA/Indicators.mqh"

// ---- Globals consumed by Layer 2/3 modules ----
EAState        g_State = STATE_NO_TRADE;
PendingContext g_Pending;
TradeContext   g_OpenTrade;

// ---- Layer 2: trade ops + state machine (depend on globals above) ----
#include "RSIForceStateEA/Trade.mqh"
#include "RSIForceStateEA/StateMachine.mqh"

// ---- Layer 3: visualization (depends on globals + state machine) ----
#include "RSIForceStateEA/Visualizer.mqh"

// Throttle stats panel refresh (deal history scan can be heavy).
datetime g_LastVisualRefresh = 0;
const int kVisualRefreshSeconds = 2;

// ------------------------------------------------------------------
// Input validation (fail fast on misconfiguration)
// ------------------------------------------------------------------

bool ValidateInputs()
{
  if (InpRiskPercent <= 0.0 || InpRiskPercent > 50.0)
  { Print("[INIT] InpRiskPercent must be in (0, 50]"); return false; }

  if (InpRiskRewardRatio <= 0.0)
  { Print("[INIT] InpRiskRewardRatio must be > 0"); return false; }

  if (InpPartialCloseAtR <= 0.0 || InpPartialCloseAtR >= InpRiskRewardRatio)
  { Print("[INIT] InpPartialCloseAtR must be in (0, InpRiskRewardRatio)"); return false; }

  if (InpPartialClosePercent <= 0.0 || InpPartialClosePercent >= 100.0)
  { Print("[INIT] InpPartialClosePercent must be in (0, 100)"); return false; }

  if (InpPendingMaxAliveBars < 1)
  { Print("[INIT] InpPendingMaxAliveBars must be >= 1"); return false; }

  if (InpWatchingMaxBars < 1)
  { Print("[INIT] InpWatchingMaxBars must be >= 1"); return false; }

  if (InpSlopeLookbackBars < 2)
  { Print("[INIT] InpSlopeLookbackBars must be >= 2"); return false; }

  if (InpMinBarsBetweenCrosses < 1)
  { Print("[INIT] InpMinBarsBetweenCrosses must be >= 1"); return false; }

  if (InpSwingLookbackBars < 5)
  { Print("[INIT] InpSwingLookbackBars must be >= 5"); return false; }

  if (InpSidewayRSILow >= InpSidewayRSIHigh)
  { Print("[INIT] InpSidewayRSILow must be < InpSidewayRSIHigh"); return false; }

  if (InpRSI_EMA9Period >= InpRSI_WMA45Period)
  { Print("[INIT] InpRSI_EMA9Period must be < InpRSI_WMA45Period"); return false; }

  if (InpSignalBarShift < 1)
  { Print("[INIT] InpSignalBarShift must be >= 1 (use closed bars)"); return false; }

  return true;
}

// ------------------------------------------------------------------
// Lifecycle
// ------------------------------------------------------------------

int OnInit()
{
  if (!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;

  ZeroMemory(g_Pending);
  ZeroMemory(g_OpenTrade);
  g_State                 = STATE_NO_TRADE;
  g_HasTradedThisPullback = false;
  g_BarsInWatching        = 0;
  g_LastTrend             = TREND_NONE;
  g_LastDirTrend          = TREND_NONE;
  g_LastVisualRefresh     = 0;

  if (!InitIndicators())
  {
    Print("[INIT] InitIndicators failed");
    return INIT_FAILED;
  }
  if (!RefreshIndicatorData())
  {
    Print("[INIT] RefreshIndicatorData failed (need more history)");
    return INIT_FAILED;
  }

  InitTradeOps();

  // Seed both trend trackers to current value so we don't fire a false
  // "direction flip" event on the first tick.
  g_LastTrend = DetectTrend(InpSignalBarShift);
  if (g_LastTrend != TREND_NONE) g_LastDirTrend = g_LastTrend;

  PrintFormat("[INIT] RSIForceStateEA v1.30 ready | Symbol=%s | TF=%d | startTrend=%s",
              _Symbol, (int)_Period, EnumToString(g_LastTrend));

  AttachIndicatorsToChart();
  DrawAllVisuals(g_LastTrend);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  RemoveAllVisuals();
  ReleaseIndicators();
  PrintFormat("[DEINIT] reason=%d", reason);
}

// ------------------------------------------------------------------
// Tick loop:
//   - tick-level: refresh data, sync broker state, manage open trade
//   - bar-level:  evaluate state machine on every newly closed bar
//   - visuals:    refresh dashboard/levels (throttled)
// ------------------------------------------------------------------
void OnTick()
{
  if (!RefreshIndicatorData()) return;

  SyncStateWithBroker();

  if (g_State == STATE_IN_TRADE)
    ManagePartialAndBreakEven(g_OpenTrade);

  const bool newBar = IsNewBar();
  if (newBar) RunStateMachine();

  // Throttle the dashboard refresh to avoid excessive history queries.
  const datetime now = TimeCurrent();
  if (newBar || (now - g_LastVisualRefresh) >= kVisualRefreshSeconds)
  {
    g_LastVisualRefresh = now;
    DrawAllVisuals(DetectTrend(InpSignalBarShift));
  }
}

// Trade events can change order/position state between ticks; just resync.
// Visuals will refresh on the next tick (throttled by kVisualRefreshSeconds).
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
  SyncStateWithBroker();
}
