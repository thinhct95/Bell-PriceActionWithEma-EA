//+------------------------------------------------------------------+
//| Draw.mqh — label swing theo TF chart hiện tại                      |
//| Chart lớn (D1): b* | Chart H1: b*+i* | Chart M5: b*+i*+H0–L1      |
//+------------------------------------------------------------------+
#ifndef ICT2026_DRAW_MQH
#define ICT2026_DRAW_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/Swing.mqh>
#include <ICT2026/IntradayStructure.mqh>

const string ICT26_DRAW_PFX = "ICT26_DR_";

int IctDraw_ChartPeriodSeconds()
{
   return (int)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
}

// Chỉ vẽ swing TF hiện tại + TF lớn hơn; ẩn swing TF nhỏ hơn chart
void IctDraw_ResolveSwingVisibility(bool &showBias, bool &showIntra, bool &showConfirm)
{
   showBias    = false;
   showIntra   = false;
   showConfirm = false;

   const int chartSec   = IctDraw_ChartPeriodSeconds();
   const int biasSec    = (int)PeriodSeconds(InpBiasTf);
   const int intraSec   = (int)PeriodSeconds(InpIntradayTf);
   const int confirmSec = (int)PeriodSeconds(InpConfirmTf);

   if(chartSec <= 0 || biasSec <= 0 || intraSec <= 0 || confirmSec <= 0)
      return;

   showConfirm = (chartSec <= confirmSec);
   showIntra   = (chartSec <= intraSec);
   showBias    = (chartSec <= biasSec) || (chartSec >= biasSec);
}

void IctDraw_DeleteByPrefix(const string prefix)
{
   const long ch = ChartID();
   for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
   {
      const string name = ObjectName(ch, i, 0, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(ch, name);
   }
}

void IctDraw_Clear()
{
   const long ch = ChartID();
   IctDraw_DeleteByPrefix(ICT26_DRAW_PFX);
   ObjectDelete(ch, ICT26_DRAW_PFX + "TXT_DAILY");
   ObjectDelete(ch, ICT26_DRAW_PFX + "TXT_INTRA");
}

void IctDraw_SwingLabel(const string id, const string text,
                        const datetime t, const double price,
                        const bool isHigh, const color clr)
{
   const long ch = ChartID();
   if(ObjectFind(ch, id) < 0)
      ObjectCreate(ch, id, OBJ_TEXT, 0, t, price);
   ObjectMove(ch, id, 0, t, price);
   ObjectSetString(ch, id, OBJPROP_TEXT, text);
   ObjectSetInteger(ch, id, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, id, OBJPROP_FONTSIZE, InpChartLabelFontSize);
   ObjectSetString(ch, id, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(ch, id, OBJPROP_ANCHOR, isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
   ObjectSetInteger(ch, id, OBJPROP_SELECTABLE, false);
}

void IctDraw_SwingSet(const string objPfx, const string tagPfx,
                      IctSwingSet &sw,
                      const color clrHi, const color clrLo)
{
   if(!sw.IsComplete())
      return;

   IctDraw_SwingLabel(objPfx + tagPfx + "H0", tagPfx + "H0",
                      sw.h0.time, sw.h0.price, true, clrHi);
   IctDraw_SwingLabel(objPfx + tagPfx + "H1", tagPfx + "H1",
                      sw.h1.time, sw.h1.price, true, clrHi);
   IctDraw_SwingLabel(objPfx + tagPfx + "L0", tagPfx + "L0",
                      sw.l0.time, sw.l0.price, false, clrLo);
   IctDraw_SwingLabel(objPfx + tagPfx + "L1", tagPfx + "L1",
                      sw.l1.time, sw.l1.price, false, clrLo);
}

bool IctDraw_BuildConfirmSwings(const string sym, IctSwingSet &sw)
{
   ENUM_ICT_STRUCT structural = ICT_STRUCT_NONE;
   return IctBuildConfirmSwingSet(sym, sw, structural);
}

void IctDraw_Render(const string sym)
{
   if(!InpDrawChartLabels)
   {
      IctDraw_Clear();
      return;
   }

   IctDraw_Clear();

   bool showBias = false, showIntra = false, showConfirm = false;
   IctDraw_ResolveSwingVisibility(showBias, showIntra, showConfirm);

   const string p = ICT26_DRAW_PFX;

   if(InpDrawBiasSwingLabels && showBias && g_ictDailyBias.swings.IsComplete())
   {
      IctSwingSet biasSw = g_ictDailyBias.swings;
      IctDraw_SwingSet(p, "b", biasSw, clrGold, clrKhaki);
   }

   if(InpDrawIntraSwingLabels && showIntra && g_ictIntraday.swings.IsComplete())
   {
      IctSwingSet intraSw = g_ictIntraday.swings;
      IctDraw_SwingSet(p, "i", intraSw, clrDodgerBlue, clrOrange);
   }

   if(InpDrawConfirmLabels && showConfirm)
   {
      IctSwingSet confirmSw;
      if(IctDraw_BuildConfirmSwings(sym, confirmSw))
         IctDraw_SwingSet(p, "", confirmSw, clrLightGreen, clrLightCoral);
   }

   ChartRedraw();
}

#endif
