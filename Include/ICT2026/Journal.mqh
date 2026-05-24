//+------------------------------------------------------------------+
//| Journal.mqh — log lý do chặn MSS/entry vào Experts journal        |
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
