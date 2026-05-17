//+------------------------------------------------------------------+
//| HyperICT.mq5                                                     |
//| EA đọc cấu trúc HTF — không giao dịch                           |
//| Docs: Include/HyperICT/README.md                                 |
//| Mở folder workspace: .../MQL5 (không mở riêng Include/HyperICT)|
//+------------------------------------------------------------------+
//| MAP SPEC → MODULE:                                               |
//|  § tiên quyết Fib + HH-HL     → FibValidator, SwingEngine        |
//|  §1.1 trạng thái trend       → Classifier, Panel                 |
//|  §1.2 Key LV + OB            → KeyLevels, Draw                   |
//|  §1.3 vẽ label/rect          → Draw                              |
//|  §1.4 CHoCH/Continue         → UpdateEngine, SwingEngine roll    |
//|  Pipeline                    → StateMachine                      |
//|  Input HTF/swing/fib         → Config                            |
//|  Kiểu dữ liệu                → Types                              |
//|                                                                  |
//| CHƯA CÓ TRONG DỰ ÁN: đặt lệnh, LTF, session, alert             |
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
//| Khóa snapshot swing HTF + vẽ lần đầu                             |
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
//| Mỗi tick: logic HTF chỉ trên nến HTF mới (StateMachine)          |
//| Vẽ rectangle kéo dài mỗi tick                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   CStateMachine::OnChartEvent(g_ctx);
   CDraw::Render(g_ctx);
   CPanel::Render(g_ctx);
}

//+------------------------------------------------------------------+
//| API cho EA/script khác đọc state                                 |
//+------------------------------------------------------------------+
ENUM_HTF_STATE HyperICT_GetState() { return g_ctx.state; }

//+------------------------------------------------------------------+
