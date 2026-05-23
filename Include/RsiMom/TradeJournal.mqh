//+------------------------------------------------------------------+
//| TradeJournal.mqh — CSV lệnh đóng + tổng hợp tháng (RsiMomentumEA)|
//+------------------------------------------------------------------+
#ifndef RSI_MOM_TRADE_JOURNAL_MQH
#define RSI_MOM_TRADE_JOURNAL_MQH

struct RsiMomMonthRow
{
   string ym;
   int    trades;
   int    wins;
   int    losses;
   double netProfit;
   double grossProfit;
   double grossLoss;
   int    slCount;
   int    tpCount;
   int    otherCount;
};

int g_rsiMomJournalHandle = INVALID_HANDLE;
RsiMomMonthRow g_rsiMomMonths[];
int g_rsiMomMonthCount = 0;

string RsiMomJournal_TradesPath(const string sym, const ENUM_TIMEFRAMES tf)
{
   return StringFormat("RsiMomEA\\journal_%s_%s.csv", sym, EnumToString(tf));
}

string RsiMomJournal_SummaryPath(const string sym, const ENUM_TIMEFRAMES tf)
{
   return StringFormat("RsiMomEA\\summary_%s_%s.csv", sym, EnumToString(tf));
}

int RsiMomJournal_FindMonth(const string ym)
{
   for(int i = 0; i < g_rsiMomMonthCount; i++)
   {
      if(g_rsiMomMonths[i].ym == ym)
         return i;
   }
   return -1;
}

void RsiMomJournal_AddMonth(const string ym, const double profit, const string exitTag)
{
   int idx = RsiMomJournal_FindMonth(ym);
   if(idx < 0)
   {
      idx = g_rsiMomMonthCount;
      g_rsiMomMonthCount++;
      ArrayResize(g_rsiMomMonths, g_rsiMomMonthCount);
      g_rsiMomMonths[idx].ym = ym;
      g_rsiMomMonths[idx].trades = 0;
      g_rsiMomMonths[idx].wins = 0;
      g_rsiMomMonths[idx].losses = 0;
      g_rsiMomMonths[idx].netProfit = 0.0;
      g_rsiMomMonths[idx].grossProfit = 0.0;
      g_rsiMomMonths[idx].grossLoss = 0.0;
      g_rsiMomMonths[idx].slCount = 0;
      g_rsiMomMonths[idx].tpCount = 0;
      g_rsiMomMonths[idx].otherCount = 0;
   }

   RsiMomMonthRow r = g_rsiMomMonths[idx];
   r.trades++;
   r.netProfit += profit;
   if(profit > 0.0)
   {
      r.wins++;
      r.grossProfit += profit;
   }
   else if(profit < 0.0)
   {
      r.losses++;
      r.grossLoss += profit;
   }

   if(exitTag == "SL")
      r.slCount++;
   else if(exitTag == "TP")
      r.tpCount++;
   else
      r.otherCount++;

   g_rsiMomMonths[idx] = r;
}

bool RsiMomJournal_DeleteIfExists(const string path)
{
   if(!FileIsExist(path, FILE_COMMON))
      return false;
   return FileDelete(path, FILE_COMMON);
}

bool RsiMomJournal_ResetFiles(const string sym, const ENUM_TIMEFRAMES tf)
{
   RsiMomJournal_CloseFiles();
   RsiMomJournal_DeleteIfExists(RsiMomJournal_TradesPath(sym, tf));
   RsiMomJournal_DeleteIfExists(RsiMomJournal_SummaryPath(sym, tf));
   return true;
}

bool RsiMomJournal_OpenTrades(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(g_rsiMomJournalHandle != INVALID_HANDLE)
      return true;

   FolderCreate("RsiMomEA", FILE_COMMON);
   const string path = RsiMomJournal_TradesPath(sym, tf);
   const bool exists = FileIsExist(path, FILE_COMMON);

   g_rsiMomJournalHandle = FileOpen(path, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
   if(g_rsiMomJournalHandle == INVALID_HANDLE)
   {
      Print("[RsiMomEA] Journal: không mở file ", path, " err=", GetLastError());
      return false;
   }

   if(!exists || FileSize(g_rsiMomJournalHandle) == 0)
   {
      FileWrite(g_rsiMomJournalHandle,
                "close_time", "year_month", "profit", "dir", "exit",
                "entry_time", "entry_price", "sl", "tp", "volume",
                "risk_pts", "profit_r",
                "rsi", "wma45", "ema200", "close_entry", "above_ema200",
                "atr", "atr_ratio", "atr_exp_ok",
                "session_ok", "spread_pts",
                "symbol", "timeframe", "magic");
   }
   else
   {
      FileSeek(g_rsiMomJournalHandle, 0, SEEK_END);
   }
   return true;
}

void RsiMomJournal_CloseFiles()
{
   if(g_rsiMomJournalHandle != INVALID_HANDLE)
   {
      FileClose(g_rsiMomJournalHandle);
      g_rsiMomJournalHandle = INVALID_HANDLE;
   }
}

bool RsiMomJournal_Copy1(const int handle, const int shift, double &v)
{
   v = 0.0;
   if(handle == INVALID_HANDLE || shift < 0)
      return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1)
      return false;
   v = buf[0];
   return true;
}

