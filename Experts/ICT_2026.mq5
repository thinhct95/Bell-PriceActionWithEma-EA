//+------------------------------------------------------------------+
//| ICT_2026.mq5 — Daily Bias + Intraday Structure (H1)              |
//| BOS = Continue | CHoCH = Reversal                                |
//+------------------------------------------------------------------+
#property copyright "ICT 2026"
#property version   "1.130"
#property description "ICT2026 MSS limit entry + SL swing CHoCH + TP intraday"

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

   if(biasOk || intraOk)
   {
      PrintFormat("[ICT2026] Init — Bias=%s | Intraday=%s | Allow=%s | FVG=%d",
                  IctBiasDisplayShort(g_ictDailyBias.bias),
                  IctTrendDisplayShort(g_ictIntraday.trend),
                  g_ictIntraday.isAllowTrade ? "true" : "false",
                  g_ictLowTf.availableCount);
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
ENUM_ICT_BIAS ICT2026_GetDailyBias() { return g_ictDailyBias.bias; }

ENUM_ICT_TREND ICT2026_GetIntradayTrend() { return g_ictIntraday.trend; }

bool ICT2026_IsAllowTrade() { return g_ictIntraday.isAllowTrade; }

int ICT2026_GetFvgAvailableCount() { return g_ictLowTf.availableCount; }

ENUM_ICT_MSS_PHASE ICT2026_GetMssPhase() { return g_ictLowTf.mss.phase; }

string ICT2026_GetMssReason() { return g_ictLowTf.mss.displayReason; }

//+------------------------------------------------------------------+
