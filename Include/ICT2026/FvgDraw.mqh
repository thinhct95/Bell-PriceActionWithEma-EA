//+------------------------------------------------------------------+
//| FvgDraw.mqh — render FVG + Premium/Discount lên chart            |
//+------------------------------------------------------------------+
//| v1.180 — selective rendering (chart không lag với 24+ FVG):       |
//|   1) Top-N USED gần nhất (default 3) — sort theo createdTime desc |
//|   2) Top-N AVAILABLE gần nhất (default 3)                         |
//|   3) Price-near: giá hiện tại trong [lower-N×ATR, upper+N×ATR]    |
//|   4) M5 FVG đang dùng cho MSS pipeline — luôn ép vẽ              |
//|                                                                   |
//| Inputs control:                                                   |
//|   InpDrawFvgZones          — bật/tắt vẽ                          |
//|   InpDrawMaxRecentPerState — N FVG gần nhất mỗi state             |
//|   InpDrawNearAtrMult       — bán kính near-price theo ATR        |
//|                                                                   |
//| Render: rectangle (FVG body) + 2 horizontal lines (Premium /      |
//| Discount edge). Bull/Bear/Used có màu riêng (InpFvgBull/Bear/Used)|
//|                                                                   |
//| Skip nếu: InpOnlyStatsMode = true (tester mode)                   |
//|                                                                   |
//| Object prefix:                                                    |
//|   ICT26_FVG_   — body rectangle                                   |
//|   ICT26_PD_    — Premium / Discount lines                         |
//|   ICT26_CFVG_  — Confirm TF (M5) FVG body                         |
//|                                                                   |
//| Public API:                                                       |
//|   void IctFvgDraw_Render(sym)                                     |
//|   void IctFvgDraw_DeleteAll()                                     |
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

// Insertion sort (descending theo createdTime) cho mảng indices nhỏ
void IctFvgDraw_SortIdxByTimeDesc(int &idx[], const int n,
                                   const IctFvgZone &zones[])
{
   for(int i = 1; i < n; i++)
   {
      const int cur = idx[i];
      const datetime ct = zones[cur].createdTime;
      int j = i - 1;
      while(j >= 0 && zones[idx[j]].createdTime < ct)
      {
         idx[j + 1] = idx[j];
         j--;
      }
      idx[j + 1] = cur;
   }
}

// Build mask "có vẽ" cho mảng FVG: top-N USED + top-N AVAILABLE gần nhất,
// cộng các FVG mà price hiện tại gần (≤ N×ATR).
void IctFvgDraw_BuildVisibleMask(const IctFvgZone &zones[], const int count,
                                  const string sym, bool &visible[])
{
   ArrayResize(visible, count);
   for(int i = 0; i < count; i++) visible[i] = false;
   if(count == 0)
      return;

   const int maxN = MathMax(0, InpDrawMaxRecentPerState);

   // Phân loại theo state
   int avail[], used[];
   ArrayResize(avail, count);
   ArrayResize(used,  count);
   int nA = 0, nU = 0;
   for(int i = 0; i < count; i++)
   {
      if(zones[i].state == ICT_FVG_USED)
         used[nU++] = i;
      else
         avail[nA++] = i;
   }
   ArrayResize(avail, nA);
   ArrayResize(used,  nU);

   IctFvgDraw_SortIdxByTimeDesc(avail, nA, zones);
   IctFvgDraw_SortIdxByTimeDesc(used,  nU, zones);

   for(int i = 0; i < MathMin(maxN, nA); i++) visible[avail[i]] = true;
   for(int i = 0; i < MathMin(maxN, nU); i++) visible[used[i]]  = true;

   // Mở rộng theo price-near
   if(InpDrawNearAtrMult > 0.0)
   {
      const double atr = IctFvg_AtrFvgTf(sym);
      if(atr > 0.0)
      {
         const double thresh = atr * InpDrawNearAtrMult;
         const double px = SymbolInfoDouble(sym, SYMBOL_BID);
         for(int i = 0; i < count; i++)
         {
            if(visible[i]) continue;
            if(px >= zones[i].lower - thresh && px <= zones[i].upper + thresh)
               visible[i] = true;
         }
      }
   }
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

   // Lọc H1 FVG cho top-N + price-near
   bool visH1[];
   IctFvgDraw_BuildVisibleMask(g_ictFvgZones, g_ictFvgCount, sym, visH1);

   for(int i = 0; i < g_ictFvgCount; i++)
   {
      if(!visH1[i])
         continue;
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
      // Lọc tương tự cho M5 FVG. M5 FVG đang được dùng cho MSS → ép vẽ.
      bool visM5[];
      IctFvgDraw_BuildVisibleMask(g_ictConfirmFvgZones, g_ictConfirmFvgCount, sym, visM5);
      const ulong activeM5 = IctLowTf_MssM5FvgId();

      for(int j = 0; j < g_ictConfirmFvgCount; j++)
      {
         const bool isActive = (activeM5 != 0 && g_ictConfirmFvgZones[j].id == activeM5 &&
                                IctLowTf_MssPhase() >= ICT_MSS_M5_FVG);
         if(!visM5[j] && !isActive)
            continue;

         const string cid = IntegerToString((long)g_ictConfirmFvgZones[j].id);
         const string cpfx = ICT26_CFVG_PFX + cid + "_";
         const datetime cStart = g_ictConfirmFvgZones[j].createdTime;
         const datetime cEnd   = IctFvg_GetFvgDrawTimeEnd(sym, InpConfirmTf, g_ictConfirmFvgZones[j]);

         color cClr = (g_ictConfirmFvgZones[j].side == ICT_FVG_BULL) ?
                      clrDarkGreen : clrFireBrick;
         if(g_ictConfirmFvgZones[j].state == ICT_FVG_USED)
            cClr = InpFvgUsedColor;
         if(isActive)
            cClr = (g_ictConfirmFvgZones[j].side == ICT_FVG_BULL) ? clrAqua : clrOrange;

         IctFvgDraw_Rect(cpfx + "BOX", cStart, g_ictConfirmFvgZones[j].upper,
                         cEnd, g_ictConfirmFvgZones[j].lower, cClr, true);
      }
   }

   ChartRedraw();
}

#endif
