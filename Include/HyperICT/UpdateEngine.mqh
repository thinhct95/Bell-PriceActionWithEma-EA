//+------------------------------------------------------------------+
//| UpdateEngine.mqh                                                 |
//| §1.4 CHoCH & Trend Continue — cập nhật incremental               |
//+------------------------------------------------------------------+
//| ĐÃ GIẢI QUYẾT:                                                   |
//|  • Chỉ chạy khi nến HTF mới đóng; không quét lại full lookback   |
//|  • Phá Key LV1 (body) → CHoCH | Phá Key LV2 → Continue           |
//|  • §1.4a Bull Continue P1: track newH0 (nến xanh), newL0 (đáy)   |
//|  • §1.4a P2: IsConfirmedSwingHigh(newH0) → roll, khóa newH0    |
//|  • §1.4b Bull CHoCH P1–2: track newL0 → swing low confirm → P3   |
//|  • §1.4b P3 case1: phá H0 → newH0 confirm → roll (L1 giữ)       |
//|  • §1.4b P3 case2: phá newL0 → newH0+newL02 confirm → bear roll|
//|  • §1.4c/d Bear: đối xứng Continue & CHoCH                       |
//|  • Xác nhận đỉnh/đáy = InpSwingRange (KHÔNG dùng Fib ở đây)      |
//| CHƯA TỐI ƯU: gắn OB chính xác cho newL0 mỗi leg; edge case đa tín hiệu |
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
                            const int shift, SwingPoint &pt, const bool onlyIfLocked)
   {
      if(onlyIfLocked)
         return;
      const double h = iHigh(sym, tf, shift);
      if(!pt.Valid() || h > pt.price)
         CSwingEngine::FillSwingHigh(sym, tf, shift, pt);
   }

   static void TrackNewLow(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, SwingPoint &pt, const bool onlyIfLocked)
   {
      if(onlyIfLocked)
         return;
      const double l = iLow(sym, tf, shift);
      if(!pt.Valid() || l < pt.price)
         CSwingEngine::FillSwingLow(sym, tf, shift, pt);
   }

   static void FinalizePivotHigh(const string sym, const ENUM_TIMEFRAMES tf,
                                 SwingPoint &pt, const int range)
   {
      if(pt.Valid())
         CSwingEngine::FillSwingHigh(sym, tf, pt.shift, pt);
   }

   static void FinalizePivotLow(const string sym, const ENUM_TIMEFRAMES tf,
                                SwingPoint &pt, const int range)
   {
      if(pt.Valid())
         CSwingEngine::FillSwingLow(sym, tf, pt.shift, pt);
   }

   static void FinishRoll(HtfContext &ctx)
   {
      ctx.update.Clear();
      ctx.structBias = CSwingEngine::ClassifyStructure(ctx.swings);
      Dbg(StringFormat("Roll xong — bias=%d", ctx.structBias));
   }

