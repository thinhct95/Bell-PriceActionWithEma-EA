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

double IctMssEntry_Atr(const string sym, const ENUM_TIMEFRAMES tf, const int period)
{
   const int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, 1, 1, buf) != 1)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   IndicatorRelease(h);
   return buf[0];
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
                               double &entryOut, double &slOut, double &tpOut)
{
   entryOut = slOut = tpOut = 0.0;

   entryOut = IctMssEntry_LimitPrice(m5Zone);
   if(entryOut <= 0.0)
      return false;

   const bool isBuy = (m5Zone.side == ICT_FVG_BULL);
   const ENUM_ICT_BIAS bias = isBuy ? ICT_BIAS_BULL : ICT_BIAS_BEAR;

   double swingSl = 0.0;
   if(!IctMss_GetConfirmMssSwing(sym, bias, swingSl))
   {
      if(g_ictLowTf.mss.slSwingPrice > 0.0)
         swingSl = g_ictLowTf.mss.slSwingPrice;
      else
         return false;
   }

   const double atrM5 = IctMssEntry_Atr(sym, InpConfirmTf, InpFvgAtrPeriod);
   const double bufSl = (atrM5 > 0.0) ? atrM5 * InpMssSlAtrMult : 10.0 * _Point;
   const double minRR = MathMax(1.0, InpMssMinRR);

   if(isBuy)
   {
      slOut = swingSl - bufSl;
      const double risk = entryOut - slOut;
      if(risk <= _Point)
         return false;
      tpOut = entryOut + risk * minRR;
   }
   else
   {
      slOut = swingSl + bufSl;
      const double risk = slOut - entryOut;
      if(risk <= _Point)
         return false;
      tpOut = entryOut - risk * minRR;
   }

   entryOut = IctMssEntry_NormalizePrice(sym, entryOut);
   slOut    = IctMssEntry_NormalizePrice(sym, slOut);
   tpOut    = IctMssEntry_NormalizePrice(sym, tpOut);

   if(isBuy && (slOut >= entryOut - _Point || tpOut <= entryOut + _Point))
      return false;
   if(!isBuy && (slOut <= entryOut + _Point || tpOut >= entryOut - _Point))
      return false;

   return true;
}

bool IctMssEntry_HasOpenExposure(const string sym)
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
   if(!IctMssEntry_ComputeLevels(sym, m5, entry, sl, tp))
   {
      g_ictLowTf.mss.displayReason = StringFormat("%s | chờ H0/L0 M5 cho SL",
                                      IctMssPhaseText(g_ictLowTf.mss.phase));
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

   g_ictLowTf.mss.pendingTicket = ticket;
   g_ictLowTf.mss.pendingEntry  = entry;
   g_ictLowTf.mss.pendingSl     = sl;
   g_ictLowTf.mss.pendingTp     = tp;
   g_ictLowTf.mss.displayReason = StringFormat("Sell/Buy limit %.2f | SL %.2f (H0/L0) | TP %.2f RR%.1f",
                                   entry, sl, tp, rr);
}

#endif