bool RsiMomJournal_AtrRatioAt(const int hAtr, const int shift,
                             const int cmpBars, const double minRatio,
                             double &atrNow, double &ratio, bool &expOk)
{
   atrNow = 0.0;
   ratio = 0.0;
   expOk = false;
   double atrRef = 0.0;
   if(!RsiMomJournal_Copy1(hAtr, shift, atrNow) || !RsiMomJournal_Copy1(hAtr, shift + cmpBars, atrRef))
      return false;
   if(atrRef <= 0.0)
      return false;
   ratio = atrNow / atrRef;
   expOk = (ratio >= MathMax(1.0, minRatio) - 1e-8);
   return true;
}

string RsiMomJournal_ExitTag(const long dealReason, const double profit)
{
   if(dealReason == DEAL_REASON_SL)
      return "SL";
   if(dealReason == DEAL_REASON_TP)
      return "TP";
   if(profit >= 0.0)
      return "WIN";
   return "LOSS";
}

bool RsiMomJournal_FindEntryDeal(const ulong positionId,
                                 ulong &entryDeal,
                                 datetime &entryTime,
                                 long &posType,
                                 double &entryPrice,
                                 double &sl,
                                 double &tp,
                                 double &volume)
{
   entryDeal = 0;
   entryTime = 0;
   posType = 0;
   entryPrice = sl = tp = volume = 0.0;

   if(positionId == 0 || !HistorySelectByPosition(positionId))
      return false;

   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0 || !HistoryDealSelect(d))
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      entryDeal = d;
      entryTime = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      posType = HistoryDealGetInteger(d, DEAL_TYPE);
      entryPrice = HistoryDealGetDouble(d, DEAL_PRICE);
      volume = HistoryDealGetDouble(d, DEAL_VOLUME);

      const ulong orderTicket = (ulong)HistoryDealGetInteger(d, DEAL_ORDER);
      if(orderTicket > 0 && HistoryOrderSelect(orderTicket))
      {
         sl = HistoryOrderGetDouble(orderTicket, ORDER_SL);
         tp = HistoryOrderGetDouble(orderTicket, ORDER_TP);
      }
      return true;
   }
   return false;
}

void RsiMomJournal_WriteSummary(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(g_rsiMomMonthCount <= 0)
      return;

   const string path = RsiMomJournal_SummaryPath(sym, tf);
   const int h = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
   {
      Print("[RsiMomEA] Summary CSV lỗi ", path, " err=", GetLastError());
      return;
   }

   FileWrite(h,
             "year_month", "trades", "wins", "losses", "winrate_pct",
             "net_profit", "gross_profit", "gross_loss", "avg_profit",
             "sl_count", "tp_count", "other_count");

   for(int i = 0; i < g_rsiMomMonthCount; i++)
   {
      const RsiMomMonthRow r = g_rsiMomMonths[i];
      double winrate = 0.0;
      if(r.trades > 0)
         winrate = 100.0 * (double)r.wins / (double)r.trades;
      const double avg = (r.trades > 0) ? r.netProfit / (double)r.trades : 0.0;

      FileWrite(h,
                r.ym,
                IntegerToString(r.trades),
                IntegerToString(r.wins),
                IntegerToString(r.losses),
                DoubleToString(winrate, 2),
                DoubleToString(r.netProfit, 2),
                DoubleToString(r.grossProfit, 2),
                DoubleToString(r.grossLoss, 2),
                DoubleToString(avg, 2),
                IntegerToString(r.slCount),
                IntegerToString(r.tpCount),
                IntegerToString(r.otherCount));
   }

   FileClose(h);
   Print("[RsiMomEA] Summary CSV → ", path, " (FILE_COMMON, ", g_rsiMomMonthCount, " tháng)");
}

void RsiMomJournal_ResetMonths()
{
   ArrayResize(g_rsiMomMonths, 0);
   g_rsiMomMonthCount = 0;
}

void RsiMomJournal_OnDeinit(const string sym, const ENUM_TIMEFRAMES tf)
{
   RsiMomJournal_WriteSummary(sym, tf);
   RsiMomJournal_CloseFiles();
}

