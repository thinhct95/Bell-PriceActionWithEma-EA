//+------------------------------------------------------------------+
//| FvgDraw.mqh — vẽ iTF FVG + Premium/Discount trên chart           |
//+------------------------------------------------------------------+
#ifndef ICT2026_FVGDRAW_MQH
#define ICT2026_FVGDRAW_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Fvg.mqh>
#include <ICT2026/ConfirmFvg.mqh>
#include <ICT2026/LowTfApi.mqh>

const string ICT26_FVG_PFX  = "ICT26_FVG_";
const string ICT26_CFVG_PFX = "ICT26_CFVG_";

void IctFvgDraw_DeleteAll()
{
   const long ch = ChartID();
   for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
   {
      const string name = ObjectName(ch, i, 0, -1);
      if(StringFind(name, ICT26_FVG_PFX) == 0 || StringFind(name, ICT26_CFVG_PFX) == 0)
         ObjectDelete(ch, name);
   }
}

void IctFvgDraw_Rect(const string name,
                     const datetime t1, const double p1,
                     const datetime t2, const double p2,
                     const color clr, const bool fill)
{
   const long ch = ChartID();
   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);

   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, name, OBJPROP_FILL, fill);
   ObjectSetInteger(ch, name, OBJPROP_BACK, true);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectMove(ch, name, 0, t1, p1);
   ObjectMove(ch, name, 1, t2, p2);
}

void IctFvgDraw_HLine(const string name, const datetime t1, const datetime t2,
                      const double price, const color clr, const ENUM_LINE_STYLE style)
{
   const long ch = ChartID();
   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_TREND, 0, t1, price, t2, price);

   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, name, OBJPROP_STYLE, style);
   ObjectSetInteger(ch, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(ch, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(ch, name, OBJPROP_BACK, true);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectMove(ch, name, 0, t1, price);
   ObjectMove(ch, name, 1, t2, price);
}

void IctFvgDraw_Render(const string sym)
{
   if(InpOnlyStatsMode)
      return;
   if(!InpDrawFvgZones)
   {
      IctFvgDraw_DeleteAll();
      return;
   }

   IctFvgDraw_DeleteAll();

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(!IctFvg_MatchesBias(g_ictFvgZones[i]))
         continue;

      const string id = IntegerToString((long)g_ictFvgZones[i].id);
      const string pfx = ICT26_FVG_PFX + id + "_";

      const datetime fvgStart = g_ictFvgZones[i].createdTime;
      const datetime fvgEnd   = IctFvg_GetFvgDrawTimeEnd(sym, InpFvgTf, g_ictFvgZones[i]);

      color fvgClr = (g_ictFvgZones[i].side == ICT_FVG_BULL) ? InpFvgBullColor : InpFvgBearColor;
      if(g_ictFvgZones[i].state == ICT_FVG_USED)
         fvgClr = InpFvgUsedColor;

      IctFvgDraw_Rect(pfx + "BOX", fvgStart, g_ictFvgZones[i].upper,
                      fvgEnd, g_ictFvgZones[i].lower, fvgClr, true);

      if(g_ictFvgZones[i].pdHigh > g_ictFvgZones[i].pdLow && g_ictFvgZones[i].pdEq > 0.0 &&
         g_ictFvgZones[i].pdRangeStart > 0)
      {
         const datetime pdStart = g_ictFvgZones[i].pdRangeStart;
         const datetime pdEnd   = IctFvg_GetPdDrawTimeEnd(g_ictFvgZones[i]);

         IctFvgDraw_Rect(pfx + "PD_PRE", pdStart, g_ictFvgZones[i].pdHigh,
                         pdEnd, g_ictFvgZones[i].pdEq, InpPdPremiumColor, true);
         IctFvgDraw_Rect(pfx + "PD_DIS", pdStart, g_ictFvgZones[i].pdEq,
                         pdEnd, g_ictFvgZones[i].pdLow, InpPdDiscountColor, true);
         IctFvgDraw_HLine(pfx + "PD_EQ", pdStart, pdEnd,
                          g_ictFvgZones[i].pdEq, clrWhite, STYLE_DOT);
      }
   }

   if(InpDrawConfirmFvg)
   {
      for(int j = 0; j < g_ictConfirmFvgCount; j++)
      {
         const string cid = IntegerToString((long)g_ictConfirmFvgZones[j].id);
         const string cpfx = ICT26_CFVG_PFX + cid + "_";
         const datetime cStart = g_ictConfirmFvgZones[j].createdTime;
         const datetime cEnd   = IctFvg_GetFvgDrawTimeEnd(sym, InpConfirmTf, g_ictConfirmFvgZones[j]);

         color cClr = (g_ictConfirmFvgZones[j].side == ICT_FVG_BULL) ?
                      clrDarkGreen : clrFireBrick;
         if(g_ictConfirmFvgZones[j].state == ICT_FVG_USED)
            cClr = InpFvgUsedColor;

         if(IctLowTf_MssM5FvgId() == g_ictConfirmFvgZones[j].id &&
            IctLowTf_MssPhase() >= ICT_MSS_M5_FVG)
            cClr = (g_ictConfirmFvgZones[j].side == ICT_FVG_BULL) ? clrAqua : clrOrange;

         IctFvgDraw_Rect(cpfx + "BOX", cStart, g_ictConfirmFvgZones[j].upper,
                         cEnd, g_ictConfirmFvgZones[j].lower, cClr, true);
      }
   }

   ChartRedraw();
}

#endif
