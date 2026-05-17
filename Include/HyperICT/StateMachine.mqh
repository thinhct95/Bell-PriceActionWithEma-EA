//+------------------------------------------------------------------+
//| StateMachine.mqh                                                 |
//| Pipeline: Init → mỗi nến HTF → Update → Fib/Key → Classify       |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • OnInit: LockInitialSnapshot (swing cố định từ lúc bot chạy)   |
//|  • Mỗi nến HTF mới: UpdateEngine → RefreshDerived → state        |
//|  • RefreshDerived: Fib tiên quyết + KeyLevels + Classifier       |
//|  • Sau roll swing: tính lại structBias, fibOk, key, state        |
//| KHÔNG: trading logic, OnTimer intrabar cho update                |
//+------------------------------------------------------------------+
#ifndef HYPERICT_STATEMACHINE_MQH
#define HYPERICT_STATEMACHINE_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/SwingEngine.mqh>
#include <HyperICT/FibValidator.mqh>
#include <HyperICT/KeyLevels.mqh>
#include <HyperICT/Classifier.mqh>
#include <HyperICT/UpdateEngine.mqh>

class CStateMachine
{
   static void Dbg(const string msg)
   {
      if(InpDebug)
         Print("[HyperICT] ", msg);
   }

   static void RefreshDerived(HtfContext &ctx)
   {
      // Fib 0.382: chỉ ý nghĩa tiên quyết pullback trên bộ swing hiện tại
      ctx.fibOk = CFibValidator::IsPullbackValid(ctx.swings, InpFibMinRatio);
      CKeyLevels::BuildKeyLevels(ctx.symbol, ctx.htf, ctx.structBias,
                                 ctx.swings, ctx.keyLv1, ctx.keyLv2);
      ctx.state = CClassifier::Evaluate(ctx);
   }

public:
   static bool Init(HtfContext &ctx, const string sym)
   {
      ctx.symbol = sym;
      ctx.htf = InpHtf;
      ctx.update.Clear();
      ctx.lastHtfBar = 0;
      ctx.snapshotReady = false;

      if(!CSwingEngine::LockInitialSnapshot(ctx))
      {
         Dbg("Init fail: không đủ 4 swing HTF");
         return false;
      }
      ctx.structBias = CSwingEngine::ClassifyStructure(ctx.swings);
      RefreshDerived(ctx);
      Dbg(StringFormat("Snapshot locked | bias=%d fib=%s state=%s",
           ctx.structBias, ctx.fibOk ? "OK" : "pending",
           CClassifier::StateText(ctx.state)));
      return true;
   }

   static void OnChartEvent(HtfContext &ctx, const bool forceRedraw = false)
   {
      const bool newBar = CUpdateEngine::IsNewHtfBar(ctx);
      if(newBar)
      {
         ctx.lastHtfBar = iTime(ctx.symbol, ctx.htf, 0);
         CUpdateEngine::OnHtfBarClose(ctx);   // §1.4 trước
         RefreshDerived(ctx);                 // §1.1 + §1.2 sau
         if(InpDebug)
            Dbg("HTF bar → " + CClassifier::StateText(ctx.state));
      }
      else if(forceRedraw)
         RefreshDerived(ctx);
   }
};

#endif // HYPERICT_STATEMACHINE_MQH
