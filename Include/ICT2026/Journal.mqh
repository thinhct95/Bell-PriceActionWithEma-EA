//+------------------------------------------------------------------+
//| Journal.mqh — log MSS pipeline + entry block reasons (de-dup)    |
//+------------------------------------------------------------------+
//| Log lên Experts Journal kèm de-dup (cùng reason consecutive →    |
//| skip) để journal không spam khi pipeline đứng yên.                |
//|                                                                   |
//| Skip nếu: InpOnlyStatsMode = true (silent tester mode v1.162)    |
//|                                                                   |
//| 2 channels:                                                       |
//|   IctMss_JournalPipeline(reason) — phase transition / wait        |
//|   IctMss_JournalEntryBlock(reason) — lý do block không entry      |
//|   IctMss_JournalReset() — reset cache khi setup reset             |
//|                                                                   |
//| Globals owned:                                                    |
//|   g_ictMssJournalLast       — cache last pipeline reason          |
//|   g_ictMssEntryJournalLast  — cache last block reason             |
//|                                                                   |
//| Helper:                                                           |
//|   IctMss_IsEntryReadyReason(reason) — true nếu reason hợp lệ      |
//|     (không thuộc "block" — e.g. "READY", "Limit placed")          |
//+------------------------------------------------------------------+
#ifndef ICT2026_JOURNAL_MQH
#define ICT2026_JOURNAL_MQH

#include <ICT2026/Config.mqh>

string g_ictMssJournalLast   = "";
string g_ictMssEntryJournalLast = "";

bool IctMss_IsEntryReadyReason(const string reason)
{
   if(StringFind(reason, "READY") == 0)
      return true;
   if(StringFind(reason, "Limit ") >= 0)
      return true;
   if(StringFind(reason, "Sell/Buy limit") >= 0)
      return true;
   return false;
}

void IctMss_JournalPipeline(const string reason)
{
   if(InpOnlyStatsMode)
      return;
   if(!InpMssLogJournal)
      return;
   if(IctMss_IsEntryReadyReason(reason))
      return;
   if(reason == g_ictMssJournalLast)
      return;

   g_ictMssJournalLast = reason;
   PrintFormat("[ICT2026/MSS] %s", reason);
}

void IctMss_JournalEntryBlock(const string reason)
{
   if(InpOnlyStatsMode)
      return;
   if(!InpMssLogJournal)
      return;
   if(reason == g_ictMssEntryJournalLast)
      return;

   g_ictMssEntryJournalLast = reason;
   PrintFormat("[ICT2026/Entry] Chặn lệnh: %s", reason);
}

void IctMss_JournalReset()
{
   g_ictMssJournalLast      = "";
   g_ictMssEntryJournalLast = "";
}

#endif
