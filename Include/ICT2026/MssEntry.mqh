//+------------------------------------------------------------------+
//| MssEntry.mqh — Limit @ M5 FVG edge | SL H0/L0 M5 | TP min RR     |
//+------------------------------------------------------------------+
#ifndef ICT2026_MSSENTRY_MQH
#define ICT2026_MSSENTRY_MQH

#include <Trade/Trade.mqh>
#include <ICT2026/Journal.mqh>
#include <ICT2026/MssSetup.mqh>
#include <ICT2026/IntradayStructure.mqh>

CTrade g_ictMssTrade;

double IctMssEntry_NormalizePrice(const string sym, const double price)
{
   const double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      return NormalizeDouble(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   return NormalizeDouble(MathRound(price / tick) * tick,
                          (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
}

double IctMssEntry_NormalizeVolume(const string sym, double vol)
{
   const double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   const double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      return 0.0;
   vol = MathFloor(vol / step) * step;
   if(vol < vmin - 1e-12)
      return 0.0;
   if(vol > vmax)
      vol = vmax;
   return NormalizeDouble(vol, 2);
}

double IctMssEntry_VolumeForRisk(const string sym, const bool isBuy,
                                 const double entry, const double sl)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(MathAbs(entry - sl) < pt)
      return 0.0;

   const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpMssRiskPct / 100.0);
   double profit = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       sym, 1.0, entry, sl, profit))
      return 0.0;

   const double lossPerLot = MathAbs(profit);
   if(lossPerLot < DBL_EPSILON)
      return 0.0;

   return riskMoney / lossPerLot;
}

double IctMssEntry_LimitPrice(const IctFvgZone &zone)
{
   if(zone.side == ICT_FVG_BULL)
      return zone.upper;
   if(zone.side == ICT_FVG_BEAR)
      return zone.lower;
   return 0.0;
}

