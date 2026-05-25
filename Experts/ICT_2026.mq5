//+------------------------------------------------------------------+
//| ICT_2026.mq5 — Daily Bias + Intraday Structure (H1)              |
//| BOS = Continue | CHoCH = Reversal                                |
//+------------------------------------------------------------------+
#property copyright "ICT 2026"
#property version   "1.151"
#property description "ICT2026 MSS | SL = swing + ATR + spread | TP = iL0/iH0 + ATR − 2×spread (dễ khớp)"

#include <ICT2026/Config.mqh>
#include <ICT2026/DailyBias.mqh>
#include <ICT2026/IntradayStructure.mqh>
#include <ICT2026/LowTfTrend.mqh>
#include <ICT2026/Panel.mqh>
#include <ICT2026/Draw.mqh>

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

   if(refresh || !panelBoot)
   {
      IctPanel_Render(_Symbol);
      IctDraw_Render(_Symbol);
      panelBoot = true;
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
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