public:
   static bool IsNewHtfBar(HtfContext &ctx)
   {
      const datetime t0 = iTime(ctx.symbol, ctx.htf, 0);
      return t0 != 0 && t0 != ctx.lastHtfBar;
   }

   //--- Phát hiện body phá Key LV1/L2 lần đầu → bật BUILD
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
            Dbg("Bull CHoCH — body break L0");
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
            Dbg("Bear CHoCH — body break H0");
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

   //--- §1.4a Bull Continue — P1 track + P2 swing high confirm → roll
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

      FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange);
      ctx.update.newH0Locked = true;
      FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange);
      CSwingEngine::RollBullContinue(ctx.swings, ctx.update.newH0, ctx.update.newL0);
      FinishRoll(ctx);
      Dbg("Bull Continue — swing high confirmed, rolled");
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

      FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange);
      ctx.update.newLLocked = true;
      FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange);
      CSwingEngine::RollBearContinue(ctx.swings, ctx.update.newH0, ctx.update.newL0);
      FinishRoll(ctx);
      Dbg("Bear Continue — swing low confirmed, rolled");
   }

   //--- §1.4b Bull CHoCH — P1 track newL0, P2 swing low confirm → CHOCH_RESOLVE
   static void ProcessBullChochBuild(HtfContext &ctx, const int sh)
   {
      TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, ctx.update.newLLocked);
      if(ctx.update.newLLocked)
         return;

      if(!CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
            ctx.update.newL0, InpSwingRange))
         return;

      FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange);
      ctx.update.newLLocked = true;
      ctx.update.phase = UPD_PHASE_CHOCH_RESOLVE;
      Dbg("Bull CHoCH — newL0 swing confirmed → phase 3");
   }

   static void ProcessBearChochBuild(HtfContext &ctx, const int sh)
   {
      TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, ctx.update.newH0Locked);
      if(ctx.update.newH0Locked)
         return;

      if(!CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
            ctx.update.newH0, InpSwingRange))
         return;

      FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange);
      ctx.update.newH0Locked = true;
      ctx.update.phase = UPD_PHASE_CHOCH_RESOLVE;
      Dbg("Bear CHoCH — newH0 swing confirmed → phase 3");
   }

   //--- §1.4b Bull CHoCH P3 — case1 về bull / case2 confirm bear
   static void ProcessBullChochResolve(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.swings.h0.price))
      {
         if(!ctx.update.case1TrackingH0)
         {
            ctx.update.case1TrackingH0 = true;
            ctx.update.newH0.Clear();
            ctx.update.newH0Locked = false;
            Dbg("Bull CHoCH case1 — break H0, track newH0");
         }
         if(CKeyLevels::IsBullCandle(ctx.symbol, ctx.htf, sh))
            TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, ctx.update.newH0Locked);

         if(ctx.update.case1TrackingH0 && !ctx.update.newH0Locked &&
            CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
               ctx.update.newH0, InpSwingRange))
         {
            FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange);
            ctx.update.newH0Locked = true;
            CSwingEngine::RollBullChochCase1(ctx.swings, ctx.update.newH0, ctx.update.newL0);
            FinishRoll(ctx);
            Dbg("Bull CHoCH case1 — newH0 confirmed, rolled");
         }
         return;
      }

      if(ctx.update.newL0.Valid() &&
         CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.update.newL0.price))
      {
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newH0, false);
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL02, false);

         const bool hOk = CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
                              ctx.update.newH0, InpSwingRange);
         const bool lOk = CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
                              ctx.update.newL02, InpSwingRange);
         if(hOk && lOk)
         {
            FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newH0, InpSwingRange);
            FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL02, InpSwingRange);
            CSwingEngine::RollBullChochCase2(ctx.swings,
                  ctx.update.newH0, ctx.update.newL0, ctx.update.newL02);
            FinishRoll(ctx);
            Dbg("Bull CHoCH case2 — bear confirmed, rolled");
         }
      }
   }

   static void ProcessBearChochResolve(HtfContext &ctx, const int sh)
   {
      if(CKeyLevels::BodyBreakBelow(ctx.symbol, ctx.htf, sh, ctx.swings.l0.price))
      {
         if(!ctx.update.case1TrackingH0)
         {
            ctx.update.case1TrackingH0 = true;
            ctx.update.newL0.Clear();
            ctx.update.newLLocked = false;
            Dbg("Bear CHoCH case1 — break L0, track newL0");
         }
         if(CKeyLevels::IsBearCandle(ctx.symbol, ctx.htf, sh))
            TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, ctx.update.newLLocked);

         if(ctx.update.case1TrackingH0 && !ctx.update.newLLocked &&
            CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
               ctx.update.newL0, InpSwingRange))
         {
            FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange);
            ctx.update.newLLocked = true;
            CSwingEngine::RollBearChochCase1(ctx.swings, ctx.update.newH0, ctx.update.newL0);
            FinishRoll(ctx);
            Dbg("Bear CHoCH case1 — newL0 confirmed, rolled");
         }
         return;
      }

      if(ctx.update.newH0.Valid() &&
         CKeyLevels::BodyBreakAbove(ctx.symbol, ctx.htf, sh, ctx.update.newH0.price))
      {
         TrackNewLow(ctx.symbol, ctx.htf, sh, ctx.update.newL0, false);
         TrackNewHigh(ctx.symbol, ctx.htf, sh, ctx.update.newL02, false);

         const bool lOk = CSwingEngine::IsConfirmedSwingLow(ctx.symbol, ctx.htf,
                              ctx.update.newL0, InpSwingRange);
         const bool hOk = CSwingEngine::IsConfirmedSwingHigh(ctx.symbol, ctx.htf,
                              ctx.update.newL02, InpSwingRange);
         if(lOk && hOk)
         {
            FinalizePivotLow(ctx.symbol, ctx.htf, ctx.update.newL0, InpSwingRange);
            FinalizePivotHigh(ctx.symbol, ctx.htf, ctx.update.newL02, InpSwingRange);
            CSwingEngine::RollBearChochCase2(ctx.swings,
                  ctx.update.newH0, ctx.update.newL0, ctx.update.newL02);
            FinishRoll(ctx);
            Dbg("Bear CHoCH case2 — bull confirmed, rolled");
         }
      }
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