bool IctMssEntry_ComputeLevels(const string sym, const IctFvgZone &m5Zone,
                               double &entryOut, double &slOut, double &tpOut,
                               string &reasonOut)
{
   entryOut = slOut = tpOut = 0.0;
   reasonOut = "";

   entryOut = IctMssEntry_LimitPrice(m5Zone);
   if(entryOut <= 0.0)
   {
      reasonOut = "M5 FVG side không xác định";
      return false;
   }

   const bool isBuy = (m5Zone.side == ICT_FVG_BULL);
   const ENUM_ICT_BIAS bias = isBuy ? ICT_BIAS_BULL : ICT_BIAS_BEAR;

   double swingSl = 0.0;
   if(g_ictLowTf.mss.chochLocked && g_ictLowTf.mss.slSwingPrice > 0.0)
      swingSl = g_ictLowTf.mss.slSwingPrice;
   else if(!IctMss_GetConfirmMssSwing(sym, bias, swingSl))
   {
      if(g_ictLowTf.mss.slSwingPrice > 0.0)
         swingSl = g_ictLowTf.mss.slSwingPrice;
      else
      {
         reasonOut = "Chưa có swing H0/L0 M5 cho SL";
         return false;
      }
   }

   // Buffer SL/TP thuần spread — ổn định, không lệ thuộc ATR động
   //   SL = swing + InpMssSlSpreadMult × spread (cộng ra ngoài đỉnh/đáy)
   //   TP = iL0/iH0 ± InpMssTpSpreadMult × spread (chốt trước vùng cản để dễ khớp)
   const double spreadNow = MathMax(0.0,
                            SymbolInfoDouble(sym, SYMBOL_ASK) -
                            SymbolInfoDouble(sym, SYMBOL_BID));
   const double spreadUnit = (spreadNow > 0.0) ? spreadNow : _Point;

   const double bufSl = InpMssSlSpreadMult * spreadUnit;
   const double bufTp = InpMssTpSpreadMult * spreadUnit;
   const double minRR = MathMax(1.0, InpMssMinRR);

   // ── TP target = iL0 (BEAR) / iH0 (BULL): sóng H1, m5 chỉ để entry
   // TP đặt CÁCH target một buffer (gần chạm — không chờ hit chính xác)
   const IctSwingSet iSw = g_ictIntraday.swings;
   double tpTarget = 0.0;
   if(isBuy && iSw.hasH0)
      tpTarget = iSw.h0.price;
   else if(!isBuy && iSw.hasL0)
      tpTarget = iSw.l0.price;

   // ── Logic TP (1 ngưỡng duy nhất):
   //   RR(TP@iL0/iH0) > InpMssMinRR (= 2.0) → dùng TP tại iL0/iH0 (mục tiêu sóng H1)
   //   Ngược lại (RR ≤ 2.0 hoặc iL0/iH0 không khả dụng) → TP cố định = entry ± risk × InpMssMinRR (= 2R)
   if(isBuy)
   {
      slOut = swingSl - bufSl;
      const double risk = entryOut - slOut;
      if(risk <= _Point)
      {
         reasonOut = StringFormat("Risk≤0 (SL %.5f ≥ entry %.5f)", slOut, entryOut);
         return false;
      }

      double tpAtIH0 = 0.0;
      double rrAtIH0 = 0.0;
      if(tpTarget > 0.0 && tpTarget > entryOut + bufTp + _Point)
      {
         tpAtIH0 = tpTarget - bufTp;
         rrAtIH0 = (tpAtIH0 - entryOut) / risk;
      }

      if(rrAtIH0 > minRR)
         tpOut = tpAtIH0;
      else
         tpOut = entryOut + risk * minRR;
   }
   else
   {
      slOut = swingSl + bufSl;
      const double risk = slOut - entryOut;
      if(risk <= _Point)
      {
         reasonOut = StringFormat("Risk≤0 (SL %.5f ≤ entry %.5f)", slOut, entryOut);
         return false;
      }

      double tpAtIL0 = 0.0;
      double rrAtIL0 = 0.0;
      if(tpTarget > 0.0 && tpTarget < entryOut - bufTp - _Point)
      {
         tpAtIL0 = tpTarget + bufTp;
         rrAtIL0 = (entryOut - tpAtIL0) / risk;
      }

      if(rrAtIL0 > minRR)
         tpOut = tpAtIL0;
      else
         tpOut = entryOut - risk * minRR;
   }

   entryOut = IctMssEntry_NormalizePrice(sym, entryOut);
   slOut    = IctMssEntry_NormalizePrice(sym, slOut);
   tpOut    = IctMssEntry_NormalizePrice(sym, tpOut);

   if(isBuy && (slOut >= entryOut - _Point || tpOut <= entryOut + _Point))
   {
      reasonOut = StringFormat("SL/TP sai phía (BUY entry=%.5f SL=%.5f TP=%.5f)",
                               entryOut, slOut, tpOut);
      return false;
   }
   if(!isBuy && (slOut <= entryOut + _Point || tpOut >= entryOut - _Point))
   {
      reasonOut = StringFormat("SL/TP sai phía (SELL entry=%.5f SL=%.5f TP=%.5f)",
                               entryOut, slOut, tpOut);
      return false;
   }

   return true;
}

bool IctMssEntry_HasOpenPositionMagic(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMssMagic)
         return true;
   }
   return false;
}

bool IctMssEntry_HasOpenExposure(const string sym)
{
   if(IctMssEntry_HasOpenPositionMagic(sym))
      return true;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != sym)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMssMagic)
         continue;
      const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT)
         return true;
   }
   return false;
}

string IctMssEntry_DealReasonText(const long r)
{
   switch((ENUM_DEAL_REASON)r)
   {
      case DEAL_REASON_SL:     return "SL";
      case DEAL_REASON_TP:     return "TP";
      case DEAL_REASON_SO:     return "Stop Out";
      case DEAL_REASON_EXPERT: return "Expert close";
      case DEAL_REASON_CLIENT: return "Manual";
      case DEAL_REASON_MOBILE: return "Mobile";
      case DEAL_REASON_WEB:    return "Web";
      default:                 return (r < 0) ? "Detected" : "Unknown";
   }
}

void IctMssEntry_MarkM5FvgUsed(const string sym, const ulong fvgId)
{
   if(fvgId == 0)
      return;
   const int idx = IctConfirmFvg_FindById(fvgId);
   if(idx < 0)
      return;
   g_ictConfirmFvgZones[idx].state = ICT_FVG_USED;
   if(g_ictConfirmFvgZones[idx].fvgUsedTime == 0)
      g_ictConfirmFvgZones[idx].fvgUsedTime = iTime(sym, InpConfirmTf, 0);
}

