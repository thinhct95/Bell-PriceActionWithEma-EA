//+------------------------------------------------------------------+
//| Classifier.mqh                                                   |
//| Phân loại trạng thái HTF §1.1 (bar HTF đóng, shift 1)            |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • Bull Pullback: Fib OK + giá (mid body) giữa L0–H0              |
//|  • Bull CHoCH: body phá dưới L0 HOẶC đang update.phase CHoCH     |
//|  • Bull Continue: body phá trên H0 HOẶC đang update Continue      |
//|  • Bear: đối xứng (phá H0 / phá L0)                              |
//|  • Neutral: không đủ 4 swing hoặc cấu trúc không HH-HL/LH-LL     |
//|  • Fib fail → BULL/BEAR_INCOMPLETE (sóng chưa kết thúc)          |
//| ƯU TIÊN: nếu đang §1.4 update → hiển thị CHoCH/Continue trước    |
//| CHƯA: phân tầng ưu tiên phức tạp khi nhiều tín hiệu cùng bar     |
//+------------------------------------------------------------------+
#ifndef HYPERICT_CLASSIFIER_MQH
#define HYPERICT_CLASSIFIER_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/FibValidator.mqh>
#include <HyperICT/KeyLevels.mqh>

class CClassifier
{
public:
   static ENUM_HTF_STATE Evaluate(HtfContext &ctx)
   {
      if(!ctx.snapshotReady || !ctx.swings.IsComplete())
         return HTF_NEUTRAL;

      if(ctx.structBias == STRUCT_NONE)
         return HTF_NEUTRAL;

      const int sh = 1;   // bar HTF vừa đóng
      const double bodyMid = (iClose(ctx.symbol, ctx.htf, sh) +
                              iOpen(ctx.symbol, ctx.htf, sh)) * 0.5;

      //--- Đang trong §1.4 → state CHoCH / Continue theo event
      if(ctx.update.phase != UPD_PHASE_IDLE)
      {
         if(ctx.structBias == STRUCT_BULL)
         {
            if(ctx.update.event == UPD_CONTINUE)
               return HTF_BULL_CONTINUE;
            if(ctx.update.event == UPD_CHOCH)
               return HTF_BULL_CHOCH;
         }
         else if(ctx.structBias == STRUCT_BEAR)
         {
            if(ctx.update.event == UPD_CONTINUE)
               return HTF_BEAR_CONTINUE;
            if(ctx.update.event == UPD_CHOCH)
               return HTF_BEAR_CHOCH;
         }
      }

      //--- § tiên quyết Fib: fail ≠ Neutral
      if(!ctx.fibOk)
      {
         if(ctx.structBias == STRUCT_BULL)
            return HTF_BULL_INCOMPLETE;
         if(ctx.structBias == STRUCT_BEAR)
            return HTF_BEAR_INCOMPLETE;
      }

      //--- §1.1 trạng thái khi snapshot idle (chưa hoặc đã xong update)
      if(ctx.structBias == STRUCT_BULL)
      {
         if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.keyLv1.price))
            return HTF_BULL_CHOCH;
         if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.keyLv2.price))
            return HTF_BULL_CONTINUE;
         if(CKeyLevels::PriceBetween(bodyMid, ctx.keyLv1.price, ctx.keyLv2.price))
            return HTF_BULL_PULLBACK;
      }
      else if(ctx.structBias == STRUCT_BEAR)
      {
         if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.keyLv1.price))
            return HTF_BEAR_CHOCH;
         if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.keyLv2.price))
            return HTF_BEAR_CONTINUE;
         if(CKeyLevels::PriceBetween(bodyMid, ctx.keyLv1.price, ctx.keyLv2.price))
            return HTF_BEAR_PULLBACK;
      }

      return HTF_NEUTRAL;
   }

   static string StateText(const ENUM_HTF_STATE s)
   {
      switch(s)
      {
         case HTF_BULL_INCOMPLETE: return "BULL (Fib pending)";
         case HTF_BEAR_INCOMPLETE: return "BEAR (Fib pending)";
         case HTF_BULL_PULLBACK:   return "BULL PULLBACK";
         case HTF_BULL_CHOCH:      return "BULL CHoCH";
         case HTF_BULL_CONTINUE:   return "BULL CONTINUE";
         case HTF_BEAR_PULLBACK:   return "BEAR PULLBACK";
         case HTF_BEAR_CHOCH:      return "BEAR CHoCH";
         case HTF_BEAR_CONTINUE:   return "BEAR CONTINUE";
         default:                  return "NEUTRAL";
      }
   }
};

#endif // HYPERICT_CLASSIFIER_MQH
