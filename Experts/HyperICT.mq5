//+------------------------------------------------------------------+
//| HyperICT.mq5                                                     |
//| HTF structure: swings, Key LV, CHoCH / Continue (modular)        |
//+------------------------------------------------------------------+
#property copyright "HyperICT"
#property version   "0.11"
#property description "HTF structure | Fib=init only | pivot confirm=InpSwingRange"

#include <HyperICT/Config.mqh>
#include <HyperICT/Types.mqh>
#include <HyperICT/StateMachine.mqh>
#include <HyperICT/Draw.mqh>
#include <HyperICT/Panel.mqh>

HtfContext g_ctx;

//+------------------------------------------------------------------+
int OnInit()
{
   g_ctx.symbol = _Symbol;
   g_ctx.htf = InpHtf;
   g_ctx.lastHtfBar = iTime(_Symbol, InpHtf, 0);

   if(!CStateMachine::Init(g_ctx, _Symbol))
   {
      Print("[HyperICT] Init: chưa đủ swing — chờ dữ liệu hoặc giảm InpSwingRange");
      return INIT_SUCCEEDED;
   }

   CDraw::Render(g_ctx);
   CPanel::Render(g_ctx);
   ChartRedraw();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CDraw::ClearAll();
   CPanel::Clear();
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   CStateMachine::OnChartEvent(g_ctx);
   CDraw::Render(g_ctx);
   CPanel::Render(g_ctx);
}

//+------------------------------------------------------------------+
ENUM_HTF_STATE HyperICT_GetState() { return g_ctx.state; }

//+------------------------------------------------------------------+
