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

   return INIT_SUCCEEDED;
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

   TrendUpdate();
   FVGUpdate();
   DrawAll();
}
