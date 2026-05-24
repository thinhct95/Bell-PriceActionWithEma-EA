//+------------------------------------------------------------------+
//| FvgDraw.mqh — vẽ iTF FVG + Premium/Discount trên chart           |
//+------------------------------------------------------------------+
#ifndef ICT2026_FVGDRAW_MQH
#define ICT2026_FVGDRAW_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Fvg.mqh>

const string ICT26_FVG_PFX = "ICT26_FVG_";

void IctFvgDraw_DeleteAll()
{
   const long ch = ChartID();
   for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
   {
      const string name = ObjectName(ch, i, 0, -1);
      if(StringFind(name, ICT26_FVG_PFX) == 0)
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

void IctFvgDraw_Label(const string name, const datetime t, const double price,
                      const string text, const color clr)
{
   const long ch = ChartID();
   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_TEXT, 0, t, price);

   ObjectMove(ch, name, 0, t, price);
   ObjectSetString(ch, name, OBJPROP_TEXT, text);
   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, InpChartLabelFontSize);
   ObjectSetString(ch, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
}

void IctFvgDraw_Render(const string sym)
{
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

      string tag = StringFormat("iFVG %s %s", IctFvgSideText(g_ictFvgZones[i].side),
                                IctFvgStateText(g_ictFvgZones[i].state));
      if(g_ictFvgZones[i].pdZone != ICT_PD_NONE)
         tag += " " + IctPdZoneText(g_ictFvgZones[i].pdZone);

      IctFvgDraw_Label(pfx + "LBL", fvgEnd, g_ictFvgZones[i].upper, tag, fvgClr);
   }

   ChartRedraw();
}

#endif
