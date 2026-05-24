//+------------------------------------------------------------------+
//| UpdateEngine.mqh — §1.4 CHoCH / Continue                          |
//+------------------------------------------------------------------+
#ifndef HYPERICT_UPDATEENGINE_MQH
#define HYPERICT_UPDATEENGINE_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/SwingEngine.mqh>
#include <HyperICT/KeyLevels.mqh>

class CUpdateEngine
{
   static void Dbg(const string msg)
   {
      if(InpDebug)
         Print("[HyperICT/Update] ", msg);
   }

   static void TrackNewHigh(const string sym, const ENUM_TIMEFRAMES tf,
                            const int shift, SwingPoint &pt, const bool frozen)
   {
      if(frozen)
         return;
      const double h = iHigh(sym, tf, shift);
      if(!pt.Valid() || h > pt.price)
         CSwingEngine::FillSwingHigh(sym, tf, shift, pt);
   }

   static void TrackNewLow(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, SwingPoint &pt, const bool frozen)
   {
      if(frozen)
         return;
      const double l = iLow(sym, tf, shift);
      if(!pt.Valid() || l < pt.price)
         CSwingEngine::FillSwingLow(sym, tf, shift, pt);
   }

   static bool ConfirmedSwingHighAt(const string sym, const ENUM_TIMEFRAMES tf,
                                    const int shift, const int range)
   {
      SwingPoint pt;
      CSwingEngine::FillSwingHigh(sym, tf, shift, pt);
      return CSwingEngine::IsConfirmedSwingHigh(sym, tf, pt, range);
   }

   static bool ConfirmedSwingLowAt(const string sym, const ENUM_TIMEFRAMES tf,
                                   const int shift, const int range)
   {
      SwingPoint pt;
      CSwingEngine::FillSwingLow(sym, tf, shift, pt);
      return CSwingEngine::IsConfirmedSwingLow(sym, tf, pt, range);
   }

   // P2 bull CHoCH: đáy confirm (swing low) HOẶC đã hồi lên có swing high sau đáy
   static bool TryConfirmBullChochNewL0(const string sym, const ENUM_TIMEFRAMES tf,
                                        const SwingPoint &newL0, const int range)
   {
      if(!newL0.Valid())
         return false;

      if(CSwingEngine::IsConfirmedSwingLow(sym, tf, newL0, range))
         return true;

      for(int sh = 1; sh < newL0.shift; sh++)
      {
         if(iLow(sym, tf, sh) <= newL0.price + _Point)
            continue;
         if(ConfirmedSwingHighAt(sym, tf, sh, range))
            return true;
      }
      return false;
   }

   // Đỉnh hồi cao nhất (đã confirm) sau đáy newL0 — dùng seed newH0 case2
   static bool FindRetraceHighAfterLow(const string sym, const ENUM_TIMEFRAMES tf,
                                       const SwingPoint &low, const int range,
                                       SwingPoint &outHigh)
   {
      outHigh.Clear();
      if(!low.Valid())
         return false;

      for(int sh = 1; sh < low.shift; sh++)
      {
         if(iLow(sym, tf, sh) <= low.price + _Point)
            continue;
         if(!ConfirmedSwingHighAt(sym, tf, sh, range))
            continue;
         const double h = iHigh(sym, tf, sh);
         if(!outHigh.Valid() || h > outHigh.price)
            CSwingEngine::FillSwingHigh(sym, tf, sh, outHigh);
      }
      return outHigh.Valid();
   }

   static bool FindRetraceLowAfterHigh(const string sym, const ENUM_TIMEFRAMES tf,
                                      const SwingPoint &high, const int range,
                                      SwingPoint &outLow)
   {
      outLow.Clear();
      if(!high.Valid())
         return false;

      for(int sh = 1; sh < high.shift; sh++)
      {
         if(iHigh(sym, tf, sh) >= high.price - _Point)
            continue;
         if(!ConfirmedSwingLowAt(sym, tf, sh, range))
            continue;
         const double l = iLow(sym, tf, sh);
         if(!outLow.Valid() || l < outLow.price)
            CSwingEngine::FillSwingLow(sym, tf, sh, outLow);
      }
      return outLow.Valid();
   }

   // P2 bear CHoCH: đỉnh confirm hoặc hồi xuống có swing low sau đỉnh
   static bool TryConfirmBearChochNewH0(const string sym, const ENUM_TIMEFRAMES tf,
                                        const SwingPoint &newH0, const int range)
   {
      if(!newH0.Valid())
         return false;

      if(CSwingEngine::IsConfirmedSwingHigh(sym, tf, newH0, range))
         return true;

      for(int sh = 1; sh < newH0.shift; sh++)
      {
         if(iHigh(sym, tf, sh) >= newH0.price - _Point)
            continue;
         if(ConfirmedSwingLowAt(sym, tf, sh, range))
            return true;
      }
      return false;
   }

