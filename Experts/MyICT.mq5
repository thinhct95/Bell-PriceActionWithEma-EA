//+------------------------------------------------------------------+
//| MyICT.mq5                                                        |
//| Big/Small structure + State machine (NO_TREND → PULLBACK → …)    |
//+------------------------------------------------------------------+
#property copyright "MyICT"
#property version   "1.04"
#property description "ICT states: pullback discount/premium | limit/trade tracking"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
enum ENUM_ICT_TREND
{
   ICT_TREND_UNKNOWN = 0,
   ICT_TREND_UP      = 1,
   ICT_TREND_DOWN    = 2,
   ICT_TREND_NEUTRAL = 3
};

enum ENUM_ICT_STATE
{
   ICT_STATE_NO_TREND        = 0,
   ICT_STATE_PULLBACK        = 1,
   ICT_STATE_WAITING_TRIGGER = 2,
   ICT_STATE_LIMIT_ORDERED   = 3,
   ICT_STATE_ON_TRADE        = 4,
   ICT_STATE_NONE            = 5
};

//+------------------------------------------------------------------+
input group "══ Swing (nến trước/sau pivot) ══"
input int             InpBigSwingRange    = 24;
input int             InpSmallSwingRange  = 2;
input int             InpSwingLookback    = 400;

input group "══ Discount / Premium (sóng Big) ══"
input double          InpZoneEqPct         = 50.0;   // % từ đáy/đỉnh sóng → equilibrium
input double          InpZoneTolPoints     = 5.0;    // dung sai (point)

input group "══ Trade (limit — trigger bổ sung sau) ══"
input ulong           InpMagic             = 20260620;
input bool            InpAutoLimitOnZone   = false; // true: đặt limit khi WAITING_TRIGGER

input group "══ Hiển thị chart ══"
input bool            InpDrawSwings       = true;
input bool            InpDrawTrendLines   = true;
input bool            InpDrawZones        = true;
input uchar           InpZoneFillAlpha    = 68;     // 0=đặc, 255=trong suốt (nhỏ=hơn=mờ vừa)
input uchar           InpZoneActiveAlpha  = 50;     // vùng bias active (đậm hơn)
input color           InpClrBigHigh       = clrDodgerBlue;
input color           InpClrBigLow        = clrDeepSkyBlue;
input color           InpClrSmallHigh     = clrOrange;
input color           InpClrSmallLow      = clrGold;
input color           InpClrDiscount      = C'0,110,45';    // xanh đậm (dễ thấy trên nền đen)
input color           InpClrPremium       = C'150,45,55';   // đỏ burgundy
input color           InpClrZoneLabel     = clrWhite;
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

struct BigWaveZone
{
   bool   valid;
   double waveHigh;
   double waveLow;
   double equilibrium;
   double discountTop;   // buy: giá <= discountTop = trong discount
   double premiumBottom; // sell: giá >= premiumBottom = trong premium
};

const string OBJ_PFX = "MYICT_";

TrendSnapshot   g_big;
TrendSnapshot   g_small;
BigWaveZone     g_zone;
ENUM_ICT_STATE  g_state = ICT_STATE_NO_TREND;
ENUM_ICT_STATE  g_statePrev = ICT_STATE_NO_TREND;
bool            g_biasBuy = false;
datetime        g_lastBar = 0;

CTrade          g_trade;

//+------------------------------------------------------------------+
long ActChart() { return ChartID(); }

ENUM_TIMEFRAMES ChartTf() { return (ENUM_TIMEFRAMES)Period(); }

//+------------------------------------------------------------------+
color WithAlpha(const color clr, const uchar alpha)
{
   return (color)((long)clr | ((long)alpha << 24));
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
      case ICT_TREND_UP:      return "UP (HH+HL)";
      case ICT_TREND_DOWN:    return "DOWN (LH+LL)";
      case ICT_TREND_NEUTRAL: return "NEUTRAL";
      default:                return "—";
   }
}

