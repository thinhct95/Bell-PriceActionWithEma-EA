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

   // ── Xác định side: ưu tiên M5 FVG, fallback chochBias khi không có FVG
   const bool hasFvg = (m5Zone.side != ICT_FVG_NONE);
   ENUM_ICT_BIAS bias = ICT_BIAS_NONE;
   if(hasFvg)
      bias = (m5Zone.side == ICT_FVG_BULL) ? ICT_BIAS_BULL : ICT_BIAS_BEAR;
   else if(g_ictLowTf.mss.chochLocked)
      bias = g_ictLowTf.mss.chochBias;

   if(bias == ICT_BIAS_NONE)
   {
      reasonOut = "Không xác định được side (no FVG + no chochBias)";
      return false;
   }
   const bool isBuy = (bias == ICT_BIAS_BULL);

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

   // SL final (đã buffer + spread)
   slOut = isBuy ? swingSl - bufSl : swingSl + bufSl;

   // ── 2 candidate entries:
   //    A) M5 FVG limit (nếu có)
   //    B) MSS keyLV (chochKeyLevel — L0 broken cho bear, H0 broken cho bull)
   const double mktBid = SymbolInfoDouble(sym, SYMBOL_BID);
   const double mktAsk = SymbolInfoDouble(sym, SYMBOL_ASK);

   double entryFvg = 0.0, riskFvg = DBL_MAX;
   if(hasFvg)
   {
      entryFvg = IctMssEntry_LimitPrice(m5Zone);
      const double rA = isBuy ? (entryFvg - slOut) : (slOut - entryFvg);
      const bool limitOk = isBuy ? (entryFvg < mktAsk - _Point)
                                 : (entryFvg > mktBid + _Point);
      if(entryFvg > 0.0 && rA > _Point && limitOk)
         riskFvg = rA;
   }

   double entryMss = g_ictLowTf.mss.chochKeyLevel;
   double riskMss = DBL_MAX;
   {
      const double rB = isBuy ? (entryMss - slOut) : (slOut - entryMss);
      const bool limitOk = isBuy ? (entryMss < mktAsk - _Point)
                                 : (entryMss > mktBid + _Point);
      if(entryMss > 0.0 && rB > _Point && limitOk)
         riskMss = rB;
   }

   string entrySource = "";
   if(riskFvg < DBL_MAX && (riskMss == DBL_MAX || riskFvg < riskMss))
   {
      entryOut = entryFvg;
      entrySource = StringFormat("M5 FVG (risk %.2f < MSS %.2f)",
                                 riskFvg, (riskMss == DBL_MAX ? 0.0 : riskMss));
   }
   else if(riskMss < DBL_MAX)
   {
      entryOut = entryMss;
      if(hasFvg)
         entrySource = StringFormat("MSS keyLV (risk %.2f ≤ FVG %.2f)",
                                    riskMss, (riskFvg == DBL_MAX ? 999.99 : riskFvg));
      else
         entrySource = "MSS keyLV (no M5 FVG)";
   }
   else
   {
      reasonOut = StringFormat(
         "Cả 2 entry không hợp lệ | mkt=%.2f/%.2f | FVG=%.2f | MSS=%.2f | SL=%.2f",
         mktBid, mktAsk, entryFvg, entryMss, slOut);
      return false;
   }

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
   const double risk = isBuy ? (entryOut - slOut) : (slOut - entryOut);
   if(risk <= _Point)
   {
      reasonOut = StringFormat("Risk≤0 (SL %.5f vs entry %.5f)", slOut, entryOut);
      return false;
   }

   // Swing-based TP (= TP "tự nhiên" tại iL0/iH0 ± bufTp) — dùng cho partial close trigger
   double swingTp = 0.0;
   if(isBuy)
   {
      double tpAtIH0 = 0.0, rrAtIH0 = 0.0;
      if(tpTarget > 0.0 && tpTarget > entryOut + bufTp + _Point)
      {
         tpAtIH0 = tpTarget - bufTp;
         rrAtIH0 = (tpAtIH0 - entryOut) / risk;
         swingTp = tpAtIH0;
      }
      tpOut = (rrAtIH0 > minRR) ? tpAtIH0 : (entryOut + risk * minRR);
   }
   else
   {
      double tpAtIL0 = 0.0, rrAtIL0 = 0.0;
      if(tpTarget > 0.0 && tpTarget < entryOut - bufTp - _Point)
      {
         tpAtIL0 = tpTarget + bufTp;
         rrAtIL0 = (entryOut - tpAtIL0) / risk;
         swingTp = tpAtIL0;
      }
      tpOut = (rrAtIL0 > minRR) ? tpAtIL0 : (entryOut - risk * minRR);
   }

   // Partial close trigger: chỉ kích hoạt khi TP gồng XA HƠN swing TP
   //   BUY: tpOut > swingTp + _Point → partial khi giá lên đến swingTp
   //   SELL: tpOut < swingTp - _Point → partial khi giá xuống đến swingTp
   double partialTrigger = 0.0;
   if(swingTp > 0.0 && InpMssPartialClosePct > 0.0)
   {
      if(isBuy && tpOut > swingTp + _Point)
         partialTrigger = swingTp;
      else if(!isBuy && tpOut < swingTp - _Point)
         partialTrigger = swingTp;
   }
   g_ictLowTf.mss.partialTriggerPrice = partialTrigger;
   g_ictLowTf.mss.partialCloseDone    = false;

   // entrySource lưu vào reasonOut để display thấy nguồn entry
   reasonOut = entrySource;

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