void IctMss_OnEodCancel(const string sym, const ulong ticket)
{
   const ulong m5Id = g_ictLowTf.mss.m5FvgId;
   const ulong h1Id = g_ictLowTf.mss.h1FvgId;

   if(ticket > 0 && OrderSelect(ticket))
      g_ictMssTrade.OrderDelete(ticket);

   IctMss_ResetState();
   g_ictLowTf.mss.displayReason = StringFormat(
      "EOD cancel pending #%I64u | H1 #%I64u — reset, chờ phiên mới",
      ticket, h1Id);

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/MSS] EOD cancel limit #%I64u | H1 #%I64u | M5 #%I64u | reset → WAIT_FVG_TOUCH",
                  ticket, h1Id, m5Id);
}

void IctMss_OnPendingTimeout(const string sym, const ulong ticket, const int hours)
{
   const ulong m5Id = g_ictLowTf.mss.m5FvgId;
   const ulong h1Id = g_ictLowTf.mss.h1FvgId;

   if(ticket > 0 && OrderSelect(ticket))
      g_ictMssTrade.OrderDelete(ticket);

   IctMssEntry_MarkM5FvgUsed(sym, m5Id);
   IctMss_ResetState();

   // Guard giống OnPositionClosed: chỉ accept H1 FVG có touch sau timeout
   g_ictMssAfterCloseGuard = TimeCurrent();

   g_ictLowTf.mss.displayReason = StringFormat(
      "Timeout %dh pending #%I64u | M5 FVG #%I64u → Used | chờ touch FVG mới",
      hours, ticket, m5Id);

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/MSS] Pending timeout %dh #%I64u | H1 #%I64u | M5 #%I64u → Used | guard=%s | reset → WAIT_FVG_TOUCH",
                  hours, ticket, h1Id, m5Id,
                  TimeToString(g_ictMssAfterCloseGuard, TIME_DATE | TIME_MINUTES));
}

void IctMssEntry_CheckPendingTimeout(const string sym)
{
   if(InpMssPendingExpireHours <= 0)
      return;
   if(g_ictLowTf.mss.pendingTicket == 0)
      return;
   if(g_ictLowTf.mss.pendingPlacedTime == 0)
      return;
   if(IctMssEntry_HasOpenPositionMagic(sym))
      return;

   const ulong ticket = g_ictLowTf.mss.pendingTicket;
   if(!OrderSelect(ticket))
   {
      // Pending đã biến mất (broker expire / cancel manual) mà chưa thành position
      // → vẫn coi như timeout, reset state để chờ FVG mới
      IctMss_OnPendingTimeout(sym, 0, InpMssPendingExpireHours);
      return;
   }

   const datetime placed = g_ictLowTf.mss.pendingPlacedTime;
   const int elapsedSec  = (int)(TimeCurrent() - placed);
   const int timeoutSec  = InpMssPendingExpireHours * 3600;
   if(elapsedSec < timeoutSec)
      return;

   IctMss_OnPendingTimeout(sym, ticket, InpMssPendingExpireHours);
}

void IctMssEntry_CheckEodCancel(const string sym)
{
   if(!InpMssCancelPendingEod)
      return;
   if(g_ictLowTf.mss.pendingTicket == 0)
      return;
   if(IctMssEntry_HasOpenPositionMagic(sym))
      return;

   const ulong ticket = g_ictLowTf.mss.pendingTicket;
   if(!OrderSelect(ticket))
   {
      g_ictLowTf.mss.pendingTicket = 0;
      return;
   }

   MqlDateTime mdt;
   TimeToStruct(TimeCurrent(), mdt);
   const int nowMinutes = mdt.hour * 60 + mdt.min;
   const int eodMinutes = InpMssEodHour * 60 + InpMssEodMinute;
   if(nowMinutes < eodMinutes)
      return;

   MqlDateTime d0;
   d0.year = mdt.year;
   d0.mon  = mdt.mon;
   d0.day  = mdt.day;
   d0.hour = 0;
   d0.min  = 0;
   d0.sec  = 0;
   const datetime dayStart = StructToTime(d0);

   static datetime s_lastEodHandledDate = 0;
   if(s_lastEodHandledDate == dayStart)
      return;
   s_lastEodHandledDate = dayStart;

   IctMss_OnEodCancel(sym, ticket);
}

