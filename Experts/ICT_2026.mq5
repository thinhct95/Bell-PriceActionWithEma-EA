//+------------------------------------------------------------------+
//| ICT_2026.mq5 — Root EA (orchestrator only, no business logic)    |
//+------------------------------------------------------------------+
//| Layer pipeline (đọc từ trên xuống = TF cao xuống thấp):           |
//|   D1   → DailyBias       — bias hôm nay (BULL/BEAR/RANGE/NONE)    |
//|   H1   → IntradayStructure — H1 trend + IsAllowTrade              |
//|   H1   → LowTfTrend      — orchestrator FVG + MSS pipeline        |
//|           ├── Fvg          — detect/state/PD                      |
//|           ├── ConfirmFvg   — M5 FVG pool                          |
//|           ├── MssSetup     — phase machine + keylv lock           |
//|           └── MssEntry     — order + partial + BE + timeout       |
//|   UI   → Panel / Draw / FvgDraw / MssDraw + Stats                 |
//|                                                                   |
//| Trigger:                                                          |
//|   OnInit              — init từng module, gọi Update force=true   |
//|   OnTick              — orchestrator (xem README ▸ "Current      |
//|                          architecture A.")                        |
//|   OnTradeTransaction  — filter DEAL_ENTRY_OUT magic → call        |
//|                          IctMss_OnPositionClosed (reset state)    |
//|   OnDeinit            — clean up objects                          |
//|                                                                   |
//| Quy ước: file này KHÔNG được chứa business logic. Mọi rule đi vào|
//| module tương ứng.                                                 |
//+------------------------------------------------------------------+
#property copyright "ICT 2026"
#property version   "1.187"
#property description "ICT2026 MSS | strict body-break, PD-for-all-FVG, bias-aware touch, stale-limit cap"

#include <ICT2026/Config.mqh>
#include <ICT2026/DailyBias.mqh>
#include <ICT2026/IntradayStructure.mqh>
#include <ICT2026/LowTfTrend.mqh>
#include <ICT2026/Panel.mqh>
#include <ICT2026/Draw.mqh>
#include <ICT2026/Stats.mqh>

//+------------------------------------------------------------------+
int OnInit()
{
   const bool biasOk = IctDailyBias_Init(_Symbol);
   const bool intraOk = IctIntraday_Init(_Symbol);
   const bool lowOk = IctLowTfTrend_Init(_Symbol);

   if(!biasOk)
      Print("[ICT2026] Daily Bias: chưa đủ dữ liệu ", EnumToString(InpBiasTf));
   if(!intraOk)
      Print("[ICT2026] Intraday: chưa đủ dữ liệu ", EnumToString(InpIntradayTf));
   if(!lowOk)
      Print("[ICT2026] LowTF/FVG: chưa đủ dữ liệu ", EnumToString(InpFvgTf));

   IctMssStats_Recompute(_Symbol, InpMssMagic);

   if(InpOnlyStatsMode)
   {
      PrintFormat("[ICT2026] OnlyStatsMode = ON — skip render/draw, chỉ in stats khi deinit");
      return INIT_SUCCEEDED;
   }

   if(biasOk || intraOk)
   {
      IctEaState_Refresh(_Symbol);
      PrintFormat("[ICT2026] Init — EA=%s | Bias=%s | H1=%s | Allow=%s | FVG=%d | Stats=%d trades",
                  IctEaState_Code(IctEaState_Current()),
                  IctBiasDisplayShort(g_ictDailyBias.bias),
                  IctTrendDisplayShort(g_ictIntraday.trend),
                  g_ictIntraday.isAllowTrade ? "true" : "false",
                  g_ictLowTf.availableCount,
                  g_ictMssStats.total);
      IctPanel_Render(_Symbol);
      IctDraw_Render(_Symbol);
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IctMssStats_Recompute(_Symbol, InpMssMagic);
   PrintFormat("[ICT2026] === FINAL %s | %s ===",
               IctMssStats_LineCounts(), IctMssStats_LinePerf());

   if(InpOnlyStatsMode)
      return;

   IctPanel_Clear();
   IctDraw_Clear();
   IctFvgDraw_DeleteAll();
   IctMssDraw_DeleteAll();
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   static bool panelBoot = false;

   bool refresh = false;
   if(IctDailyBias_Update(_Symbol))
      refresh = true;
   if(IctIntraday_Update(_Symbol))
      refresh = true;
   if(IctLowTfTrend_Update(_Symbol))
      refresh = true;

   IctLowTfTrend_TickRefresh(_Symbol);

   if(InpOnlyStatsMode)
      return;

   if(refresh || !panelBoot)
   {
      IctPanel_Render(_Symbol);
      IctDraw_Render(_Symbol);
      panelBoot = true;
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(InpOnlyStatsMode)
      return;
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      IctPanel_Render(_Symbol);
      IctDraw_Render(_Symbol);
      IctFvgDraw_Render(_Symbol);
      IctMssDraw_Render(_Symbol);
   }
}

//+------------------------------------------------------------------+
//| Bắt close (SL/TP/manual) → mark M5 FVG Used + reset MSS pipeline |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   const ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMssMagic)
      return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   const long reason = HistoryDealGetInteger(deal, DEAL_REASON);
   const double net  = HistoryDealGetDouble(deal, DEAL_PROFIT)
                     + HistoryDealGetDouble(deal, DEAL_SWAP)
                     + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   IctMss_OnPositionClosed(_Symbol, reason, net);
   IctMssStats_Recompute(_Symbol, InpMssMagic);

   if(InpOnlyStatsMode)
   {
      PrintFormat("[ICT2026] %s | %s",
                  IctMssStats_LineCounts(), IctMssStats_LinePerf());
      return;
   }

   IctEaState_Refresh(_Symbol);
   IctPanel_Render(_Symbol);
   IctMssDraw_Render(_Symbol);
   IctFvgDraw_Render(_Symbol);
}

//+------------------------------------------------------------------+
ENUM_ICT_BIAS ICT2026_GetDailyBias() { return g_ictDailyBias.bias; }

ENUM_ICT_TREND ICT2026_GetIntradayTrend() { return g_ictIntraday.trend; }

bool ICT2026_IsAllowTrade() { return g_ictIntraday.isAllowTrade; }

int ICT2026_GetFvgAvailableCount() { return g_ictLowTf.availableCount; }

ENUM_ICT_MSS_PHASE ICT2026_GetMssPhase() { return g_ictLowTf.mss.phase; }

string ICT2026_GetMssReason() { return g_ictLowTf.mss.displayReason; }

ENUM_ICT_EA_STATE ICT2026_GetEaState() { return IctEaState_Current(); }

string ICT2026_GetEaStateCode() { return IctEaState_Code(IctEaState_Current()); }

string ICT2026_GetEaStateDetail() { return g_ictEaState.detail; }

//+------------------------------------------------------------------+
