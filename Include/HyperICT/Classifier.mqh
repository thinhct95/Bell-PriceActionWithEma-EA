//+------------------------------------------------------------------+
//| Classifier.mqh — 7+ trạng thái §1.1 (bar đóng shift 1)           |
//+------------------------------------------------------------------+
#ifndef HYPERICT_CLASSIFIER_MQH
#define HYPERICT_CLASSIFIER_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/FibValidator.mqh>
#include <HyperICT/KeyLevels.mqh>

//+------------------------------------------------------------------+
class CClassifier
{
public:
   static ENUM_HTF_STATE Evaluate(HtfContext &ctx)
   {
      if(!ctx.snapshotReady || !ctx.swings.IsComplete())
         return HTF_NEUTRAL;

      if(ctx.structBias == STRUCT_NONE)
         return HTF_NEUTRAL;

      const int sh = 1;
      const double bodyMid = (iClose(ctx.symbol, ctx.htf, sh) +
                              iOpen(ctx.symbol, ctx.htf, sh)) * 0.5;

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

      if(!ctx.fibOk)
      {
         if(ctx.structBias == STRUCT_BULL)
            return HTF_BULL_INCOMPLETE;
         if(ctx.structBias == STRUCT_BEAR)
            return HTF_BEAR_INCOMPLETE;
      }

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
