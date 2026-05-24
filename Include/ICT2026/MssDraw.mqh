//+------------------------------------------------------------------+
//| MssDraw.mqh — vẽ MSS sau H1 chạm FVG: touch, 38.2%, CHoCH, H0    |
//+------------------------------------------------------------------+
#ifndef ICT2026_MSSDRAW_MQH
#define ICT2026_MSSDRAW_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/LowTfApi.mqh>
#include <ICT2026/MssSetup.mqh>

const string ICT26_MSS_PFX = "ICT26_MSS_";

void IctMssDraw_DeleteAll()
{
   const long ch = ChartID();
   for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
   {
      const string name = ObjectName(ch, i, 0, -1);
      if(StringFind(name, ICT26_MSS_PFX) == 0)
         ObjectDelete(ch, name);
   }
}

void IctMssDraw_HLine(const string name, const datetime t1, const datetime t2,
                      const double price, const color clr, const ENUM_LINE_STYLE style,
                      const int width = 1)
{
   const long ch = ChartID();
   const string obj = ICT26_MSS_PFX + name;
   if(ObjectFind(ch, obj) < 0)
      ObjectCreate(ch, obj, OBJ_TREND, 0, t1, price, t2, price);

   ObjectSetInteger(ch, obj, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, obj, OBJPROP_STYLE, style);
   ObjectSetInteger(ch, obj, OBJPROP_WIDTH, width);
   ObjectSetInteger(ch, obj, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(ch, obj, OBJPROP_BACK, true);
   ObjectSetInteger(ch, obj, OBJPROP_SELECTABLE, false);
   ObjectMove(ch, obj, 0, t1, price);
   ObjectMove(ch, obj, 1, t2, price);
}

void IctMssDraw_VLine(const string name, const datetime t, const color clr)
{
   const long ch = ChartID();
   const string obj = ICT26_MSS_PFX + name;
   if(ObjectFind(ch, obj) < 0)
      ObjectCreate(ch, obj, OBJ_VLINE, 0, t, 0.0);

   ObjectSetInteger(ch, obj, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, obj, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(ch, obj, OBJPROP_WIDTH, 1);
   ObjectSetInteger(ch, obj, OBJPROP_BACK, true);
   ObjectSetInteger(ch, obj, OBJPROP_SELECTABLE, false);
   ObjectMove(ch, obj, 0, t, 0.0);
}

void IctMssDraw_Label(const string name, const string text,
                      const datetime t, const double price,
                      const bool above, const color clr)
{
   const long ch = ChartID();
   const string obj = ICT26_MSS_PFX + name;
   if(ObjectFind(ch, obj) < 0)
      ObjectCreate(ch, obj, OBJ_TEXT, 0, t, price);

   ObjectMove(ch, obj, 0, t, price);
   ObjectSetString(ch, obj, OBJPROP_TEXT, text);
   ObjectSetInteger(ch, obj, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, obj, OBJPROP_FONTSIZE, InpChartLabelFontSize);
   ObjectSetString(ch, obj, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(ch, obj, OBJPROP_ANCHOR, above ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(ch, obj, OBJPROP_SELECTABLE, false);
}

datetime IctMssDraw_TimeEnd(const string sym)
{
   const ENUM_TIMEFRAMES cTf = InpConfirmTf;
   return iTime(sym, cTf, 0) + (datetime)PeriodSeconds(cTf);
}

void IctMssDraw_ResolveChoch(const IctMssState &mss,
                             double &keyLv, datetime &keyT, double &slSwing, datetime &chochT)
{
   keyLv   = mss.chochKeyLevel;
   keyT    = mss.chochKeyTime;
   slSwing = mss.slSwingPrice;
   chochT  = mss.chochTime;
   if(chochT <= 0)
      chochT = keyT;
}

void IctMssDraw_Render(const string sym)
{
   if(!InpDrawMssChoch)
   {
      IctMssDraw_DeleteAll();
      return;
   }

   const IctMssState mss = g_ictLowTf.mss;
   if(mss.phase < ICT_MSS_H1_TOUCH || mss.h1FvgId == 0)
   {
      IctMssDraw_DeleteAll();
      return;
   }

   const int h1Idx = IctMss_FindH1FvgById(mss.h1FvgId);
   if(h1Idx < 0)
   {
      IctMssDraw_DeleteAll();
      return;
   }

   IctMssDraw_DeleteAll();

   const IctFvgZone h1 = g_ictFvgZones[h1Idx];
   const datetime tEnd = IctMssDraw_TimeEnd(sym);
   const bool isBear   = (g_ictDailyBias.bias == ICT_BIAS_BEAR);

   datetime tTouch = mss.h1TouchTime;
   if(tTouch <= 0)
      tTouch = h1.firstTouchTime;
   if(tTouch <= 0)
      tTouch = h1.createdTime;

   if(tTouch > 0)
   {
      IctMssDraw_VLine("H1_TOUCH", tTouch, clrDodgerBlue);
      IctMssDraw_Label("H1_TOUCH_LBL", " Retest FVG H1 ", tTouch, h1.upper, true, clrDodgerBlue);
   }

   const double fill382 = IctFvg_PriceAtFillPct(h1, InpMssH1MinFillPct);
   if(fill382 > 0.0 && tTouch > 0)
   {
      IctMssDraw_HLine("H1_382", tTouch, tEnd, fill382, clrSilver, STYLE_DOT, 1);
      IctMssDraw_Label("H1_382_LBL",
                       StringFormat(" H1 %.0f%% ", InpMssH1MinFillPct),
                       tTouch, fill382, !isBear, clrSilver);
   }

   double keyLv = 0.0, slSwing = 0.0;
   datetime keyT = 0, chochT = 0;
   IctMssDraw_ResolveChoch(mss, keyLv, keyT, slSwing, chochT);

   const bool mssPending = (mss.phase == ICT_MSS_H1_TOUCH && !mss.chochLocked);
   if(mssPending && mss.liveL0Price > 0.0)
   {
      keyLv   = isBear ? mss.liveL0Price : mss.liveH0Price;
      keyT    = isBear ? mss.liveL0Time  : mss.liveH0Time;
      slSwing = isBear ? mss.liveH0Price : mss.liveL0Price;
      chochT  = 0;
   }

   if(keyLv > 0.0)
   {
      if(keyT <= 0)
         keyT = tTouch;
      if(chochT <= 0)
         chochT = mss.chochTime > 0 ? mss.chochTime : keyT;

      const color clrChoch = clrGold;
      const string chochLbl = mssPending ?
         (isBear ? " L0 live " : " H0 live ") :
         (isBear ? " MSS↓ L0 " : " MSS↑ H0 ");
      const bool chochAbove = !isBear;
      const datetime tLineStart = (keyT > 0) ? keyT : tTouch;
      const datetime tChoch     = (chochT > 0) ? chochT : tLineStart;

      IctMssDraw_HLine("CHOCH", tLineStart, tEnd, keyLv, clrChoch,
                       mssPending ? STYLE_DOT : STYLE_SOLID, 2);
      IctMssDraw_Label("CHOCH_LBL", chochLbl, tChoch, keyLv, chochAbove, clrChoch);
   }

   if(slSwing > 0.0)
   {
      const string swTag = isBear ? " H0 " : " L0 ";
      const color clrSw  = clrYellow;
      datetime tSw = isBear ?
         (mss.liveH0Time > 0 ? mss.liveH0Time : keyT) :
         (mss.liveL0Time > 0 ? mss.liveL0Time : keyT);
      if(tSw <= 0)
         tSw = tTouch;

      IctMssDraw_HLine("MSS_SW", tSw, tEnd, slSwing, clrSw,
                       mssPending ? STYLE_DOT : STYLE_DASH, 1);
      IctMssDraw_Label("MSS_SW_LBL", swTag, tSw, slSwing, true, clrSw);
   }

   if(mss.pendingEntry > 0.0 && mss.phase >= ICT_MSS_M5_FVG)
   {
      datetime tSw = (keyT > 0) ? keyT : tTouch;
      IctMssDraw_HLine("ENTRY", tEnd - (datetime)PeriodSeconds(InpConfirmTf) * 3,
                       tEnd, mss.pendingEntry, clrAqua, STYLE_DOT, 1);
      if(mss.pendingSl > 0.0)
         IctMssDraw_HLine("SL", tSw, tEnd, mss.pendingSl, clrOrangeRed, STYLE_DOT, 1);
      if(mss.pendingTp > 0.0)
         IctMssDraw_HLine("TP", tSw, tEnd, mss.pendingTp, clrLimeGreen, STYLE_DOT, 1);
   }

   ChartRedraw();
}

#endif
