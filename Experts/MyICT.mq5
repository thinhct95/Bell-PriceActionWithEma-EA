//+------------------------------------------------------------------+
//| MyICT.mq5                                                        |
//| Cùng 1 timeframe: BigTrend (swing 12) + SmallTrend (swing 2)      |
//| HH+HL = Up | LH+LL = Down | in panel + vẽ swing                   |
//+------------------------------------------------------------------+
#property copyright "MyICT"
#property version   "1.01"
#property description "Big/Small structure trên chart TF — không đa timeframe"

//+------------------------------------------------------------------+
enum ENUM_ICT_TREND
{
   ICT_TREND_UNKNOWN = 0,
   ICT_TREND_UP      = 1,
   ICT_TREND_DOWN    = 2,
   ICT_TREND_NEUTRAL = 3
};

//+------------------------------------------------------------------+
input group "══ Swing (nến trước/sau pivot) ══"
input int             InpBigSwingRange    = 12;    // BigTrend
input int             InpSmallSwingRange  = 2;     // SmallTrend
input int             InpSwingLookback    = 400;

input group "══ Hiển thị chart ══"
input bool            InpDrawSwings       = true;
input bool            InpDrawTrendLines   = true;
input color           InpClrBigHigh       = clrDodgerBlue;
input color           InpClrBigLow        = clrDeepSkyBlue;
input color           InpClrSmallHigh     = clrOrange;
input color           InpClrSmallLow      = clrGold;
input color           InpClrUp            = clrLime;
input color           InpClrDown          = clrTomato;
input color           InpClrNeutral       = clrSilver;
input int             InpFontSize         = 9;
input int             InpPanelX           = 12;
input int             InpPanelY           = 24;

input group "══ Debug ══"
input bool            InpDebug            = false;

//+------------------------------------------------------------------+
struct SwingPoint
{
   double   price;
   datetime time;
   int      shift;
};

struct TrendSnapshot
{
   ENUM_ICT_TREND trend;
   SwingPoint     h0, h1, l0, l1;
   bool           hasH0, hasH1, hasL0, hasL1;
};

const string OBJ_PFX = "MYICT_";

TrendSnapshot g_big;
TrendSnapshot g_small;
datetime      g_lastBar = 0;

//+------------------------------------------------------------------+
long ActChart() { return ChartID(); }

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ChartTf()
{
   return (ENUM_TIMEFRAMES)Period();
}

//+------------------------------------------------------------------+
void Dbg(const string msg)
{
   if(InpDebug)
      Print("[MyICT] ", msg);
}

//+------------------------------------------------------------------+
void DeleteObjectsByPrefix(const string prefix)
{
   const long ch = ActChart();
   for(int i = ObjectsTotal(ch, 0, -1) - 1; i >= 0; i--)
   {
      const string name = ObjectName(ch, i, 0, -1);
      if(StringFind(name, prefix) == 0)
         ObjectDelete(ch, name);
   }
}

//+------------------------------------------------------------------+
string TrendText(const ENUM_ICT_TREND t)
{
   switch(t)
   {
      case ICT_TREND_UP:      return "TREND UP (HH + HL)";
      case ICT_TREND_DOWN:    return "TREND DOWN (LH + LL)";
      case ICT_TREND_NEUTRAL: return "NEUTRAL";
      default:                return "— (thiếu swing)";
   }
}

//+------------------------------------------------------------------+
color TrendColor(const ENUM_ICT_TREND t)
{
   switch(t)
   {
      case ICT_TREND_UP:   return InpClrUp;
      case ICT_TREND_DOWN: return InpClrDown;
      default:             return InpClrNeutral;
   }
}

