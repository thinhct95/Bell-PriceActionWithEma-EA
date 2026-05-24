//+------------------------------------------------------------------+
//| ConfirmFvg.mqh — FVG trên Confirm TF (M5) cho MSS entry          |
//+------------------------------------------------------------------+
#ifndef ICT2026_CONFIRMFVG_MQH
#define ICT2026_CONFIRMFVG_MQH

#include <ICT2026/Fvg.mqh>

IctFvgZone   g_ictConfirmFvgZones[];
int          g_ictConfirmFvgCount = 0;
static ulong g_ictConfirmFvgNextId  = 100000;

void IctConfirmFvg_Reset()
{
   g_ictConfirmFvgCount = 0;
   ArrayResize(g_ictConfirmFvgZones, 0);
}

bool IctConfirmFvg_IsDuplicate(const datetime createdTime, const double upper, const double lower)
{
   const double tol = _Point * 2.0;
   for(int i = 0; i < g_ictConfirmFvgCount; i++)
   {
      if(g_ictConfirmFvgZones[i].createdTime != createdTime)
         continue;
      if(MathAbs(g_ictConfirmFvgZones[i].upper - upper) <= tol &&
         MathAbs(g_ictConfirmFvgZones[i].lower - lower) <= tol)
         return true;
   }
   return false;
}

void IctConfirmFvg_AddZone(const IctFvgZone &zone)
{
   if(g_ictConfirmFvgCount >= InpFvgMaxZones)
   {
      for(int i = 0; i < g_ictConfirmFvgCount - 1; i++)
         g_ictConfirmFvgZones[i] = g_ictConfirmFvgZones[i + 1];
      g_ictConfirmFvgCount--;
   }
   ArrayResize(g_ictConfirmFvgZones, g_ictConfirmFvgCount + 1);
   g_ictConfirmFvgZones[g_ictConfirmFvgCount] = zone;
   g_ictConfirmFvgCount++;
}

void IctConfirmFvg_UpdateAll(const string sym, const ENUM_TIMEFRAMES tf)
{
   for(int i = 0; i < g_ictConfirmFvgCount; i++)
      IctFvg_UpdateZoneState(sym, tf, g_ictConfirmFvgZones[i]);
}

void IctConfirmFvg_ScanNew(const string sym, const ENUM_TIMEFRAMES tf,
                           const ENUM_ICT_FVG_SIDE wantSide,
                           const datetime notBefore,
                           const bool fullLookback = false)
{
   if(wantSide == ICT_FVG_NONE)
      return;

   const int maxShift = MathMin(InpMssConfirmFvgBars, Bars(sym, tf) - 3);
   if(maxShift < 1)
      return;

   int fromSh = fullLookback ? maxShift : MathMin(maxShift, MathMax(1, InpFvgScanBarsPerUpdate));

   for(int sh = fromSh; sh >= 1; sh--)
   {
      ENUM_ICT_FVG_SIDE side = ICT_FVG_NONE;
      double upper = 0.0, lower = 0.0;
      datetime timeA = 0, timeC = 0;

      if(!IctFvg_TryDetectAtShift(sym, tf, sh, wantSide, side, upper, lower, timeA, timeC))
         continue;
      if(notBefore > 0 && timeC < notBefore)
         continue;
      if(IctConfirmFvg_IsDuplicate(timeC, upper, lower))
         continue;

      IctFvgZone zone;
      zone.Clear();
      zone.id          = g_ictConfirmFvgNextId++;
      zone.side        = side;
      zone.state       = ICT_FVG_AVAILABLE;
      zone.upper       = upper;
      zone.lower       = lower;
      zone.createdTime = timeC;
      zone.timeStart   = timeA;
      zone.expireTime  = timeC + (datetime)(InpFvgExpireDays * 86400);
      zone.locked      = true;
      IctFvg_UpdateZoneState(sym, tf, zone);
      IctConfirmFvg_AddZone(zone);

      if(InpDebug)
         PrintFormat("[ICT2026/CFVG] New %s [%.2f – %.2f] @ %s",
                     IctFvgSideText(zone.side), zone.lower, zone.upper,
                     TimeToString(timeC, TIME_DATE | TIME_MINUTES));
   }
}

int IctConfirmFvg_FindLatestAfter(const datetime notBefore, const ENUM_ICT_FVG_SIDE side)
{
   int    bestIdx = -1;
   datetime bestT = 0;

   for(int i = 0; i < g_ictConfirmFvgCount; i++)
   {
      if(g_ictConfirmFvgZones[i].side != side)
         continue;
      if(notBefore > 0 && g_ictConfirmFvgZones[i].createdTime < notBefore)
         continue;
      if(g_ictConfirmFvgZones[i].createdTime >= bestT)
      {
         bestT   = g_ictConfirmFvgZones[i].createdTime;
         bestIdx = i;
      }
   }
   return bestIdx;
}

int IctConfirmFvg_FindById(const ulong id)
{
   for(int i = 0; i < g_ictConfirmFvgCount; i++)
      if(g_ictConfirmFvgZones[i].id == id)
         return i;
   return -1;
}

#endif