   static void FinishRoll(HtfContext &ctx)
   {
      ctx.update.Clear();
      ctx.structBias = CSwingEngine::ClassifyStructure(ctx.swings);
      Dbg(StringFormat("Roll xong — bias=%d", ctx.structBias));
   }

   static void LockBullChochNewL0(HtfContext &ctx)
   {
      CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL0.shift, ctx.update.newL0);
      ctx.update.newLLocked = true;
      ctx.update.phase = UPD_PHASE_CHOCH_RESOLVE;
      ctx.update.case2Active = false;
      ctx.update.newH0Case2Locked = false;
      ctx.update.newL02.Clear();

      SwingPoint retrace;
      if(FindRetraceHighAfterLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange, retrace))
      {
         ctx.update.newH0 = retrace;
         Dbg(StringFormat("Bull CHoCH P2 — seed newH0 @ %.5f (hồi sau đáy)", retrace.price));
      }
      else
         ctx.update.newH0.Clear();

      Dbg(StringFormat("Bull CHoCH P2 — newL0 khóa @ %.5f sh=%d",
                       ctx.update.newL0.price, ctx.update.newL0.shift));
   }

   static void LockBearChochNewH0(HtfContext &ctx)
   {
      CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newH0.shift, ctx.update.newH0);
      ctx.update.newH0Locked = true;
      ctx.update.phase = UPD_PHASE_CHOCH_RESOLVE;
      ctx.update.case2Active = false;
      ctx.update.newH0Case2Locked = false;
      ctx.update.newL02.Clear();

      SwingPoint retrace;
      if(FindRetraceLowAfterHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange, retrace))
      {
         ctx.update.newL0 = retrace;
         Dbg(StringFormat("Bear CHoCH P2 — seed newL0 @ %.5f (hồi sau đỉnh)", retrace.price));
      }
      else
         ctx.update.newL0.Clear();

      Dbg(StringFormat("Bear CHoCH P2 — newH0 khóa @ %.5f sh=%d",
                       ctx.update.newH0.price, ctx.update.newH0.shift));
   }

