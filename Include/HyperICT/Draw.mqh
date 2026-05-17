//+------------------------------------------------------------------+
//| Draw.mqh — labels H0–L1, vùng Key LV1/L2                         |
//+------------------------------------------------------------------+
#ifndef HYPERICT_DRAW_MQH
#define HYPERICT_DRAW_MQH

#include <HyperICT/Types.mqh>
#include <HyperICT/Config.mqh>
#include <HyperICT/KeyLevels.mqh>

//+------------------------------------------------------------------+
class CDraw
{
   static long Chart() { return ChartID(); }

   static color WithAlpha(const color clr, const uchar alpha)
   {
      return (color)((long)clr | ((long)alpha << 24));
   }

   static void DeleteByPrefix(const string prefix)
   {
      const long ch = Chart();
      for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
      {
         const string name = ObjectName(ch, i, 0, -1);
         if(StringFind(name, prefix) == 0)
            ObjectDelete(ch, name);
      }
   }

   static void DrawSwingLabel(const string id, const string text,
                              const datetime t, const double price,
                              const bool isHigh, const color clr)
   {
      const long ch = Chart();
      if(ObjectFind(ch, id) < 0)
         ObjectCreate(ch, id, OBJ_TEXT, 0, t, price);
      ObjectMove(ch, id, 0, t, price);
      ObjectSetString(ch, id, OBJPROP_TEXT, text);
      ObjectSetInteger(ch, id, OBJPROP_COLOR, clr);
      ObjectSetInteger(ch, id, OBJPROP_FONTSIZE, InpLabelFontSize);
      ObjectSetString(ch, id, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(ch, id, OBJPROP_ANCHOR, isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
      ObjectSetInteger(ch, id, OBJPROP_SELECTABLE, false);
   }

   static void DrawZoneRect(const string id,
                          const datetime t1, const double top, const double bottom,
                          const color fillClr, const string tip)
   {
      const long ch = Chart();
      const datetime t2 = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(t2 == 0) return;

      if(ObjectFind(ch, id) < 0)
         ObjectCreate(ch, id, OBJ_RECTANGLE, 0, t1, top, t2, bottom);
      ObjectMove(ch, id, 0, t1, top);
      ObjectMove(ch, id, 1, t2, bottom);
      ObjectSetInteger(ch, id, OBJPROP_COLOR, fillClr);
      ObjectSetInteger(ch, id, OBJPROP_FILL, true);
      ObjectSetInteger(ch, id, OBJPROP_BACK, true);
      ObjectSetInteger(ch, id, OBJPROP_SELECTABLE, false);
      ObjectSetString(ch, id, OBJPROP_TOOLTIP, tip);
   }

public:
   static void ClearAll()
   {
      DeleteByPrefix(HICT_OBJ_PFX);
   }

   static void Render(HtfContext &ctx)
   {
      if(!ctx.snapshotReady)
         return;

      const string p = HICT_OBJ_PFX;

      if(InpDrawSwings && ctx.swings.IsComplete())
      {
         DrawSwingLabel(p + "H0", "H0", ctx.swings.h0.time, ctx.swings.h0.price, true, InpClrBullHi);
         DrawSwingLabel(p + "H1", "H1", ctx.swings.h1.time, ctx.swings.h1.price, true, InpClrBullHi);
         DrawSwingLabel(p + "L0", "L0", ctx.swings.l0.time, ctx.swings.l0.price, false, InpClrBullLo);
         DrawSwingLabel(p + "L1", "L1", ctx.swings.l1.time, ctx.swings.l1.price, false, InpClrBullLo);

         if(ctx.update.newH0.Valid())
            DrawSwingLabel(p + "nH0", "newH0", ctx.update.newH0.time,
                           ctx.update.newH0.price, true, clrYellow);
         if(ctx.update.newL0.Valid())
            DrawSwingLabel(p + "nL0", "newL0", ctx.update.newL0.time,
                           ctx.update.newL0.price, false, clrYellow);
         if(ctx.update.newL02.Valid())
            DrawSwingLabel(p + "nL2", "newL02", ctx.update.newL02.time,
                           ctx.update.newL02.price, false, clrOrange);
      }

      if(!InpDrawZones)
         return;

      double top, bot;
      datetime tOb;

      if(ctx.keyLv1.zone.valid)
      {
         tOb = ctx.keyLv1.zone.obTime;
         const bool supply = (ctx.structBias == STRUCT_BULL);
         CKeyLevels::ZoneRectBounds(ctx.keyLv1.zone, supply, top, bot);
         DrawZoneRect(p + "Z_K1", tOb, top, bot,
                      WithAlpha(supply ? InpClrSupply : InpClrDemand, InpZoneFillAlpha),
                      "Key LV1");
      }

      if(ctx.keyLv2.zone.valid)
      {
         tOb = ctx.keyLv2.zone.obTime;
         const bool supply = (ctx.structBias == STRUCT_BEAR);
         CKeyLevels::ZoneRectBounds(ctx.keyLv2.zone, supply, top, bot);
         DrawZoneRect(p + "Z_K2", tOb, top, bot,
                      WithAlpha(supply ? InpClrSupply : InpClrDemand, InpZoneFillAlpha),
                      "Key LV2");
      }
   }
};

#endif // HYPERICT_DRAW_MQH
