//+------------------------------------------------------------------+
//| Stats.mqh — thống kê lệnh MSS từ history (theo magic)             |
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

   // Pass 2: tính R cho từng deal (mỗi lần gọi sẽ thay selection — không ảnh hưởng vì đã cache xong).
   for(int k = 0; k < cached; k++)
   {
      const double r = IctMssStats_ComputeR(outTickets[k]);

      g_ictMssStats.total++;
      g_ictMssStats.netProfit += nets[k];
      g_ictMssStats.sumR      += r;

      const ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)reasons[k];
      if(rs == DEAL_REASON_TP)
         g_ictMssStats.tpCount++;
      else if(rs == DEAL_REASON_SL)
         g_ictMssStats.slCount++;
      else
         g_ictMssStats.otherCount++;

      if(nets[k] > 0.0)
         g_ictMssStats.winCount++;
      else if(nets[k] < 0.0)
         g_ictMssStats.lossCount++;
   }

   g_ictMssStatsLastScan = TimeCurrent();

   if(InpMssLogJournal)
      PrintFormat("[ICT2026/Stats] Recompute %s magic=%I64u | total=%d TP=%d SL=%d khác=%d | net=%.2f sumR=%.2f",
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
   if(g_ictMssStats.total <= 0)
      return 0.0;
   return g_ictMssStats.sumR / (double)g_ictMssStats.total;
}

string IctMssStats_LineCounts()
{
   return StringFormat("Stats: %d lệnh | TP %d | SL %d | khác %d",
                       g_ictMssStats.total,
                       g_ictMssStats.tpCount,
                       g_ictMssStats.slCount,
                       g_ictMssStats.otherCount);
}

string IctMssStats_LinePerf()
{
   const double wr = IctMssStats_WinratePct();
   const double ar = IctMssStats_AvgR();
   return StringFormat("WR %.1f%% | Ravg %+.2fR | Net %+.2f",
                       wr, ar, g_ictMssStats.netProfit);
}

#endif