public:
   static bool IsNewHtfBar(HtfContext &ctx)
   {
      const datetime t0 = iTime(ctx.symbol, ctx.htf, 0);
      return t0 != 0 && t0 != ctx.lastHtfBar;
   }

   static void DetectBreakEvents(HtfContext &ctx)
   {
      if(ctx.update.phase != UPD_PHASE_IDLE)
         return;

      const int sh = 1;
      if(ctx.structBias == STRUCT_BULL)
      {
         if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.keyLv1.price))
         {
            ctx.update.event = UPD_CHOCH;
            ctx.update.phase = UPD_PHASE_BUILD;
            ctx.update.newL0.Clear();
            ctx.update.newH0Locked = false;
            ctx.update.newLLocked = false;
            ctx.update.case2Active = false;
            ctx.update.newH0Case2Locked = false;
            ctx.update.case1TrackingH0 = false;
            Dbg("Bull CHoCH P1 — body break L0");
         }
         else if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.keyLv2.price))
         {
            ctx.update.event = UPD_CONTINUE;
            ctx.update.phase = UPD_PHASE_BUILD;
            ctx.update.newH0.Clear();
            ctx.update.newL0.Clear();
            ctx.update.newH0Locked = false;
            TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
            Dbg("Bull Continue — body break H0");
         }
      }
      else if(ctx.structBias == STRUCT_BEAR)
      {
         if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.keyLv1.price))
         {
            ctx.update.event = UPD_CHOCH;
            ctx.update.phase = UPD_PHASE_BUILD;
            ctx.update.newH0.Clear();
            ctx.update.newH0Locked = false;
            ctx.update.newLLocked = false;
            ctx.update.case2Active = false;
            ctx.update.newH0Case2Locked = false;
            ctx.update.case1TrackingH0 = false;
            Dbg("Bear CHoCH P1 — body break H0");
         }
         else if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.keyLv2.price))
         {
            ctx.update.event = UPD_CONTINUE;
            ctx.update.phase = UPD_PHASE_BUILD;
            ctx.update.newH0.Clear();
            ctx.update.newL0.Clear();
            ctx.update.newLLocked = false;
            TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
            Dbg("Bear Continue — body break L0");
         }
      }
   }

   static void ProcessBullContinueBuild(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::IsBullCandle(ctx.symbol, ctx.htf, sh))
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, ctx.update.newH0Locked);
      TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);

      if(ctx.update.newH0Locked)
         return;

      if(!CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
            ctx.update.newH0, InpSwingRange))
         return;

      CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newH0.shift, ctx.update.newH0);
      CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL0.shift, ctx.update.newL0);
      CSwingEngine::RollBullContinue(ctx.swings, ctx.update.newH0, ctx.update.newL0);
      FinishRoll(ctx);
      Dbg("Bull Continue — roll");
   }

   static void ProcessBearContinueBuild(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::IsBearCandle(ctx.symbol, ctx.htf, sh))
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, ctx.update.newLLocked);
      TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);

      if(ctx.update.newLLocked)
         return;

      if(!CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
            ctx.update.newL0, InpSwingRange))
         return;

      CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL0.shift, ctx.update.newL0);
      CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newH0.shift, ctx.update.newH0);
      CSwingEngine::RollBearContinue(ctx.swings, ctx.update.newH0, ctx.update.newL0);
      FinishRoll(ctx);
      Dbg("Bear Continue — roll");
   }

   static void ProcessBullChochBuild(HtfContext &ctx, const int sh)
   {
      if(!ctx.update.newLLocked)
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);

      if(ctx.update.newLLocked)
         return;

      if(TryConfirmBullChochNewL0(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange))
         LockBullChochNewL0(ctx);
   }

   static void ProcessBearChochBuild(HtfContext &ctx, const int sh)
   {
      if(!ctx.update.newH0Locked)
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);

      if(ctx.update.newH0Locked)
         return;

      if(TryConfirmBearChochNewH0(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange))
         LockBearChochNewH0(ctx);
   }

   // P3 case2: newL0 khóa → hồi (newH0) → phá xuống (newL02) → roll bear
   static void ProcessBullChochCase2(HtfContext &ctx, const int sh)
   {
      if(!ctx.update.newLLocked || !ctx.update.newL0.Valid())
         return;

      if(!CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.update.newL0.price))
      {
         if(!ctx.update.case2Active)
            return;
      }
      else if(!ctx.update.case2Active)
      {
         ctx.update.case2Active = true;
         ctx.update.newL02.Clear();
         ctx.update.case1TrackingH0 = false;
         if(ctx.update.newH0.Valid() &&
            CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
               ctx.update.newH0, InpSwingRange))
            ctx.update.newH0Case2Locked = true;
         else
            ctx.update.newH0Case2Locked = false;
         Dbg("Bull CHoCH P3 case2 — bắt đầu (newL0 đã khóa, phá xuống)");
      }

      if(!ctx.update.case2Active)
         return;

      if(!ctx.update.newH0Case2Locked)
      {
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
         if(CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
               ctx.update.newH0, InpSwingRange))
         {
            CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newH0.shift, ctx.update.newH0);
            ctx.update.newH0Case2Locked = true;
            ctx.update.newL02.Clear();
            Dbg(StringFormat("Bull CHoCH case2 — newH0 confirm @ %.5f", ctx.update.newH0.price));
         }
         return;
      }

      TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL02, false);

      if(!CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
            ctx.update.newL02, InpSwingRange))
         return;

      CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL02.shift, ctx.update.newL02);
      CSwingEngine::RollBullChochCase2(ctx.swings,
            ctx.update.newH0, ctx.update.newL0, ctx.update.newL02);
      FinishRoll(ctx);
      Dbg("Bull CHoCH case2 — roll bear (H0→H1, newH0→H0, newL0→L1, newL02→L0)");
   }

   static void ProcessBullChochResolve(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.swings.h0.price))
      {
         ctx.update.case2Active = false;
         ctx.update.newH0Case2Locked = false;

         if(!ctx.update.case1TrackingH0)
         {
            ctx.update.case1TrackingH0 = true;
            ctx.update.newH0.Clear();
            ctx.update.newH0Locked = false;
            Dbg("Bull CHoCH case1 — phá H0, track newH0");
         }
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, ctx.update.newH0Locked);

         if(!ctx.update.newH0Locked &&
            CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
               ctx.update.newH0, InpSwingRange))
         {
            CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newH0.shift, ctx.update.newH0);
            CSwingEngine::RollBullChochCase1(ctx.swings, ctx.update.newH0, ctx.update.newL0);
            FinishRoll(ctx);
            Dbg("Bull CHoCH case1 — roll bull");
         }
         return;
      }

      ProcessBullChochCase2(ctx, sh);
   }

   static void ProcessBearChochCase2(HtfContext &ctx, const int sh)
   {
      if(!ctx.update.newH0Locked || !ctx.update.newH0.Valid())
         return;

      if(!CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.update.newH0.price))
      {
         if(!ctx.update.case2Active)
            return;
      }
      else if(!ctx.update.case2Active)
      {
         ctx.update.case2Active = true;
         ctx.update.newL02.Clear();
         ctx.update.case1TrackingH0 = false;
         if(ctx.update.newL0.Valid() &&
            CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
               ctx.update.newL0, InpSwingRange))
            ctx.update.newH0Case2Locked = true;
         else
            ctx.update.newH0Case2Locked = false;
         Dbg("Bear CHoCH P3 case2 — bắt đầu");
      }

      if(!ctx.update.case2Active)
         return;

      if(!ctx.update.newH0Case2Locked)
      {
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
         if(CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
               ctx.update.newL0, InpSwingRange))
         {
            CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL0.shift, ctx.update.newL0);
            ctx.update.newH0Case2Locked = true;
            ctx.update.newL02.Clear();
            Dbg(StringFormat("Bear CHoCH case2 — newL0 retrace confirm @ %.5f", ctx.update.newL0.price));
         }
         return;
      }

      TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newL02, false);

      if(!CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
            ctx.update.newL02, InpSwingRange))
         return;

      CSwingEngine::FillSwingHigh(ctx.symbol, ctx.htf, ctx.update.newL02.shift, ctx.update.newL02);
      CSwingEngine::RollBearChochCase2(ctx.swings,
            ctx.update.newH0, ctx.update.newL0, ctx.update.newL02);
      FinishRoll(ctx);
      Dbg("Bear CHoCH case2 — roll bull");
   }

   static void ProcessBearChochResolve(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.swings.l0.price))
      {
         ctx.update.case2Active = false;
         ctx.update.newH0Case2Locked = false;

         if(!ctx.update.case1TrackingH0)
         {
            ctx.update.case1TrackingH0 = true;
            ctx.update.newL0.Clear();
            ctx.update.newLLocked = false;
            Dbg("Bear CHoCH case1 — phá L0");
         }
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, ctx.update.newLLocked);

         if(!ctx.update.newLLocked &&
            CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
               ctx.update.newL0, InpSwingRange))
         {
            CSwingEngine::FillSwingLow(ctx.symbol, ctx.htf, ctx.update.newL0.shift, ctx.update.newL0);
            CSwingEngine::RollBearChochCase1(ctx.swings, ctx.update.newH0, ctx.update.newL0);
            FinishRoll(ctx);
            Dbg("Bear CHoCH case1 — roll bear");
         }
         return;
      }

      ProcessBearChochCase2(ctx, sh);
   }

   static void OnHtfBarClose(HtfContext &ctx)
   {
      const int sh = 1;

      if(ctx.update.phase == UPD_PHASE_IDLE)
      {
         DetectBreakEvents(ctx);
         if(ctx.update.phase != UPD_PHASE_BUILD)
            return;

         if(ctx.update.event == UPD_CONTINUE)
         {
            if(ctx.structBias == STRUCT_BULL)
            {
               if(CKeyLevels::IsBullCandle(ctx.symbol, ctx.htf, sh))
                  TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
               TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
            }
            else if(ctx.structBias == STRUCT_BEAR)
            {
               if(CKeyLevels::IsBearCandle(ctx.symbol, ctx.htf, sh))
                  TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
               TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
            }
         }
         else if(ctx.update.event == UPD_CHOCH)
         {
            if(ctx.structBias == STRUCT_BULL)
               TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
            else
               TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
         }
         return;
      }

      if(ctx.update.phase == UPD_PHASE_BUILD)
      {
         if(ctx.update.event == UPD_CONTINUE && ctx.structBias == STRUCT_BULL)
            ProcessBullContinueBuild(ctx, sh);
         else if(ctx.update.event == UPD_CONTINUE && ctx.structBias == STRUCT_BEAR)
            ProcessBearContinueBuild(ctx, sh);
         else if(ctx.update.event == UPD_CHOCH && ctx.structBias == STRUCT_BULL)
            ProcessBullChochBuild(ctx, sh);
         else if(ctx.update.event == UPD_CHOCH && ctx.structBias == STRUCT_BEAR)
            ProcessBearChochBuild(ctx, sh);
         return;
      }

      if(ctx.update.phase == UPD_PHASE_CHOCH_RESOLVE)
      {
         if(ctx.structBias == STRUCT_BULL)
            ProcessBullChochResolve(ctx, sh);
         else if(ctx.structBias == STRUCT_BEAR)
            ProcessBearChochResolve(ctx, sh);
      }
   }
};

#endif // HYPERICT_UPDATEENGINE_MQH