//+------------------------------------------------------------------+
string StateText(const ENUM_ICT_STATE s)
{
   switch(s)
   {
      case ICT_STATE_NO_TREND:        return "NO_TREND";
      case ICT_STATE_PULLBACK:        return "PULLBACK";
      case ICT_STATE_WAITING_TRIGGER: return "WAITING_TRIGGER";
      case ICT_STATE_LIMIT_ORDERED:   return "LIMIT_ORDERED";
      case ICT_STATE_ON_TRADE:        return "ON_TRADE";
      case ICT_STATE_NONE:            return "NONE";
      default:                        return "?";
   }
}

//+------------------------------------------------------------------+
color StateColor(const ENUM_ICT_STATE s)
{
   switch(s)
   {
      case ICT_STATE_WAITING_TRIGGER: return clrGold;
      case ICT_STATE_LIMIT_ORDERED:   return clrOrange;
      case ICT_STATE_ON_TRADE:        return clrLime;
      case ICT_STATE_PULLBACK:        return clrAqua;
      case ICT_STATE_NONE:            return clrGray;
      default:                        return InpClrNeutral;
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
   if(count < 1) return;
   s0 = pts[count - 1];
   has0 = true;
   if(count < 2) return;
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
bool BigTrendIsClear()
{
   return (g_big.trend == ICT_TREND_UP || g_big.trend == ICT_TREND_DOWN);
}

//+------------------------------------------------------------------+
bool IsPullbackStructure()
{
   if(!BigTrendIsClear())
      return false;
   if(g_big.trend == ICT_TREND_UP && g_small.trend == ICT_TREND_DOWN)
   {
      g_biasBuy = true;
      return true;
   }
   if(g_big.trend == ICT_TREND_DOWN && g_small.trend == ICT_TREND_UP)
   {
      g_biasBuy = false;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CalcBigWaveZone()
{
   ZeroMemory(g_zone);
   if(!g_big.hasH0 || !g_big.hasL0)
      return;

   g_zone.waveHigh = g_big.h0.price;
   g_zone.waveLow  = g_big.l0.price;
   if(g_zone.waveHigh < g_zone.waveLow)
   {
      const double t = g_zone.waveHigh;
      g_zone.waveHigh = g_zone.waveLow;
      g_zone.waveLow  = t;
   }

   const double range = g_zone.waveHigh - g_zone.waveLow;
   if(range <= 0.0)
      return;

   const double pct = MathMax(1.0, MathMin(99.0, InpZoneEqPct)) / 100.0;
   g_zone.equilibrium  = g_zone.waveLow + range * pct;
   g_zone.discountTop  = g_zone.equilibrium;
   g_zone.premiumBottom = g_zone.equilibrium;
   g_zone.valid = true;
}

//+------------------------------------------------------------------+
bool PriceInDiscount(const double price)
{
   if(!g_zone.valid)
      return false;
   const double tol = InpZoneTolPoints * _Point;
   return (price <= g_zone.discountTop + tol);
}

//+------------------------------------------------------------------+
bool PriceInPremium(const double price)
{
   if(!g_zone.valid)
      return false;
   const double tol = InpZoneTolPoints * _Point;
   return (price >= g_zone.premiumBottom - tol);
}

//+------------------------------------------------------------------+
bool HasMyPosition(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool HasMyPendingLimit(const string sym)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != sym)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void SetTradeFilling()
{
   const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fm & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
// Placeholder: trigger chi tiết sẽ bổ sung — tạm đặt limit tại equilibrium
bool TryPlaceLimitFromState(const string sym)
{
   if(!InpAutoLimitOnZone || g_state != ICT_STATE_WAITING_TRIGGER)
      return false;
   if(!g_zone.valid || HasMyPosition(sym) || HasMyPendingLimit(sym))
      return false;

   const int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   const double px = NormalizeDouble(g_zone.equilibrium, dig);

   g_trade.SetExpertMagicNumber(InpMagic);
   SetTradeFilling();

   bool ok = false;
   if(g_biasBuy)
      ok = g_trade.BuyLimit(0.01, sym, px, 0.0, 0.0, ORDER_TIME_GTC, 0, "MyICT limit buy");
   else
      ok = g_trade.SellLimit(0.01, sym, px, 0.0, 0.0, ORDER_TIME_GTC, 0, "MyICT limit sell");

   if(ok)
      Dbg("Đặt limit tại equilibrium (placeholder)");
   return ok;
}

//+------------------------------------------------------------------+
ENUM_ICT_STATE ComputeStructureState(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!BigTrendIsClear())
      return ICT_STATE_NO_TREND;

   if(!IsPullbackStructure())
      return ICT_STATE_NO_TREND;

   CalcBigWaveZone();

   const double refPrice = iClose(sym, tf, 1);

   if(g_biasBuy)
   {
      if(PriceInDiscount(refPrice))
         return ICT_STATE_WAITING_TRIGGER;
      return ICT_STATE_PULLBACK;
   }

   if(PriceInPremium(refPrice))
      return ICT_STATE_WAITING_TRIGGER;
   return ICT_STATE_PULLBACK;
}

//+------------------------------------------------------------------+
void UpdateStateMachine(const string sym, const ENUM_TIMEFRAMES tf)
{
   g_statePrev = g_state;

   if(HasMyPosition(sym))
   {
      g_state = ICT_STATE_ON_TRADE;
      return;
   }

   if(HasMyPendingLimit(sym))
   {
      g_state = ICT_STATE_LIMIT_ORDERED;
      return;
   }

   if(g_statePrev == ICT_STATE_ON_TRADE || g_statePrev == ICT_STATE_LIMIT_ORDERED)
   {
      g_state = ICT_STATE_NONE;
      Dbg("NONE — lệnh đã đóng (SL/TP hoặc hủy)");
      return;
   }

   if(g_statePrev == ICT_STATE_NONE)
   {
      // một nến NONE rồi quay lại đánh giá cấu trúc
   }

   g_state = ComputeStructureState(sym, tf);

   if(g_state == ICT_STATE_WAITING_TRIGGER)
      TryPlaceLimitFromState(sym);

   if(g_state != g_statePrev && InpDebug)
      Dbg(StringFormat("State %s → %s", StateText(g_statePrev), StateText(g_state)));
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

   if(ObjectFind(ch, txt) < 0)
      ObjectCreate(ch, txt, OBJ_TEXT, 0, t, NormalizeDouble(price + yOff, dig));
   ObjectMove(ch, txt, 0, t, NormalizeDouble(price + yOff, dig));
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
void DrawZoneRect(const string name, const datetime t1, const datetime t2,
                  const double pTop, const double pBot, const color clr,
                  const uchar fillAlpha, const string tip)
{
   const long ch = ActChart();
   const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double y1 = NormalizeDouble(MathMax(pTop, pBot), dig);
   const double y2 = NormalizeDouble(MathMin(pTop, pBot), dig);

   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_RECTANGLE, 0, t1, y1, t2, y2);
   ObjectMove(ch, name, 0, t1, y1);
   ObjectMove(ch, name, 1, t2, y2);
   ObjectSetInteger(ch, name, OBJPROP_COLOR, WithAlpha(clr, fillAlpha));
   ObjectSetInteger(ch, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(ch, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(ch, name, OBJPROP_FILL, true);
   ObjectSetInteger(ch, name, OBJPROP_BACK, true);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, name, OBJPROP_HIDDEN, true);
   ObjectSetString(ch, name, OBJPROP_TOOLTIP, tip);
}

//+------------------------------------------------------------------+
void DrawZoneTag(const string name, const datetime t, const double price,
                 const string text, const color clr)
{
   const long ch = ActChart();
   const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_TEXT, 0, t, NormalizeDouble(price, dig));
   ObjectMove(ch, name, 0, t, NormalizeDouble(price, dig));
   ObjectSetString(ch, name, OBJPROP_TEXT, text);
   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, MathMax(7, InpFontSize - 1));
   ObjectSetString(ch, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(ch, name, OBJPROP_BACK, false);
}

//+------------------------------------------------------------------+
void DrawLayer(const string tag, const TrendSnapshot &snap,
               const color clrHi, const color clrLo, const int lineWidth)
{
   if(!InpDrawSwings)
      return;

   if(snap.hasH0)
      DrawArrowTag(tag + "_H0", snap.h0.time, snap.h0.price, true, tag + " H0", clrHi, lineWidth);
   if(snap.hasH1)
      DrawArrowTag(tag + "_H1", snap.h1.time, snap.h1.price, true, tag + " H1", clrHi, lineWidth);
   if(snap.hasL0)
      DrawArrowTag(tag + "_L0", snap.l0.time, snap.l0.price, false, tag + " L0", clrLo, lineWidth);
   if(snap.hasL1)
      DrawArrowTag(tag + "_L1", snap.l1.time, snap.l1.price, false, tag + " L1", clrLo, lineWidth);

   if(!InpDrawTrendLines)
      return;
   if(snap.hasH0 && snap.hasH1)
      DrawSegLine(OBJ_PFX + tag + "_LNH", snap.h1.time, snap.h1.price,
                  snap.h0.time, snap.h0.price, clrHi, lineWidth);
   if(snap.hasL0 && snap.hasL1)
      DrawSegLine(OBJ_PFX + tag + "_LNL", snap.l1.time, snap.l1.price,
                  snap.l0.time, snap.l0.price, clrLo, lineWidth);
}

//+------------------------------------------------------------------+
void DrawZones(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!InpDrawZones || !g_zone.valid)
      return;

   const datetime t2 = iTime(sym, tf, 0);
   const datetime t1 = iTime(sym, tf, MathMin(60, Bars(sym, tf) - 1));
   if(t1 == 0 || t2 == 0)
      return;

   const bool activePullback = (g_state == ICT_STATE_PULLBACK
                              || g_state == ICT_STATE_WAITING_TRIGGER);
   const uchar discAlpha = (activePullback && g_biasBuy)
                           ? InpZoneActiveAlpha : InpZoneFillAlpha;
   const uchar premAlpha = (activePullback && !g_biasBuy)
                           ? InpZoneActiveAlpha : InpZoneFillAlpha;

   DrawZoneRect(OBJ_PFX + "Z_DISC", t1, t2,
                g_zone.discountTop, g_zone.waveLow,
                InpClrDiscount, discAlpha,
                "Discount — nửa dưới sóng Big (Buy)");

   DrawZoneRect(OBJ_PFX + "Z_PREM", t1, t2,
                g_zone.waveHigh, g_zone.premiumBottom,
                InpClrPremium, premAlpha,
                "Premium — nửa trên sóng Big (Sell)");

   DrawSegLine(OBJ_PFX + "Z_EQ", t1, g_zone.equilibrium, t2, g_zone.equilibrium,
               clrGold, 1);
   ObjectSetInteger(ActChart(), OBJ_PFX + "Z_EQ", OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(ActChart(), OBJ_PFX + "Z_EQ", OBJPROP_WIDTH, 2);

   const double midDisc = (g_zone.waveLow + g_zone.discountTop) * 0.5;
   const double midPrem = (g_zone.premiumBottom + g_zone.waveHigh) * 0.5;
   DrawZoneTag(OBJ_PFX + "LBL_DISC", t2, midDisc, " DISCOUNT ", InpClrZoneLabel);
   DrawZoneTag(OBJ_PFX + "LBL_PREM", t2, midPrem, " PREMIUM ", InpClrZoneLabel);
}

//+------------------------------------------------------------------+
string LayerBlock(const string title, const int swingRange, const TrendSnapshot &snap)
{
   string s = StringFormat("%s (sw %d): %s", title, swingRange, TrendText(snap.trend));
   if(snap.hasH0 && snap.hasH1 && snap.hasL0 && snap.hasL1)
      s += StringFormat("\n  H0=%.2f H1=%.2f L0=%.2f L1=%.2f",
                        snap.h0.price, snap.h1.price, snap.l0.price, snap.l1.price);
   return s;
}

//+------------------------------------------------------------------+
string StateBlock()
{
   string s = StringFormat("STATE: %s", StateText(g_state));
   if(g_state == ICT_STATE_PULLBACK || g_state == ICT_STATE_WAITING_TRIGGER)
      s += StringFormat(" | Bias %s", g_biasBuy ? "BUY" : "SELL");
   if(g_zone.valid)
      s += StringFormat("\n  Eq=%.2f (%.0f%%) | %s",
                        g_zone.equilibrium, InpZoneEqPct,
                        g_biasBuy ? "Discount" : "Premium");
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
   ObjectSetInteger(ch, name, OBJPROP_COLOR, StateColor(g_state));
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(ch, name, OBJPROP_TEXT, body);
}

//+------------------------------------------------------------------+
void RedrawChart(const string sym, const ENUM_TIMEFRAMES tf)
{
   DeleteObjectsByPrefix(OBJ_PFX);

   string panel = StringFormat("MyICT | %s %s\n", sym, EnumToString(tf));
   panel += StateBlock() + "\n";
   panel += LayerBlock("BigTrend", InpBigSwingRange, g_big) + "\n";
   panel += LayerBlock("SmallTrend", InpSmallSwingRange, g_small);

   DrawPanel(panel);
   DrawLayer("BIG", g_big, InpClrBigHigh, InpClrBigLow, 2);
   DrawLayer("SML", g_small, InpClrSmallHigh, InpClrSmallLow, 1);
   DrawZones(sym, tf);
   ChartRedraw(ActChart());
}

//+------------------------------------------------------------------+
void OnNewBar(const string sym)
{
   const ENUM_TIMEFRAMES tf = ChartTf();

   AnalyzeLayer(sym, tf, InpBigSwingRange, g_big);
   AnalyzeLayer(sym, tf, InpSmallSwingRange, g_small);

   if(g_big.hasH0 && g_big.hasL0)
      CalcBigWaveZone();

   UpdateStateMachine(sym, tf);
   RedrawChart(sym, tf);

   Comment(StringFormat("MyICT | %s\n%s\nBig: %s | Small: %s",
                        StateText(g_state),
                        g_biasBuy && (g_state == ICT_STATE_PULLBACK || g_state == ICT_STATE_WAITING_TRIGGER)
                           ? "Bias BUY" : (!g_biasBuy && IsPullbackStructure() ? "Bias SELL" : ""),
                        TrendText(g_big.trend),
                        TrendText(g_small.trend)));
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar = 0;
   g_state = ICT_STATE_NO_TREND;
   g_statePrev = ICT_STATE_NO_TREND;
   g_trade.SetExpertMagicNumber(InpMagic);
   SetTradeFilling();
   OnNewBar(_Symbol);
   Print("[MyICT] Init state=", StateText(g_state));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteObjectsByPrefix(OBJ_PFX);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   const ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
      return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT)
      return;

   g_state = ICT_STATE_NONE;
   Dbg("OnTradeTransaction → NONE (đóng lệnh)");
   RedrawChart(_Symbol, ChartTf());
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
   OnNewBar(sym);
}

//+------------------------------------------------------------------+
ENUM_ICT_STATE GetIctState()     { return g_state; }
ENUM_ICT_TREND GetBigTrend()     { return g_big.trend; }
ENUM_ICT_TREND GetSmallTrend()   { return g_small.trend; }