void RsiMomJournal_RecordClosedDeal(const ulong dealOut,
                                    const string sym,
                                    const ENUM_TIMEFRAMES tf,
                                    const ulong magic,
                                    const int hRsi,
                                    const int hWma45,
                                    const int hEma200,
                                    const int hAtrRegime,
                                    const int atrCmpBars,
                                    const double atrMinRatio,
                                    const int sessionOkAtEntry)
{
   if(dealOut == 0 || !HistoryDealSelect(dealOut))
      return;
   if(HistoryDealGetString(dealOut, DEAL_SYMBOL) != sym)
      return;
   if((ulong)HistoryDealGetInteger(dealOut, DEAL_MAGIC) != magic)
      return;
   if(HistoryDealGetInteger(dealOut, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   if(!RsiMomJournal_OpenTrades(sym, tf))
      return;

   const ulong posId = (ulong)HistoryDealGetInteger(dealOut, DEAL_POSITION_ID);
   ulong entryDeal = 0;
   datetime entryTime = 0;
   long posType = 0;
   double entryPrice = 0.0, sl = 0.0, tp = 0.0, volume = 0.0;
   if(!RsiMomJournal_FindEntryDeal(posId, entryDeal, entryTime, posType,
                                  entryPrice, sl, tp, volume))
   {
      Print("[RsiMomEA] Journal: không tìm entry pos=", posId);
      return;
   }

   const int entryShift = iBarShift(sym, tf, entryTime, true);
   if(entryShift < 1)
   {
      Print("[RsiMomEA] Journal: entry shift invalid ", TimeToString(entryTime));
      return;
   }

   const int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double rsi = 0.0, wma = 0.0, ema200 = 0.0, atrNow = 0.0, atrRatio = 0.0;
   bool atrExpOk = false;
   RsiMomJournal_Copy1(hRsi, entryShift, rsi);
   RsiMomJournal_Copy1(hWma45, entryShift, wma);
   RsiMomJournal_Copy1(hEma200, entryShift, ema200);
   RsiMomJournal_AtrRatioAt(hAtrRegime, entryShift, atrCmpBars, atrMinRatio,
                            atrNow, atrRatio, atrExpOk);

   const double closeEntry = iClose(sym, tf, entryShift);
   const int aboveEma = (ema200 > 0.0 && closeEntry > ema200) ? 1 : 0;

   const int sessionOk = (sessionOkAtEntry != 0) ? 1 : 0;
   const int spreadPts = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);

   double riskPts = 0.0;
   if(posType == DEAL_TYPE_BUY && sl > 0.0)
      riskPts = (entryPrice - sl) / _Point;
   else if(posType == DEAL_TYPE_SELL && sl > 0.0)
      riskPts = (sl - entryPrice) / _Point;
   if(riskPts < 0.0)
      riskPts = 0.0;

   const datetime closeTime = (datetime)HistoryDealGetInteger(dealOut, DEAL_TIME);
   MqlDateTime dt;
   TimeToStruct(closeTime, dt);
   const string yearMonth = StringFormat("%04d-%02d", dt.year, dt.mon);

   const double profit = HistoryDealGetDouble(dealOut, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealOut, DEAL_SWAP)
                       + HistoryDealGetDouble(dealOut, DEAL_COMMISSION);
   const long dealReason = HistoryDealGetInteger(dealOut, DEAL_REASON);
   const string exitTag = RsiMomJournal_ExitTag(dealReason, profit);
   const string dir = (posType == DEAL_TYPE_BUY) ? "BUY" : "SELL";

   double profitR = 0.0;
   if(riskPts > 0.0)
   {
      const double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      const double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(tickSz > 0.0 && tickVal > 0.0)
      {
         const double riskMoney = (riskPts * _Point / tickSz) * tickVal * volume;
         if(riskMoney > 0.0)
            profitR = profit / riskMoney;
      }
   }

   RsiMomJournal_AddMonth(yearMonth, profit, exitTag);

   FileWrite(g_rsiMomJournalHandle,
             TimeToString(closeTime, TIME_DATE | TIME_MINUTES),
             yearMonth,
             DoubleToString(profit, 2),
             dir,
             exitTag,
             TimeToString(entryTime, TIME_DATE | TIME_MINUTES),
             DoubleToString(entryPrice, dig),
             DoubleToString(sl, dig),
             DoubleToString(tp, dig),
             DoubleToString(volume, 2),
             DoubleToString(riskPts, 1),
             DoubleToString(profitR, 3),
             DoubleToString(rsi, 2),
             DoubleToString(wma, dig),
             DoubleToString(ema200, dig),
             DoubleToString(closeEntry, dig),
             IntegerToString(aboveEma),
             DoubleToString(atrNow, dig),
             DoubleToString(atrRatio, 4),
             IntegerToString(atrExpOk ? 1 : 0),
             IntegerToString(sessionOk),
             IntegerToString(spreadPts),
             sym,
             EnumToString(tf),
             IntegerToString((int)magic));

   FileFlush(g_rsiMomJournalHandle);
}

#endif