// Chốt 50% volume + dời SL về BE khi giá đạt swing iL0/iH0 (chỉ áp dụng khi TP gồng xa hơn swing)
void IctMssEntry_CheckPartialClose(const string sym)
{
   if(InpMssPartialClosePct <= 0.0)
      return;
   if(g_ictLowTf.mss.partialCloseDone)
      return;
   if(g_ictLowTf.mss.partialTriggerPrice <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMssMagic)
         continue;

      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      const double volume = PositionGetDouble(POSITION_VOLUME);
      const double curTp  = PositionGetDouble(POSITION_TP);
      const double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
      const double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
      const double trig   = g_ictLowTf.mss.partialTriggerPrice;

      bool reached = false;
      if(ptype == POSITION_TYPE_BUY)
         reached = (bid >= trig - _Point);
      else if(ptype == POSITION_TYPE_SELL)
         reached = (ask <= trig + _Point);

      if(!reached)
         return;

      // Tính volume cần đóng (1 nửa, đã normalize step)
      const double pct = MathMax(0.0, MathMin(100.0, InpMssPartialClosePct)) / 100.0;
      const double vClose = IctMssEntry_NormalizeVolume(sym, volume * pct);
      if(vClose <= 0.0 || vClose >= volume)
         return;

      g_ictMssTrade.SetExpertMagicNumber(InpMssMagic);
      if(!g_ictMssTrade.PositionClosePartial(ticket, vClose))
      {
         if(InpMssLogJournal)
            PrintFormat("[ICT2026/MSS] PartialClose fail #%I64u vol=%.2f — %d %s",
                        ticket, vClose, g_ictMssTrade.ResultRetcode(),
                        g_ictMssTrade.ResultRetcodeDescription());
         return;
      }

      // Dời SL về BE (entry price). Giữ TP cũ.
      if(!g_ictMssTrade.PositionModify(ticket, openPx, curTp))
      {
         if(InpMssLogJournal)
            PrintFormat("[ICT2026/MSS] BE move fail #%I64u — %d %s",
                        ticket, g_ictMssTrade.ResultRetcode(),
                        g_ictMssTrade.ResultRetcodeDescription());
      }

      g_ictLowTf.mss.partialCloseDone = true;

      if(InpMssLogJournal)
         PrintFormat("[ICT2026/MSS] PartialClose #%I64u %.0f%% (%.2f→%.2f lot) @ %.2f | SL→BE %.2f | TP %.2f",
                     ticket, InpMssPartialClosePct, volume, volume - vClose,
                     (ptype == POSITION_TYPE_BUY ? bid : ask),
                     openPx, curTp);
      return;
   }
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
   IctMssEntry_CheckPartialClose(sym);

   if(g_ictLowTf.mss.phase == ICT_MSS_IDLE && g_ictLowTf.mss.pendingTicket > 0)
   {
      IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
      g_ictLowTf.mss.pendingTicket = 0;
   }

   if(!InpMssTradeEnabled)
   {
      if(g_ictLowTf.mss.phase >= ICT_MSS_CHOCH)
         IctMss_JournalEntryBlock("InpMssTradeEnabled=false");
      return;
   }

   // Cho phép entry từ CHOCH trở lên (không bắt buộc M5 FVG):
   // ComputeLevels sẽ chọn entry giữa M5 FVG (nếu có) và MSS keyLV (luôn có sau lock)
   if(!g_ictIntraday.isAllowTrade ||
      g_ictLowTf.mss.phase < ICT_MSS_CHOCH ||
      !g_ictLowTf.mss.chochLocked ||
      g_ictLowTf.mss.chochKeyLevel <= 0.0)
   {
      if(g_ictLowTf.mss.pendingTicket > 0)
      {
         IctMssEntry_CancelTicket(g_ictLowTf.mss.pendingTicket);
         g_ictLowTf.mss.pendingTicket = 0;
      }
      if(g_ictLowTf.mss.phase >= ICT_MSS_H1_TOUCH)
      {
         if(!g_ictIntraday.isAllowTrade)
            IctMss_JournalEntryBlock("AllowTrade=false");
         else if(g_ictLowTf.mss.phase < ICT_MSS_CHOCH)
            IctMss_JournalEntryBlock(g_ictLowTf.mss.displayReason);
         else
            IctMss_JournalEntryBlock("Chờ MSS lock (chochKeyLevel)");
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

   // M5 FVG là OPTIONAL: nếu có thì compare với MSS keyLV để chọn entry SL gần hơn
   IctFvgZone m5;
   m5.side = ICT_FVG_NONE;
   if(g_ictLowTf.mss.m5FvgId > 0)
   {
      const int mIdx = IctConfirmFvg_FindById(g_ictLowTf.mss.m5FvgId);
      if(mIdx >= 0)
         m5 = g_ictConfirmFvgZones[mIdx];
   }

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

   const bool isBuy = (g_ictLowTf.mss.chochBias == ICT_BIAS_BULL);
   const string entrySource = lvlReason; // ComputeLevels trả entrySource qua reasonOut
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
         g_ictLowTf.mss.displayReason = StringFormat("Limit %.2f SL %.2f TP %.2f | RR %.1f | %s",
                                         entry, sl, tp, rr, entrySource);
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
   g_ictLowTf.mss.displayReason = StringFormat("Sell/Buy limit %.2f | SL %.2f | TP %.2f RR%.1f | %s",
                                   entry, sl, tp, rr, entrySource);
}

#endif