void IctMss_OnPositionClosed(const string sym, const long reason, const double netProfit)
{
   const ulong m5Id = g_ictLowTf.mss.m5FvgId;
   const ulong h1Id = g_ictLowTf.mss.h1FvgId;
   const string rt  = IctMssEntry_DealReasonText(reason);

   IctMssEntry_MarkM5FvgUsed(sym, m5Id);

   IctMss_ResetState();

   // Guard: chặn pipeline pick H1 FVG có touch trước thời điểm này.
   // Phải đợi touch mới (FVG mới hoặc re-touch) thì mới setup MSS + entry mới.
   g_ictMssAfterCloseGuard = TimeCurrent();

   g_ictLowTf.mss.displayReason = StringFormat(
      "Đóng %s (net %.2f) | M5 FVG #%I64u → Used | chờ touch FVG mới",
      rt, netProfit, m5Id);

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/MSS] Close (%s, net=%.2f) | H1 #%I64u | M5 #%I64u → Used | guard=%s | reset → WAIT_FVG_TOUCH",
                  rt, netProfit, h1Id, m5Id,
                  TimeToString(g_ictMssAfterCloseGuard, TIME_DATE | TIME_MINUTES));
}

bool IctMssEntry_CancelTicket(const ulong ticket)
{
   if(ticket == 0)
      return true;
   if(!OrderSelect(ticket))
      return true;
   return g_ictMssTrade.OrderDelete(ticket);
}

bool IctMssEntry_PlaceLimit(const string sym, const bool isBuy,
                            const double entry, const double sl, const double tp,
                            const double volume, ulong &ticketOut)
{
   ticketOut = 0;
   g_ictMssTrade.SetExpertMagicNumber(InpMssMagic);
   g_ictMssTrade.SetDeviationInPoints(20);

   const string cmt = StringFormat("ICT26_MSS %s", isBuy ? "BUY" : "SELL");
   bool ok = false;
   if(InpMssPendingExpireHours > 0)
   {
      const datetime exp = TimeCurrent() + (datetime)(InpMssPendingExpireHours * 3600);
      if(isBuy)
         ok = g_ictMssTrade.BuyLimit(volume, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cmt);
      else
         ok = g_ictMssTrade.SellLimit(volume, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cmt);
   }
   else
   {
      if(isBuy)
         ok = g_ictMssTrade.BuyLimit(volume, entry, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);
      else
         ok = g_ictMssTrade.SellLimit(volume, entry, sym, sl, tp, ORDER_TIME_GTC, 0, cmt);
   }

   if(ok)
      ticketOut = g_ictMssTrade.ResultOrder();
   else if(InpDebug)
      PrintFormat("[ICT2026/Entry] Order fail %d — %s", g_ictMssTrade.ResultRetcode(),
                  g_ictMssTrade.ResultRetcodeDescription());

   return ok;
}

void IctMssEntry_Init()
{
   g_ictMssTrade.SetExpertMagicNumber(InpMssMagic);
}

