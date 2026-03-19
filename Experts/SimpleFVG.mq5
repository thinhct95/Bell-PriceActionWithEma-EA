//+------------------------------------------------------------------+
//| SimpleFVG.mq5 – Fair Value Gap Visual Strategy (Test mode)         |
//|                                                                    |
//| Modules:                                                           |
//|   Config.mqh  → Step 0: Inputs, enums, constants                   |
//|   Trend.mqh   → Step 1: EMA34/EMA89 trend detection                |
//|   FVG.mqh     → Step 2: FVG scanning & management                  |
//|   Drawing.mqh → Step 4: Chart visualization                        |
//+------------------------------------------------------------------+
#property copyright "SimpleFVG"
#property version   "2.00"
#property description "FVG strategy visualizer – EMA trend + FVG zones on chart"

#include "SimpleFVG/Config.mqh"
#include "SimpleFVG/Trend.mqh"
#include "SimpleFVG/FVG.mqh"
#include "SimpleFVG/Trade.mqh"
#include "SimpleFVG/Drawing.mqh"

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Step 1: Initialize trend (EMA handles + chart indicators) ---
   if(!TrendInit())
      return INIT_FAILED;

   //--- Step 2: Initialize FVG array ---
   FVGInit();

   //--- Initial scan on existing bars ---
   TrendUpdate();
   FVGUpdate();

   //--- Step 4: Draw everything ---
   DrawAll();

   if(InpDebugLog)
      PrintFormat("[INIT] SimpleFVG v2.0 | %s %s | EMA%d/%d | FVG lookback=%d maxAge=%d",
                  GetTradeSymbol(), EnumToString(InpTimeframe),
                  InpEMAFastPeriod, InpEMASlowPeriod,
                  InpFVGLookbackBars, InpFVGMaxAgeBars);

    //--- Initialize last processed exit time so we don't reset based on old history.
    g_LastExitDealTime = GetLatestTP_SL_ExitDealTime();

   return INIT_SUCCEEDED;
}

//--- Track last processed TP/SL exit so we can reset strategy state
//--- only when a new SL/TP happens (not from older history).
datetime g_LastExitDealTime = 0;

datetime GetLatestTP_SL_ExitDealTime()
{
   datetime now = TimeCurrent();
   if(now == 0)
      return 0;
   if(!HistorySelect(0, now))
      return 0;

   datetime latest = 0;
   string symbol = GetTradeSymbol();

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      string dealSymbol = (string)HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long   dealMagic  = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(dealSymbol != symbol || dealMagic != InpEAMagic)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(reason != DEAL_REASON_TP && reason != DEAL_REASON_SL)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime > latest)
         latest = dealTime;
   }
   return latest;
}

//--- If a new TP/SL exit is detected since the last processed time,
//--- reset all FVG statuses by re-initializing the array and rescanning.
bool CheckAndResetOnNewTP_SL_Exit()
{
   datetime now = TimeCurrent();
   if(now == 0)
      return false;
   if(!HistorySelect(0, now))
      return false;

   datetime latestExit = g_LastExitDealTime;
   string symbol = GetTradeSymbol();

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      string dealSymbol = (string)HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long   dealMagic  = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(dealSymbol != symbol || dealMagic != InpEAMagic)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(reason != DEAL_REASON_TP && reason != DEAL_REASON_SL)
         continue;

      datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dealTime > g_LastExitDealTime && dealTime > latestExit)
         latestExit = dealTime;
   }

   if(latestExit <= g_LastExitDealTime)
      return false;

   //--- Only reset strategy state when our position is fully closed.
   //--- This avoids resetting on partial TP/SL deals while position still exists.
   if(CountOurPositions() > 0)
      return false;

   g_LastExitDealTime = latestExit;

   //--- Cancel any pending limit orders left from before the exit.
   CancelAllOurLimitOrders();

   //--- Reset FVG states completely and rescan from scratch.
   FVGInit();
   TrendUpdate();
   FVGUpdate();

   if(InpDebugLog)
      PrintFormat("[RESET] New SL/TP exit at %s → reset FVG array",
                  TimeToString(g_LastExitDealTime));

   return true;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   TrendDeinit();
   DrawCleanup();
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar())
      return;

   //--- IMPORTANT: reset internal FVG status after TP/SL so we don't reuse
   //--- old TOUCHED/MITIGATED states.
   if(CheckAndResetOnNewTP_SL_Exit())
   {
      DrawAll();
      return; // avoid entering a new trade on the same bar immediately
   }

   TrendUpdate();
   FVGUpdate();
   ManageFVGTrades();
   DrawAll();
}
