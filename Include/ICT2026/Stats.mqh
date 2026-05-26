//+------------------------------------------------------------------+
//| Stats.mqh — thống kê lệnh MSS từ HistoryDeals (theo magic)       |
//+------------------------------------------------------------------+
//| Quét HistoryDeals filter symbol + magic = InpMssMagic. Compute:   |
//|   total / tpCount / slCount / otherCount                          |
//|   winCount / lossCount / sumR / netProfit                         |
//|                                                                   |
//| v1.183 — chỉ TP/SL được đếm vào total/win/loss/sumR/tp/sl. Partial|
//| close / manual / EA-close → otherCount (chỉ log, không vào panel).|
//| netProfit cộng dồn TẤT CẢ deals (kể cả partial — P&L thực).       |
//| AvgR = sumR / (tpCount + slCount) — đồng nhất với cách đếm.       |
//|                                                                   |
//| 2-pass scan (v1.142 fix):                                         |
//|   Pass 1: chỉ collect ticket + reason + net (global selection còn |
//|           nguyên, không gọi HistorySelectByPosition)               |
//|   Pass 2: tính R cho từng ticket (mỗi call thay selection)        |
//|                                                                   |
//| R computation (ComputeR):                                         |
//|   R = (closePrice - entryPrice) / (entryPrice - slPrice)  for BUY |
//|     = (entryPrice - closePrice) / (slPrice - entryPrice)  for SELL|
//|   entryPrice + slPrice lấy từ DEAL_ENTRY_IN + ORDER_SL của        |
//|   position.                                                       |
//|                                                                   |
//| Globals owned:                                                    |
//|   g_ictMssStats           — IctMssStats struct                    |
//|   g_ictMssStatsLastScan   — TS scan gần nhất (debounce)           |
//|                                                                   |
//| Public API:                                                       |
//|   void IctMssStats_Recompute(sym, magic)                          |
//|   double IctMssStats_WinratePct() / IctMssStats_AvgR()            |
//|   string IctMssStats_LineCounts() / IctMssStats_LinePerf()        |
//+------------------------------------------------------------------+
#ifndef ICT2026_STATS_MQH
#define ICT2026_STATS_MQH

#include <ICT2026/Config.mqh>

struct IctMssStats
{
   int    total;
   int    tpCount;
   int    slCount;
   int    otherCount;   // manual / expert / mobile / web
   int    winCount;     // profit > 0
   int    lossCount;    // profit < 0
   double sumR;         // tổng R đạt được (đã quy chuẩn theo risk lúc vào lệnh)
   double netProfit;

   void Clear()
   {
      total = tpCount = slCount = otherCount = 0;
      winCount = lossCount = 0;
      sumR = 0.0;
      netProfit = 0.0;
   }
};

IctMssStats g_ictMssStats;
static datetime g_ictMssStatsLastScan = 0;

double IctMssStats_ComputeR(const ulong outDeal)
{
   const ulong posId = (ulong)HistoryDealGetInteger(outDeal, DEAL_POSITION_ID);
   const double closePrice = HistoryDealGetDouble(outDeal, DEAL_PRICE);
   if(posId == 0 || closePrice <= 0.0)
      return 0.0;

   if(!HistorySelectByPosition(posId))
      return 0.0;

   double entryPrice = 0.0;
   double slPrice    = 0.0;
   bool   isBuy      = false;

   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID) != posId)
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      entryPrice = HistoryDealGetDouble(d, DEAL_PRICE);
      isBuy = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY);

      const ulong orderTicket = (ulong)HistoryDealGetInteger(d, DEAL_ORDER);
      if(orderTicket > 0 && HistoryOrderSelect(orderTicket))
         slPrice = HistoryOrderGetDouble(orderTicket, ORDER_SL);
      break;
   }

   if(entryPrice <= 0.0 || slPrice <= 0.0)
      return 0.0;

   const double risk = isBuy ? (entryPrice - slPrice) : (slPrice - entryPrice);
   if(risk <= _Point)
      return 0.0;

   const double move = isBuy ? (closePrice - entryPrice) : (entryPrice - closePrice);
   return move / risk;
}

