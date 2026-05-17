//+------------------------------------------------------------------+
//| Panel.mqh — nhãn trạng thái góc chart                            |
//+------------------------------------------------------------------+
#ifndef HYPERICT_PANEL_MQH
#define HYPERICT_PANEL_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/Classifier.mqh>

//+------------------------------------------------------------------+
class CPanel
{
public:
   static void Clear()
   {
      ObjectDelete(ChartID(), HICT_OBJ_PFX + "PANEL");
   }

   static void Render(HtfContext &ctx)
   {
      if(!InpDrawPanel)
      {
         Clear();
         return;
      }

      const long ch = ChartID();
      const string name = HICT_OBJ_PFX + "PANEL";

      string bias = "—";
      if(ctx.structBias == STRUCT_BULL) bias = "HH-HL";
      else if(ctx.structBias == STRUCT_BEAR) bias = "LH-LL";

      string txt = StringFormat("HyperICT | %s %s\n", ctx.symbol, EnumToString(ctx.htf));
      txt += StringFormat("Structure: %s | Fib: %s\n", bias, ctx.fibOk ? "OK" : "pending");
      txt += "State: " + CClassifier::StateText(ctx.state) + "\n";
      if(ctx.swings.IsComplete())
      {
         txt += StringFormat("H0=%.5f L0=%.5f | Key1=%.5f Key2=%.5f",
                             ctx.swings.h0.price, ctx.swings.l0.price,
                             ctx.keyLv1.price, ctx.keyLv2.price);
      }
      if(ctx.update.phase != UPD_PHASE_IDLE)
         txt += StringFormat("\nUpdate: evt=%d phase=%d | swingR=%d",
                             ctx.update.event, ctx.update.phase, InpSwingRange);

      if(ObjectFind(ch, name) < 0)
      {
         ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(ch, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetString(ch, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
      }
      ObjectSetInteger(ch, name, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(ch, name, OBJPROP_YDISTANCE, InpPanelY);
      ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, InpLabelFontSize + 1);
      ObjectSetInteger(ch, name, OBJPROP_COLOR, clrWhite);
      ObjectSetString(ch, name, OBJPROP_TEXT, txt);
   }
};

#endif // HYPERICT_PANEL_MQH