//+------------------------------------------------------------------+
bool IsSwingHigh(const string sym, const ENUM_TIMEFRAMES tf,
                 const int shift, const int swingRange)
{
   const int str = MathMax(1, swingRange);
   const double h = iHigh(sym, tf, shift);
   for(int k = 1; k <= str; k++)
   {
      if(shift + k >= Bars(sym, tf) || shift - k < 0)
         return false;
      if(h <= iHigh(sym, tf, shift + k) || h <= iHigh(sym, tf, shift - k))
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsSwingLow(const string sym, const ENUM_TIMEFRAMES tf,
                const int shift, const int swingRange)
{
   const int str = MathMax(1, swingRange);
   const double l = iLow(sym, tf, shift);
   for(int k = 1; k <= str; k++)
   {
      if(shift + k >= Bars(sym, tf) || shift - k < 0)
         return false;
      if(l >= iLow(sym, tf, shift + k) || l >= iLow(sym, tf, shift - k))
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void SortSwingsByTime(SwingPoint &pts[], const int count)
{
   for(int i = 0; i < count - 1; i++)
      for(int j = i + 1; j < count; j++)
         if(pts[j].time < pts[i].time)
         {
            const SwingPoint t = pts[i];
            pts[i] = pts[j];
            pts[j] = t;
         }
}

//+------------------------------------------------------------------+
void CollectSwings(const string sym, const ENUM_TIMEFRAMES tf,
                   const int swingRange, SwingPoint &highs[], SwingPoint &lows[])
{
   ArrayResize(highs, 0);
   ArrayResize(lows, 0);

   const int str  = MathMax(1, swingRange);
   const int bars = Bars(sym, tf);
   const int last = MathMin(InpSwingLookback, bars - str - 1);
   if(last < str + 5)
      return;

   int nH = 0, nL = 0;

   for(int sh = last; sh >= 1; sh--)
   {
      if(IsSwingHigh(sym, tf, sh, swingRange))
      {
         ArrayResize(highs, nH + 1);
         highs[nH].price = iHigh(sym, tf, sh);
         highs[nH].time  = iTime(sym, tf, sh);
         highs[nH].shift = sh;
         nH++;
      }
      if(IsSwingLow(sym, tf, sh, swingRange))
      {
         ArrayResize(lows, nL + 1);
         lows[nL].price = iLow(sym, tf, sh);
         lows[nL].time  = iTime(sym, tf, sh);
         lows[nL].shift = sh;
         nL++;
      }
   }

   SortSwingsByTime(highs, nH);
   SortSwingsByTime(lows, nL);
}

//+------------------------------------------------------------------+
void PickLastTwo(const SwingPoint &pts[], const int count,
                 SwingPoint &s0, SwingPoint &s1, bool &has0, bool &has1)
{
   has0 = has1 = false;
   if(count < 1)
      return;
   s0 = pts[count - 1];
   has0 = true;
   if(count < 2)
      return;
   s1 = pts[count - 2];
   has1 = true;
}

//+------------------------------------------------------------------+
ENUM_ICT_TREND ClassifyTrend(const bool hasH0, const bool hasH1,
                             const bool hasL0, const bool hasL1,
                             const SwingPoint &h0, const SwingPoint &h1,
                             const SwingPoint &l0, const SwingPoint &l1)
{
   if(!hasH0 || !hasH1 || !hasL0 || !hasL1)
      return ICT_TREND_UNKNOWN;

   if(h0.price > h1.price && l0.price > l1.price)
      return ICT_TREND_UP;
   if(h0.price < h1.price && l0.price < l1.price)
      return ICT_TREND_DOWN;
   return ICT_TREND_NEUTRAL;
}

//+------------------------------------------------------------------+
bool AnalyzeLayer(const string sym, const ENUM_TIMEFRAMES tf,
                  const int swingRange, TrendSnapshot &out)
{
   ZeroMemory(out);
   out.trend = ICT_TREND_UNKNOWN;

   SwingPoint highs[], lows[];
   CollectSwings(sym, tf, swingRange, highs, lows);

   PickLastTwo(highs, ArraySize(highs), out.h0, out.h1, out.hasH0, out.hasH1);
   PickLastTwo(lows, ArraySize(lows), out.l0, out.l1, out.hasL0, out.hasL1);

   out.trend = ClassifyTrend(out.hasH0, out.hasH1, out.hasL0, out.hasL1,
                             out.h0, out.h1, out.l0, out.l1);
   return true;
}

//+------------------------------------------------------------------+
void DrawArrowTag(const string tag, const datetime t, const double price,
                  const bool isHigh, const string label, const color clr,
                  const int width)
{
   const long ch = ActChart();
   const string arr = OBJ_PFX + tag + "_AR";
   const string txt = OBJ_PFX + tag + "_TX";

   if(ObjectFind(ch, arr) < 0)
      ObjectCreate(ch, arr, OBJ_ARROW, 0, t, price);
   ObjectMove(ch, arr, 0, t, price);
   ObjectSetInteger(ch, arr, OBJPROP_ARROWCODE, isHigh ? 217 : 218);
   ObjectSetInteger(ch, arr, OBJPROP_ANCHOR, isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
   ObjectSetInteger(ch, arr, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, arr, OBJPROP_WIDTH, width);
   ObjectSetInteger(ch, arr, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, arr, OBJPROP_HIDDEN, true);

   const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double yOff = pt * (isHigh ? (width > 1 ? 150 : 90) : (width > 1 ? -150 : -90));
   const double yLbl = NormalizeDouble(price + yOff, dig);

   if(ObjectFind(ch, txt) < 0)
      ObjectCreate(ch, txt, OBJ_TEXT, 0, t, yLbl);
   ObjectMove(ch, txt, 0, t, yLbl);
   ObjectSetString(ch, txt, OBJPROP_TEXT, label);
   ObjectSetInteger(ch, txt, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, txt, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetString(ch, txt, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(ch, txt, OBJPROP_ANCHOR, isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(ch, txt, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, txt, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void DrawSegLine(const string name, const datetime t1, const double p1,
                 const datetime t2, const double p2, const color clr, const int width)
{
   const long ch = ActChart();
   const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectMove(ch, name, 0, t1, NormalizeDouble(p1, dig));
   ObjectMove(ch, name, 1, t2, NormalizeDouble(p2, dig));
   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, name, OBJPROP_STYLE, width > 1 ? STYLE_SOLID : STYLE_DOT);
   ObjectSetInteger(ch, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(ch, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void DrawLayer(const string tag, const TrendSnapshot &snap,
               const color clrHi, const color clrLo, const int lineWidth)
{
   if(!InpDrawSwings)
      return;

   if(snap.hasH0)
      DrawArrowTag(tag + "_H0", snap.h0.time, snap.h0.price, true,
                   tag + " H0", clrHi, lineWidth);
   if(snap.hasH1)
      DrawArrowTag(tag + "_H1", snap.h1.time, snap.h1.price, true,
                   tag + " H1", clrHi, lineWidth);
   if(snap.hasL0)
      DrawArrowTag(tag + "_L0", snap.l0.time, snap.l0.price, false,
                   tag + " L0", clrLo, lineWidth);
   if(snap.hasL1)
      DrawArrowTag(tag + "_L1", snap.l1.time, snap.l1.price, false,
                   tag + " L1", clrLo, lineWidth);

   if(!InpDrawTrendLines)
      return;

   if(snap.hasH0 && snap.hasH1)
      DrawSegLine(OBJ_PFX + tag + "_LNH",
                  snap.h1.time, snap.h1.price, snap.h0.time, snap.h0.price, clrHi, lineWidth);
   if(snap.hasL0 && snap.hasL1)
      DrawSegLine(OBJ_PFX + tag + "_LNL",
                  snap.l1.time, snap.l1.price, snap.l0.time, snap.l0.price, clrLo, lineWidth);
}

//+------------------------------------------------------------------+
string LayerBlock(const string title, const int swingRange,
                  const TrendSnapshot &snap)
{
   string s = StringFormat("%s (swing %d): %s",
                           title, swingRange, TrendText(snap.trend));
   if(snap.hasH0 && snap.hasH1 && snap.hasL0 && snap.hasL1)
   {
      s += StringFormat("\n  H0=%.2f H1=%.2f | L0=%.2f L1=%.2f",
                        snap.h0.price, snap.h1.price, snap.l0.price, snap.l1.price);
      s += StringFormat(" | HH:%s HL:%s LH:%s LL:%s",
                        (snap.h0.price > snap.h1.price ? "Y" : "N"),
                        (snap.l0.price > snap.l1.price ? "Y" : "N"),
                        (snap.h0.price < snap.h1.price ? "Y" : "N"),
                        (snap.l0.price < snap.l1.price ? "Y" : "N"));
   }
   return s;
}

//+------------------------------------------------------------------+
void DrawPanel(const string body)
{
   const long ch = ActChart();
   const string name = OBJ_PFX + "PANEL";

   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(ch, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(ch, name, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(ch, name, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, MathMax(8, InpFontSize + 1));
   ObjectSetString(ch, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(ch, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(ch, name, OBJPROP_TEXT, body);
}

//+------------------------------------------------------------------+
void RedrawAll(const string sym, const ENUM_TIMEFRAMES tf)
{
   DeleteObjectsByPrefix(OBJ_PFX);

   string panel = StringFormat("MyICT | %s %s\n", _Symbol, EnumToString(tf));
   panel += LayerBlock("BigTrend", InpBigSwingRange, g_big) + "\n";
   panel += LayerBlock("SmallTrend", InpSmallSwingRange, g_small);

   DrawPanel(panel);

   DrawLayer("BIG", g_big, InpClrBigHigh, InpClrBigLow, 2);
   DrawLayer("SML", g_small, InpClrSmallHigh, InpClrSmallLow, 1);

   ChartRedraw(ActChart());
}

//+------------------------------------------------------------------+
void UpdateStructure(const string sym)
{
   const ENUM_TIMEFRAMES tf = ChartTf();

   AnalyzeLayer(sym, tf, InpBigSwingRange, g_big);
   AnalyzeLayer(sym, tf, InpSmallSwingRange, g_small);

   Dbg(StringFormat("%s Big=%s Small=%s",
        EnumToString(tf), TrendText(g_big.trend), TrendText(g_small.trend)));

   RedrawAll(sym, tf);

   Comment(StringFormat("MyICT %s\nBig: %s\nSmall: %s",
                        EnumToString(tf),
                        TrendText(g_big.trend),
                        TrendText(g_small.trend)));
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar = 0;
   UpdateStructure(_Symbol);
   Print("[MyICT] Init | TF=", EnumToString(ChartTf()),
         " Big=", InpBigSwingRange, " Small=", InpSmallSwingRange);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteObjectsByPrefix(OBJ_PFX);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   const string sym = _Symbol;
   const ENUM_TIMEFRAMES tf = ChartTf();
   const datetime t0 = iTime(sym, tf, 0);
   if(t0 == 0 || t0 == g_lastBar)
      return;
   g_lastBar = t0;
   UpdateStructure(sym);
}

//+------------------------------------------------------------------+
ENUM_ICT_TREND GetBigTrend()   { return g_big.trend; }
ENUM_ICT_TREND GetSmallTrend() { return g_small.trend; }