void IctMssStats_Recompute(const string sym, const ulong magic)
{
   g_ictMssStats.Clear();

   if(!HistorySelect(0, TimeCurrent()))
      return;

   // Pass 1: thu thập ticket + dữ liệu cơ bản trong khi global history selection còn nguyên.
   // Lưu ý: nếu gọi HistorySelectByPosition (trong ComputeR) ở đây → selection bị thay,
   // các index sau sẽ đọc từ history của 1 position → đếm thiếu lệnh.
   ulong  outTickets[];
   long   reasons[];
   double nets[];
   int    cached = 0;

   const int n = HistoryDealsTotal();
   ArrayResize(outTickets, n);
   ArrayResize(reasons, n);
   ArrayResize(nets, n);

   for(int i = 0; i < n; i++)
   {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != sym)
         continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != magic)
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      outTickets[cached] = d;
      reasons[cached]    = HistoryDealGetInteger(d, DEAL_REASON);
      nets[cached]       = HistoryDealGetDouble(d, DEAL_PROFIT)
                         + HistoryDealGetDouble(d, DEAL_SWAP)
                         + HistoryDealGetDouble(d, DEAL_COMMISSION);
      cached++;
   }

   // Pass 2: chỉ tính TP/SL vào stats. Partial close / manual close
   // không phải kết quả lệnh ⇒ skip total/tp/sl/win/loss/sumR.
   // netProfit vẫn cộng dồn TẤT CẢ deals để phản ánh đúng P&L thực tế.
   for(int k = 0; k < cached; k++)
   {
      g_ictMssStats.netProfit += nets[k];

      const ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)reasons[k];
      const bool isTp = (rs == DEAL_REASON_TP);
      const bool isSl = (rs == DEAL_REASON_SL);
      if(!isTp && !isSl)
      {
         g_ictMssStats.otherCount++;
         continue;
      }

      const double r = IctMssStats_ComputeR(outTickets[k]);
      g_ictMssStats.total++;
      g_ictMssStats.sumR += r;
      if(isTp)
         g_ictMssStats.tpCount++;
      else
         g_ictMssStats.slCount++;

      if(nets[k] > 0.0)
         g_ictMssStats.winCount++;
      else if(nets[k] < 0.0)
         g_ictMssStats.lossCount++;
   }

   g_ictMssStatsLastScan = TimeCurrent();

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/Stats] Recompute %s magic=%I64u | total=%d TP=%d SL=%d (skip khác=%d) | net=%.2f sumR=%.2f",
                  sym, magic,
                  g_ictMssStats.total, g_ictMssStats.tpCount,
                  g_ictMssStats.slCount, g_ictMssStats.otherCount,
                  g_ictMssStats.netProfit, g_ictMssStats.sumR);
}

double IctMssStats_WinratePct()
{
   const int decided = g_ictMssStats.tpCount + g_ictMssStats.slCount;
   if(decided == 0)
      return 0.0;
   return 100.0 * (double)g_ictMssStats.tpCount / (double)decided;
}

double IctMssStats_AvgR()
{
   const int decided = g_ictMssStats.tpCount + g_ictMssStats.slCount;
   if(decided <= 0)
      return 0.0;
   return g_ictMssStats.sumR / (double)decided;
}

string IctMssStats_LineCounts()
{
   return StringFormat("Stats: %d lệnh | TP %d | SL %d",
                       g_ictMssStats.total,
                       g_ictMssStats.tpCount,
                       g_ictMssStats.slCount);
}

string IctMssStats_LinePerf()
{
   const double wr = IctMssStats_WinratePct();
   const double ar = IctMssStats_AvgR();
   return StringFormat("WR %.1f%% | Ravg %+.2fR | Net %+.2f",
                       wr, ar, g_ictMssStats.netProfit);
}

#endif