void IctMssEntry_Update(const string sym)
{
   static bool s_hadPosition = false;
   const bool nowPosition = IctMssEntry_HasOpenPositionMagic(sym);

   if(s_hadPosition && !nowPosition && g_ictLowTf.mss.phase != ICT_MSS_IDLE)
   {
      // Fallback nếu OnTradeTransaction miss (reload, disconnect, …)
      IctMss_OnPositionClosed(sym, -1L, 0.0);
   }
   s_hadPosition = nowPosition;

   IctMssEntry_CheckEodCancel(sym);
   IctMssEntry_CheckPendingTimeout(sym);

   if(g_ictLowTf.mss.phase == ICT_MSS_IDLE && g_ictLowTf.mss.pendingTicket > 0)
   {
      IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
      g_ictLowTf.mss.pendingTicket = 0;
   }

   if(!InpMssTradeEnabled)
   {
      if(g_ictLowTf.mss.phase >= ICT_MSS_M5_FVG)
         IctMss_JournalEntryBlock("InpMssTradeEnabled=false");
      return;
   }

   if(!g_ictIntraday.isAllowTrade || g_ictLowTf.mss.phase < ICT_MSS_M5_FVG ||
      g_ictLowTf.mss.m5FvgId == 0)
   {
      if(g_ictLowTf.mss.pendingTicket > 0)
      {
         IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
         g_ictLowTf.mss.pendingTicket = 0;
      }
      if(g_ictLowTf.mss.phase >= ICT_MSS_CHOCH)
      {
         if(!g_ictIntraday.isAllowTrade)
            IctMss_JournalEntryBlock("AllowTrade=false");
         else if(g_ictLowTf.mss.phase < ICT_MSS_M5_FVG)
            IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
         else if(g_ictLowTf.mss.m5FvgId == 0)
            IctMss_JournalEntryBlock("Chưa có M5 FVG cho entry");
      }
      return;
   }

   if(InpMssOnePosition && IctMssEntry_HasOpenExposure(sym))
   {
      if(g_ictLowTf.mss.pendingTicket > 0 && !OrderSelect(g_ictLowTf.mss.pendingTicket))
         g_ictLowTf.mss.pendingTicket = 0;
      g_ictLowTf.mss.displayReason = StringFormat("%s | position/pending active",
                                      IctMssPhaseText(g_ictLowTf.mss.phase));
      IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
      return;
   }

   const int mIdx = IctConfirmFvg_FindById(g_ictLowTf.mss.m5FvgId);
   if(mIdx < 0)
      return;

   const IctFvgZone m5 = g_ictConfirmFvgZones[mIdx];
   double entry = 0.0, sl = 0.0, tp = 0.0;
   string lvlReason = "";
   if(!IctMssEntry_ComputeLevels(sym, m5, entry, sl, tp, lvlReason))
   {
      g_ictLowTf.mss.displayReason = StringFormat("%s | %s",
                                      IctMssPhaseText(g_ictLowTf.mss.phase),
                                      lvlReason);
      IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
      return;
   }

   const bool isBuy = (m5.side == ICT_FVG_BULL);
   const double vol = IctMssEntry_NormalizeVolume(sym,
                     IctMssEntry_VolumeForRisk(sym, isBuy, entry, sl));
   if(vol <= 0.0)
   {
      g_ictLowTf.mss.displayReason = "Lot=0 (SL quá gần hoặc risk)";
      IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
      return;
   }

   const double risk = isBuy ? (entry - sl) : (sl - entry);
   const double rr   = (risk > _Point) ? (isBuy ? (tp - entry) : (entry - tp)) / risk : 0.0;

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT) * 2.0;
   if(g_ictLowTf.mss.pendingTicket > 0 && OrderSelect(g_ictLowTf.mss.pendingTicket))
   {
      if(MathAbs(g_ictLowTf.mss.pendingEntry - entry) < pt &&
         MathAbs(g_ictLowTf.mss.pendingSl - sl) < pt &&
         MathAbs(g_ictLowTf.mss.pendingTp - tp) < pt)
      {
         g_ictLowTf.mss.displayReason = StringFormat("Limit %.2f SL %.2f TP %.2f | RR %.1f",
                                         entry, sl, tp, rr);
         return;
      }
      IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
      g_ictLowTf.mss.pendingTicket = 0;
   }

   ulong ticket = 0;
   if(!IctMssEntry_PlaceLimit(sym, isBuy, entry, sl, tp, vol, ticket))
   {
      g_ictLowTf.mss.displayReason = StringFormat("Đặt limit thất bại (%d %s)",
                                      g_ictMssTrade.ResultRetcode(),
                                      g_ictMssTrade.ResultRetcodeDescription());
      IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
      return;
   }

   g_ictLowTf.mss.pendingTicket     = ticket;
   g_ictLowTf.mss.pendingPlacedTime = TimeCurrent();
   g_ictLowTf.mss.pendingEntry      = entry;
   g_ictLowTf.mss.pendingSl         = sl;
   g_ictLowTf.mss.pendingTp         = tp;
   g_ictLowTf.mss.displayReason = StringFormat("Sell/Buy limit %.2f | SL %.2f (H0/L0) | TP %.2f RR%.1f",
                                   entry, sl, tp, rr);
}

#endif
