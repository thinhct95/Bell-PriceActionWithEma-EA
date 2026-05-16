//+------------------------------------------------------------------+
//| MyICT.mq5                                                        |
//| Big/Small structure + State machine (NO_TREND → PULLBACK → …)    |
//+------------------------------------------------------------------+
#property copyright "MyICT"
#property version   "1.10"
#property description "ICT MSS: sweep + BOS + FVG → limit @ breaker | R% | stats"

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
input int             InpBigSwingRange    = 12;
input int             InpSmallSwingRange  = 2;
input int             InpSwingLookback    = 400;

input group "══ Discount / Premium (sóng Big) ══"
input double          InpZoneEqPct         = 50.0;   // % từ đáy/đỉnh sóng → equilibrium
input double          InpZoneTolPoints     = 5.0;    // dung sai (point)

input group "══ MSS / Liquidity / Breaker ══"
input int             InpMssLookback       = 50;     // quét sweep + BOS
input int             InpMssMaxRecent      = 10;    // MSS chỉ trên N nến gần nhất
input double          InpSweepTolPoints    = 3.0;    // wick quét liquidity (point)
input double          InpSweepTolAtr       = 0.05;   // + ×ATR
input double          InpMssDispAtrMult    = 0.30;   // nến BOS: body tối thiểu ×ATR
input bool            InpRequireFvg        = true;   // bắt buộc FVG sau BOS
input double          InpBreakerOffsetAtr  = 0.0;    // offset entry breaker (×ATR)
input int             InpLimitExpireBars   = 24;    // hủy limit sau N nến

input group "══ Session (London / New York) ══"
input bool            InpUseSessionFilter  = true;   // chỉ đặt lệnh trong phiên
input bool            InpSessionUseUtc     = false;  // false = giờ server broker
input int             InpLondonStartHour   = 8;      // London [0..23]
input int             InpLondonEndHour     = 17;
input int             InpNewYorkStartHour  = 13;     // New York [0..23]
input int             InpNewYorkEndHour    = 22;
input int             InpSessionAvoidLastMin = 0;  // tránh N phút cuối mỗi phiên (0=tắt)

input group "══ Trigger & quản lý lệnh ══"
input bool            InpTradeEnabled      = true;
input ulong           InpMagic             = 20260620;
input double          InpRiskPercent       = 1.0;    // 1R = % balance
input int             InpATRPeriod         = 14;
input double          InpSlAtrMult         = 0.25;   // SL trên đỉnh sweep / dưới đáy sweep + ATR×
input double          InpTpAtrBuffer       = 0.25;   // TP trước đỉnh/đáy sóng Big −/+ ATR×
input bool            InpUseMinRR          = true;   // lọc R:R tối thiểu
input double          InpMinRR             = 1.5;    // R:R tối thiểu (1:1.5 → 1.5)
input int             InpSlippagePoints    = 30;
input bool            InpOnePosition       = true;

input group "══ Thống kê (góc dưới-trái) ══"
input bool            InpShowStats         = true;
input int             InpStatFontSize      = 9;
input int             InpStatCornerX       = 8;
input int             InpStatCornerY       = 8;
input color           InpStatColor         = clrSilver;

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
input color           InpClrBreaker       = C'120,60,180';
input color           InpClrFvg           = C'40,140,90';
input color           InpClrSweep         = clrDeepSkyBlue;
input color           InpClrZoneLabel     = clrWhite;
input bool            InpDrawMssSetup     = true;
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
   bool   legExtended;   // sóng kéo tới giá mới (không chỉ H0-L0 cũ)
   double waveHigh;
   double waveLow;
   double equilibrium;
   double discountTop;
   double premiumBottom;
};

struct IctMssSetup
{
   bool     valid;
   bool     isBuy;
   double   liqLevel;
   double   sweepExtreme;
   int      sweepShift;
   double   brokenLevel;
   int      brokenShift;
   double   breakerTop;
   double   breakerBottom;
   double   entry;
   double   sl;
   double   tp;
   bool     hasFvg;
   double   fvgTop;
   double   fvgBottom;
   int      fvgShift;
   int      mssShift;
   string   summary;
};

const string OBJ_CH_PFX  = "MYICTC_";
const string STAT_PREFIX = "MYICTS_";
const string STAT_LINE1  = STAT_PREFIX + "L1";
const string STAT_LINE2  = STAT_PREFIX + "L2";

TrendSnapshot   g_big;
TrendSnapshot   g_small;
BigWaveZone     g_zone;
IctMssSetup     g_setup;
ENUM_ICT_STATE  g_state = ICT_STATE_NO_TREND;
ENUM_ICT_STATE  g_statePrev = ICT_STATE_NO_TREND;
bool            g_biasBuy = false;
datetime        g_lastBar = 0;
datetime        g_lastTriggerBar = 0;
datetime        g_limitPlacedBar = 0;

int             g_hAtr = INVALID_HANDLE;
long            g_statWins  = 0;
long            g_statLoss = 0;
long            g_statTotal = 0;

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
int ClampHour(const int h)
{
   return MathMax(0, MathMin(23, h));
}

//+------------------------------------------------------------------+
int SessionMinutesNow()
{
   MqlDateTime tm;
   const datetime t = InpSessionUseUtc ? TimeGMT() : TimeCurrent();
   TimeToStruct(t, tm);
   return tm.hour * 60 + tm.min;
}

//+------------------------------------------------------------------+
bool IsWithinSessionWindow(const int currentMinutes,
                           const int startHour, const int endHour,
                           const int avoidLastMinutes)
{
   const int startMin = ClampHour(startHour) * 60;
   int endMin = ClampHour(endHour) * 60;
   if(endMin <= startMin)
      endMin += 24 * 60;

   int cur = currentMinutes;
   if(endMin > 24 * 60 && cur < startMin)
      cur += 24 * 60;

   if(cur < startMin || cur >= endMin)
      return false;

   const int avoid = MathMax(0, avoidLastMinutes);
   if(avoid > 0 && cur >= endMin - avoid)
      return false;

   return true;
}

//+------------------------------------------------------------------+
bool IsLondonSession()
{
   return IsWithinSessionWindow(SessionMinutesNow(),
                                InpLondonStartHour, InpLondonEndHour,
                                InpSessionAvoidLastMin);
}

//+------------------------------------------------------------------+
bool IsNewYorkSession()
{
   return IsWithinSessionWindow(SessionMinutesNow(),
                                InpNewYorkStartHour, InpNewYorkEndHour,
                                InpSessionAvoidLastMin);
}

//+------------------------------------------------------------------+
bool IsTradeSessionAllowed()
{
   if(!InpUseSessionFilter)
      return true;
   return (IsLondonSession() || IsNewYorkSession());
}

//+------------------------------------------------------------------+
string SessionStatusText()
{
   if(!InpUseSessionFilter)
      return "Session: OFF (filter tắt)";

   const string tz = InpSessionUseUtc ? "UTC" : "Server";
   string s = StringFormat("Session [%s]: ", tz);
   if(IsLondonSession() && IsNewYorkSession())
      s += "London + NY";
   else if(IsLondonSession())
      s += "London";
   else if(IsNewYorkSession())
      s += "New York";
   else
      s += "CLOSED";
   return s;
}

//+------------------------------------------------------------------+
double GetAtr(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   if(g_hAtr == INVALID_HANDLE)
      return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_hAtr, 0, shift, 1, b) < 1)
      return 0.0;
   return b[0];
}

//+------------------------------------------------------------------+
double SweepTolerance(const string sym, const double atr)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return MathMax(pt * InpSweepTolPoints, atr * InpSweepTolAtr);
}

//+------------------------------------------------------------------+
double BosTolerance(const string sym, const double atr)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return MathMax(pt * 2.0, atr * 0.02);
}

//+------------------------------------------------------------------+
bool FindBearishFvg(const string sym, const ENUM_TIMEFRAMES tf,
                    const int shiftFrom, const int shiftTo,
                    double &fTop, double &fBot, int &fShift)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const int lo = MathMin(shiftFrom, shiftTo);
   const int hi = MathMax(shiftFrom, shiftTo);

   for(int i = lo; i <= hi; i++)
   {
      if(i + 2 >= Bars(sym, tf))
         continue;
      const double gapLo = iLow(sym, tf, i);
      const double gapHi = iHigh(sym, tf, i + 2);
      if(gapLo > gapHi + pt)
      {
         fTop = gapLo;
         fBot = gapHi;
         fShift = i;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool FindBullishFvg(const string sym, const ENUM_TIMEFRAMES tf,
                    const int shiftFrom, const int shiftTo,
                    double &fTop, double &fBot, int &fShift)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const int lo = MathMin(shiftFrom, shiftTo);
   const int hi = MathMax(shiftFrom, shiftTo);

   for(int i = lo; i <= hi; i++)
   {
      if(i + 2 >= Bars(sym, tf))
         continue;
      const double gapHi = iHigh(sym, tf, i);
      const double gapLo = iLow(sym, tf, i + 2);
      if(gapLo > gapHi + pt)
      {
         fTop = gapLo;
         fBot = gapHi;
         fShift = i;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool WasLiquiditySweepHigh(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shift, const double liq,
                           const double sweepTol, double &sweepHigh)
{
   const double h = iHigh(sym, tf, shift);
   const double c = iClose(sym, tf, shift);
   if(h <= liq + sweepTol || c >= liq)
      return false;
   sweepHigh = h;
   return true;
}

//+------------------------------------------------------------------+
bool WasLiquiditySweepLow(const string sym, const ENUM_TIMEFRAMES tf,
                          const int shift, const double liq,
                          const double sweepTol, double &sweepLow)
{
   const double l = iLow(sym, tf, shift);
   const double c = iClose(sym, tf, shift);
   if(l >= liq - sweepTol || c <= liq)
      return false;
   sweepLow = l;
   return true;
}

//+------------------------------------------------------------------+
void BreakerFromShift(const string sym, const ENUM_TIMEFRAMES tf,
                      const int shift, const bool isBuy,
                      double &top, double &bottom)
{
   const double o = iOpen(sym, tf, shift);
   const double c = iClose(sym, tf, shift);
   const double h = iHigh(sym, tf, shift);
   const double l = iLow(sym, tf, shift);
   top    = MathMax(o, c);
   bottom = MathMin(o, c);
   if(top <= bottom + _Point)
   {
      top    = h;
      bottom = l;
   }
}

//+------------------------------------------------------------------+
bool DetectBearishMssSetup(const string sym, const ENUM_TIMEFRAMES tf,
                           IctMssSetup &out)
{
   ZeroMemory(out);
   if(!g_small.hasL0 || !g_small.hasH0 || !g_zone.valid)
      return false;

   const double atr = GetAtr(sym, tf, 1);
   if(atr <= 0.0)
      return false;

   const double sweepTol = SweepTolerance(sym, atr);
   const double bosTol   = BosTolerance(sym, atr);
   const double liq = g_small.hasH1
                      ? MathMax(g_small.h0.price, g_small.h1.price)
                      : g_small.h0.price;
   const double broken = g_small.l0.price;
   const int brShift = MathMax(1, g_small.l0.shift);
   const int maxMss = MathMax(2, InpMssMaxRecent);

   for(int mssSh = 2; mssSh <= maxMss; mssSh++)
   {
      const double cMss = iClose(sym, tf, mssSh);
      if(cMss >= broken - bosTol)
         continue;

      const double body = MathAbs(iClose(sym, tf, mssSh) - iOpen(sym, tf, mssSh));
      if(body < atr * InpMssDispAtrMult)
         continue;

      int sweepSh = -1;
      double sweepHi = 0.0;
      for(int sw = mssSh + 1; sw <= InpMssLookback; sw++)
      {
         double sh = 0.0;
         if(WasLiquiditySweepHigh(sym, tf, sw, liq, sweepTol, sh))
         {
            sweepSh = sw;
            sweepHi = sh;
            break;
         }
      }
      if(sweepSh < 0)
         continue;

      double fTop = 0.0, fBot = 0.0;
      int fSh = -1;
      const bool hasFvg = FindBearishFvg(sym, tf, mssSh, sweepSh + 2, fTop, fBot, fSh);
      if(InpRequireFvg && !hasFvg)
         continue;

      double brTop = 0.0, brBot = 0.0;
      BreakerFromShift(sym, tf, brShift, false, brTop, brBot);
      const double entry = brTop + atr * InpBreakerOffsetAtr;

      const double slBuf = atr * InpSlAtrMult;
      const double tpBuf = atr * InpTpAtrBuffer;
      const double sl = sweepHi + slBuf;
      const double tp = g_zone.waveLow + tpBuf;

      out.valid = true;
      out.isBuy = false;
      out.liqLevel = liq;
      out.sweepExtreme = sweepHi;
      out.sweepShift = sweepSh;
      out.brokenLevel = broken;
      out.brokenShift = brShift;
      out.breakerTop = brTop;
      out.breakerBottom = brBot;
      out.entry = entry;
      out.sl = sl;
      out.tp = tp;
      out.hasFvg = hasFvg;
      out.fvgTop = fTop;
      out.fvgBottom = fBot;
      out.fvgShift = fSh;
      out.mssShift = mssSh;
      out.summary = StringFormat("SELL MSS | sweep H%.5f → BOS L%.5f | breaker %.5f",
                                 sweepHi, broken, entry);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool DetectBullishMssSetup(const string sym, const ENUM_TIMEFRAMES tf,
                           IctMssSetup &out)
{
   ZeroMemory(out);
   if(!g_small.hasH0 || !g_small.hasL0 || !g_zone.valid)
      return false;

   const double atr = GetAtr(sym, tf, 1);
   if(atr <= 0.0)
      return false;

   const double sweepTol = SweepTolerance(sym, atr);
   const double bosTol   = BosTolerance(sym, atr);
   const double liq = g_small.hasL1
                      ? MathMin(g_small.l0.price, g_small.l1.price)
                      : g_small.l0.price;
   const double broken = g_small.h0.price;
   const int brShift = MathMax(1, g_small.h0.shift);
   const int maxMss = MathMax(2, InpMssMaxRecent);

   for(int mssSh = 2; mssSh <= maxMss; mssSh++)
   {
      const double cMss = iClose(sym, tf, mssSh);
      if(cMss <= broken + bosTol)
         continue;

      const double body = MathAbs(iClose(sym, tf, mssSh) - iOpen(sym, tf, mssSh));
      if(body < atr * InpMssDispAtrMult)
         continue;

      int sweepSh = -1;
      double sweepLo = 0.0;
      for(int sw = mssSh + 1; sw <= InpMssLookback; sw++)
      {
         double slv = 0.0;
         if(WasLiquiditySweepLow(sym, tf, sw, liq, sweepTol, slv))
         {
            sweepSh = sw;
            sweepLo = slv;
            break;
         }
      }
      if(sweepSh < 0)
         continue;

      double fTop = 0.0, fBot = 0.0;
      int fSh = -1;
      const bool hasFvg = FindBullishFvg(sym, tf, mssSh, sweepSh + 2, fTop, fBot, fSh);
      if(InpRequireFvg && !hasFvg)
         continue;

      double brTop = 0.0, brBot = 0.0;
      BreakerFromShift(sym, tf, brShift, true, brTop, brBot);
      const double entry = brBot - atr * InpBreakerOffsetAtr;

      const double slBuf = atr * InpSlAtrMult;
      const double tpBuf = atr * InpTpAtrBuffer;
      const double sl = sweepLo - slBuf;
      const double tp = g_zone.waveHigh - tpBuf;

      out.valid = true;
      out.isBuy = true;
      out.liqLevel = liq;
      out.sweepExtreme = sweepLo;
      out.sweepShift = sweepSh;
      out.brokenLevel = broken;
      out.brokenShift = brShift;
      out.breakerTop = brTop;
      out.breakerBottom = brBot;
      out.entry = entry;
      out.sl = sl;
      out.tp = tp;
      out.hasFvg = hasFvg;
      out.fvgTop = fTop;
      out.fvgBottom = fBot;
      out.fvgShift = fSh;
      out.mssShift = mssSh;
      out.summary = StringFormat("BUY MSS | sweep L%.5f → BOS H%.5f | breaker %.5f",
                                 sweepLo, broken, entry);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool DetectMssSetup(const string sym, const ENUM_TIMEFRAMES tf, IctMssSetup &out)
{
   if(g_biasBuy)
      return DetectBullishMssSetup(sym, tf, out);
   return DetectBearishMssSetup(sym, tf, out);
}

//+------------------------------------------------------------------+
bool MssSetupReady()
{
   return g_setup.valid;
}

//+------------------------------------------------------------------+
double NormalizeVolume(const string sym, double v)
{
   const double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   const double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      return 0.0;
   v = MathFloor(v / step) * step;
   if(v < vmin - 1e-12)
      return 0.0;
   if(v > vmax)
      v = vmax;
   return NormalizeDouble(v, 8);
}

//+------------------------------------------------------------------+
double VolumeForRisk(const string sym, const bool isBuy,
                     const double entry, const double sl)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(MathAbs(entry - sl) < pt)
      return 0.0;
   const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double profit = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       sym, 1.0, entry, sl, profit))
      return 0.0;
   const double lossPerLot = MathAbs(profit);
   if(lossPerLot < DBL_EPSILON)
      return 0.0;
   return riskMoney / lossPerLot;
}

//+------------------------------------------------------------------+
double CalcRiskReward(const bool isBuy, const double entry,
                    const double sl, const double tp)
{
   const double risk = isBuy ? (entry - sl) : (sl - entry);
   const double reward = isBuy ? (tp - entry) : (entry - tp);
   if(risk <= _Point || reward <= 0.0)
      return 0.0;
   return reward / risk;
}

//+------------------------------------------------------------------+
bool IsRiskRewardOk(const bool isBuy, const double entry,
                    const double sl, const double tp, double &outRR)
{
   outRR = CalcRiskReward(isBuy, entry, sl, tp);
   if(!InpUseMinRR)
      return true;
   const double minRR = MathMax(0.1, InpMinRR);
   return (outRR >= minRR - 1e-8);
}

//+------------------------------------------------------------------+
bool StopsValid(const string sym, const bool isBuy,
                const double entry, const double sl, const double tp)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const int stops = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   const double md = MathMax(stops, freeze) * pt;
   if(md <= 0.0)
      return true;
   if(isBuy)
   {
      if(entry - sl < md - pt) return false;
      if(tp - entry < md - pt) return false;
   }
   else
   {
      if(sl - entry < md - pt) return false;
      if(entry - tp < md - pt) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void CancelMyPendingLimits(const string sym)
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
         g_trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
void ManagePendingLimits(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!HasMyPendingLimit(sym))
      return;

   if(InpUseSessionFilter && !IsTradeSessionAllowed())
   {
      CancelMyPendingLimits(sym);
      if(g_state == ICT_STATE_LIMIT_ORDERED)
         g_state = ICT_STATE_WAITING_TRIGGER;
      Dbg("Hủy limit — ngoài phiên London/NY");
      return;
   }

   const datetime t0 = iTime(sym, tf, 0);
   if(t0 == 0 || g_limitPlacedBar == 0)
      return;

   const int barsWait = iBarShift(sym, tf, g_limitPlacedBar, true);
   if(barsWait >= InpLimitExpireBars)
   {
      CancelMyPendingLimits(sym);
      g_state = ICT_STATE_WAITING_TRIGGER;
      Dbg("Hủy limit — hết hạn " + IntegerToString(InpLimitExpireBars) + " nến");
      return;
   }

   if(!g_setup.valid)
      return;

   const double live = g_setup.isBuy
                       ? MathMin(iLow(sym, tf, 0), iLow(sym, tf, 1))
                       : MathMax(iHigh(sym, tf, 0), iHigh(sym, tf, 1));

   if(!g_setup.isBuy && live > g_setup.sweepExtreme + SweepTolerance(sym, GetAtr(sym, tf, 1)))
   {
      CancelMyPendingLimits(sym);
      g_state = ICT_STATE_WAITING_TRIGGER;
      Dbg("Hủy SELL limit — phá lại trên sweep");
   }
   else if(g_setup.isBuy && live < g_setup.sweepExtreme - SweepTolerance(sym, GetAtr(sym, tf, 1)))
   {
      CancelMyPendingLimits(sym);
      g_state = ICT_STATE_WAITING_TRIGGER;
      Dbg("Hủy BUY limit — phá lại dưới sweep");
   }
}

//+------------------------------------------------------------------+
bool TryPlaceMssLimit(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!InpTradeEnabled)
      return false;
   if(!IsTradeSessionAllowed())
   {
      Dbg("MSS skip: ngoài phiên London/NY");
      return false;
   }
   if(g_state != ICT_STATE_WAITING_TRIGGER)
      return false;
   if(InpOnePosition && HasMyPosition(sym))
      return false;
   if(HasMyPendingLimit(sym))
      return false;

   const datetime tBar = iTime(sym, tf, 1);
   if(tBar == 0 || tBar == g_lastTriggerBar)
      return false;

   const double refClose = iClose(sym, tf, 1);
   if(g_biasBuy)
   {
      if(!PriceInDiscount(refClose))
         return false;
   }
   else
   {
      if(!PriceInPremium(refClose))
         return false;
   }

   IctMssSetup setup;
   if(!DetectMssSetup(sym, tf, setup))
   {
      g_setup.valid = false;
      return false;
   }
   g_setup = setup;

   const int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   const double entry = NormalizeDouble(setup.entry, dig);
   const double sl    = NormalizeDouble(setup.sl, dig);
   const double tp    = NormalizeDouble(setup.tp, dig);

   MqlTick tk;
   if(!SymbolInfoTick(sym, tk))
      return false;

   if(setup.isBuy)
   {
      if(tp <= entry || sl >= entry || entry >= tk.ask - _Point)
      {
         Dbg("MSS Buy skip: entry/TP/SL");
         return false;
      }
   }
   else
   {
      if(tp >= entry || sl <= entry || entry <= tk.bid + _Point)
      {
         Dbg("MSS Sell skip: entry/TP/SL");
         return false;
      }
   }

   if(!StopsValid(sym, setup.isBuy, entry, sl, tp))
   {
      Dbg("MSS skip: STOPS_LEVEL");
      return false;
   }

   double rr = 0.0;
   if(!IsRiskRewardOk(setup.isBuy, entry, sl, tp, rr))
   {
      Dbg(StringFormat("MSS skip: R:R %.2f < 1:%.2f", rr, InpMinRR));
      return false;
   }

   double vol = NormalizeVolume(sym, VolumeForRisk(sym, setup.isBuy, entry, sl));
   if(vol <= 0.0)
   {
      Dbg("MSS skip: volume=0");
      return false;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   SetTradeFilling();

   const datetime exp = tBar + (datetime)(PeriodSeconds(tf) * MathMax(1, InpLimitExpireBars));
   const string cmt = setup.isBuy ? "MyICT_BUY_BB" : "MyICT_SELL_BB";
   const bool ok = setup.isBuy
                   ? g_trade.BuyLimit(vol, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cmt)
                   : g_trade.SellLimit(vol, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, exp, cmt);

   if(!ok)
   {
      Print("[MyICT] MSS limit fail ", g_trade.ResultRetcode(), " ", g_trade.ResultComment());
      return false;
   }

   g_lastTriggerBar = tBar;
   g_limitPlacedBar = tBar;
   g_state = ICT_STATE_LIMIT_ORDERED;
   PrintFormat("[MyICT] %s | vol=%.2f entry=%.5f SL=%.5f TP=%.5f R:R=1:%.2f | %s",
               cmt, vol, entry, sl, tp, rr, setup.summary);
   return true;
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
bool BigIsBearish()
{
   if(g_big.trend == ICT_TREND_DOWN)
      return true;
   return (g_big.hasH0 && g_big.hasH1 && g_big.h0.price < g_big.h1.price);
}

//+------------------------------------------------------------------+
bool BigIsBullish()
{
   if(g_big.trend == ICT_TREND_UP)
      return true;
   return (g_big.hasH0 && g_big.hasH1 && g_big.h0.price > g_big.h1.price);
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
double ExtremeLowBetween(const string sym, const ENUM_TIMEFRAMES tf,
                           const int shiftFrom, const int shiftTo)
{
   double mn = DBL_MAX;
   const int lo = MathMin(shiftFrom, shiftTo);
   const int hi = MathMax(shiftFrom, shiftTo);
   for(int sh = lo; sh <= hi; sh++)
   {
      const double l = iLow(sym, tf, sh);
      if(l < mn)
         mn = l;
   }
   return (mn == DBL_MAX ? 0.0 : mn);
}

//+------------------------------------------------------------------+
double ExtremeHighBetween(const string sym, const ENUM_TIMEFRAMES tf,
                            const int shiftFrom, const int shiftTo)
{
   double mx = 0.0;
   const int lo = MathMin(shiftFrom, shiftTo);
   const int hi = MathMax(shiftFrom, shiftTo);
   for(int sh = lo; sh <= hi; sh++)
   {
      const double h = iHigh(sym, tf, sh);
      if(h > mx)
         mx = h;
   }
   return mx;
}

//+------------------------------------------------------------------+
void CalcBigWaveZone(const string sym, const ENUM_TIMEFRAMES tf)
{
   ZeroMemory(g_zone);
   if(!g_big.hasH0 || !g_big.hasL0)
      return;

   g_zone.legExtended = false;
   g_zone.waveHigh = g_big.h0.price;
   g_zone.waveLow  = g_big.l0.price;

   const double atr = GetAtr(sym, tf, 1);
   const double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   const double tol = MathMax(pt * 5.0, (atr > 0.0 ? atr * 0.05 : pt * 10.0));

   const int shH0 = MathMax(0, g_big.h0.shift);
   const int shL0 = MathMax(0, g_big.l0.shift);
   const int shNow = 0;   // gồm nến đang hình thành (trước chỉ tới shift=1 → trễ)

   const double liveLow  = MathMin(iLow(sym, tf, 0),  iLow(sym, tf, 1));
   const double liveHigh = MathMax(iHigh(sym, tf, 0), iHigh(sym, tf, 1));

   // Big giảm + giá phá dưới Big L0 → H0 → đáy mới (logic; draw dùng cùng g_zone)
   if(BigIsBearish() && liveLow < g_big.l0.price - tol)
   {
      double extLow = ExtremeLowBetween(sym, tf, shH0, shNow);
      if(extLow <= 0.0)
         extLow = liveLow;
      else
         extLow = MathMin(extLow, liveLow);

      g_zone.waveHigh = g_big.h0.price;
      g_zone.waveLow  = extLow;
      g_zone.legExtended = (extLow < g_big.l0.price - tol * 0.5);
   }
   // Big tăng + giá phá trên Big H0 → L0 → đỉnh mới
   else if(BigIsBullish() && liveHigh > g_big.h0.price + tol)
   {
      double extHigh = ExtremeHighBetween(sym, tf, shL0, shNow);
      if(extHigh <= 0.0)
         extHigh = liveHigh;
      else
         extHigh = MathMax(extHigh, liveHigh);

      g_zone.waveLow  = g_big.l0.price;
      g_zone.waveHigh = extHigh;
      g_zone.legExtended = (extHigh > g_big.h0.price + tol * 0.5);
   }

   if(g_zone.waveHigh < g_zone.waveLow)
   {
      const double t = g_zone.waveHigh;
      g_zone.waveHigh = g_zone.waveLow;
      g_zone.waveLow  = t;
   }

   const double range = g_zone.waveHigh - g_zone.waveLow;
   if(range <= _Point * 2)
      return;

   const double pct = MathMax(1.0, MathMin(99.0, InpZoneEqPct)) / 100.0;
   g_zone.equilibrium   = g_zone.waveLow + range * pct;
   g_zone.discountTop   = g_zone.equilibrium;
   g_zone.premiumBottom = g_zone.equilibrium;
   g_zone.valid = true;

   if(g_zone.legExtended && InpDebug)
      Dbg(StringFormat("Zone extended | H=%.5f L=%.5f Eq=%.5f liveL=%.5f",
           g_zone.waveHigh, g_zone.waveLow, g_zone.equilibrium, liveLow));
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
ENUM_ICT_STATE ComputeStructureState(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!BigTrendIsClear())
      return ICT_STATE_NO_TREND;

   if(!IsPullbackStructure())
      return ICT_STATE_NO_TREND;

   CalcBigWaveZone(sym, tf);

   const double refPrice = g_biasBuy
                           ? MathMin(iClose(sym, tf, 0), iClose(sym, tf, 1))
                           : MathMax(iClose(sym, tf, 0), iClose(sym, tf, 1));

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

   ManagePendingLimits(sym, tf);

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
      TryPlaceMssLimit(sym, tf);

   if(g_state != g_statePrev && InpDebug)
      Dbg(StringFormat("State %s → %s", StateText(g_statePrev), StateText(g_state)));
}

//+------------------------------------------------------------------+
void DrawArrowTag(const string tag, const datetime t, const double price,
                  const bool isHigh, const string label, const color clr,
                  const int width)
{
   const long ch = ActChart();
   const string arr = OBJ_CH_PFX + tag + "_AR";
   const string txt = OBJ_CH_PFX + tag + "_TX";

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
      DrawSegLine(OBJ_CH_PFX + tag + "_LNH", snap.h1.time, snap.h1.price,
                  snap.h0.time, snap.h0.price, clrHi, lineWidth);
   if(snap.hasL0 && snap.hasL1)
      DrawSegLine(OBJ_CH_PFX + tag + "_LNL", snap.l1.time, snap.l1.price,
                  snap.l0.time, snap.l0.price, clrLo, lineWidth);
}

//+------------------------------------------------------------------+
void DrawZones(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!InpDrawZones || !g_zone.valid)
      return;

   const datetime t2 = iTime(sym, tf, 0) + (datetime)PeriodSeconds(tf);
   datetime t1 = iTime(sym, tf, MathMin(60, Bars(sym, tf) - 1));
   if(g_zone.legExtended)
   {
      if(BigIsBearish() && g_big.hasH0)
         t1 = g_big.h0.time;
      else if(BigIsBullish() && g_big.hasL0)
         t1 = g_big.l0.time;
   }
   if(t1 == 0 || t2 == 0)
      return;

   const bool activePullback = (g_state == ICT_STATE_PULLBACK
                              || g_state == ICT_STATE_WAITING_TRIGGER);
   const uchar discAlpha = (activePullback && g_biasBuy)
                           ? InpZoneActiveAlpha : InpZoneFillAlpha;
   const uchar premAlpha = (activePullback && !g_biasBuy)
                           ? InpZoneActiveAlpha : InpZoneFillAlpha;

   const string extTip = g_zone.legExtended ? " (kéo theo giá)" : "";
   DrawZoneRect(OBJ_CH_PFX + "Z_DISC", t1, t2,
                g_zone.discountTop, g_zone.waveLow,
                InpClrDiscount, discAlpha,
                "Discount — nửa dưới sóng Big" + extTip);

   DrawZoneRect(OBJ_CH_PFX + "Z_PREM", t1, t2,
                g_zone.waveHigh, g_zone.premiumBottom,
                InpClrPremium, premAlpha,
                "Premium — nửa trên sóng Big" + extTip);

   DrawSegLine(OBJ_CH_PFX + "Z_EQ", t1, g_zone.equilibrium, t2, g_zone.equilibrium,
               clrGold, 1);
   ObjectSetInteger(ActChart(), OBJ_CH_PFX + "Z_EQ", OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(ActChart(), OBJ_CH_PFX + "Z_EQ", OBJPROP_WIDTH, 2);

   const double midDisc = (g_zone.waveLow + g_zone.discountTop) * 0.5;
   const double midPrem = (g_zone.premiumBottom + g_zone.waveHigh) * 0.5;
   DrawZoneTag(OBJ_CH_PFX + "LBL_DISC", t2, midDisc, " DISCOUNT ", InpClrZoneLabel);
   DrawZoneTag(OBJ_CH_PFX + "LBL_PREM", t2, midPrem, " PREMIUM ", InpClrZoneLabel);
}

//+------------------------------------------------------------------+
void DrawMssSetup(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!InpDrawMssSetup || !g_setup.valid)
      return;

   const int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   const datetime tBr = iTime(sym, tf, g_setup.brokenShift);
   const datetime tSw = iTime(sym, tf, g_setup.sweepShift);
   const datetime tEnd = iTime(sym, tf, 0) + (datetime)PeriodSeconds(tf);

   DrawSegLine(OBJ_CH_PFX + "MSS_LIQ", tSw, g_setup.liqLevel, tEnd, g_setup.liqLevel,
               InpClrSweep, 1);
   ObjectSetInteger(ActChart(), OBJ_CH_PFX + "MSS_LIQ", OBJPROP_STYLE, STYLE_DASH);

   DrawZoneRect(OBJ_CH_PFX + "MSS_BRK", tBr, tEnd,
                g_setup.breakerTop, g_setup.breakerBottom,
                InpClrBreaker, 90,
                "Breaker block — limit entry");

   DrawSegLine(OBJ_CH_PFX + "MSS_ENT", tBr, g_setup.entry, tEnd, g_setup.entry,
               clrWhite, 2);

   if(g_setup.hasFvg && g_setup.fvgShift > 0)
   {
      const datetime tF = iTime(sym, tf, g_setup.fvgShift);
      DrawZoneRect(OBJ_CH_PFX + "MSS_FVG", tF, tEnd,
                   g_setup.fvgTop, g_setup.fvgBottom,
                   InpClrFvg, 110, "FVG");
   }

   DrawZoneTag(OBJ_CH_PFX + "MSS_LBL", tEnd, g_setup.entry,
               g_setup.isBuy ? " BUY LMT " : " SELL LMT ", InpClrBreaker);
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
   {
      s += StringFormat("\n  Zone H=%.2f L=%.2f Eq=%.2f (%.0f%%)",
                        g_zone.waveHigh, g_zone.waveLow, g_zone.equilibrium, InpZoneEqPct);
      s += g_zone.legExtended ? " [sóng kéo theo giá]" : " [H0-L0]";
      s += StringFormat(" | %s", g_biasBuy ? "Discount" : "Premium");
   }
   if(g_setup.valid)
   {
      s += "\n  " + g_setup.summary;
      double rr = CalcRiskReward(g_setup.isBuy, g_setup.entry, g_setup.sl, g_setup.tp);
      if(rr > 0.0)
      {
         s += StringFormat(" | R:R=1:%.2f", rr);
         if(InpUseMinRR && rr < InpMinRR - 1e-8)
            s += StringFormat(" (< 1:%.1f)", InpMinRR);
      }
   }
   s += "\n  " + SessionStatusText();
   return s;
}

//+------------------------------------------------------------------+
void DrawPanel(const string body)
{
   const long ch = ActChart();
   const string name = OBJ_CH_PFX + "PANEL";

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
void StatsEnsureLabel(const long ch, const string name, const int yDist)
{
   if(ObjectFind(ch, name) < 0)
      ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(ch, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(ch, name, OBJPROP_XDISTANCE, InpStatCornerX);
   ObjectSetInteger(ch, name, OBJPROP_YDISTANCE, MathMax(0, yDist));
   ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, MathMax(7, InpStatFontSize));
   ObjectSetString(ch, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(ch, name, OBJPROP_COLOR, InpStatColor);
}

//+------------------------------------------------------------------+
void StatsUpdate()
{
   if(!InpShowStats)
   {
      ObjectDelete(ActChart(), STAT_LINE1);
      ObjectDelete(ActChart(), STAT_LINE2);
      return;
   }

   const long ch = ActChart();
   const int gap = (int)(MathMax(7, InpStatFontSize) * 2.2) + 12;
   StatsEnsureLabel(ch, STAT_LINE1, InpStatCornerY);
   StatsEnsureLabel(ch, STAT_LINE2, InpStatCornerY + gap);

   const long closed = g_statWins + g_statLoss;
   const double wr = (closed > 0) ? 100.0 * (double)g_statWins / (double)closed : 0.0;

   const string l1 = StringFormat("MyICT | 1R=%.1f%% | SL/TP ATR×", InpRiskPercent);
   string l2;
   if(closed > 0)
      l2 = StringFormat("Đóng %I64d | Thắng %I64d | Thua %I64d | Winrate %.1f%%",
                        g_statTotal, g_statWins, g_statLoss, wr);
   else
      l2 = StringFormat("Đóng %I64d | Thắng %I64d | Thua %I64d | Winrate: —",
                        g_statTotal, g_statWins, g_statLoss);

   ObjectSetString(ch, STAT_LINE1, OBJPROP_TEXT, l1);
   ObjectSetString(ch, STAT_LINE2, OBJPROP_TEXT, l2);
}

//+------------------------------------------------------------------+
void StatsCountExitDeal(const ulong dealTicket)
{
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   g_statTotal++;
   const ENUM_DEAL_REASON dr = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   if(dr == DEAL_REASON_TP)
      g_statWins++;
   else if(dr == DEAL_REASON_SL)
      g_statLoss++;
   else
   {
      const double net = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      if(net > 0.0) g_statWins++;
      else if(net < 0.0) g_statLoss++;
   }
}

//+------------------------------------------------------------------+
void StatsRebuildFromHistory()
{
   g_statWins = g_statLoss = g_statTotal = 0;
   if(!HistorySelect(0, TimeCurrent()))
      return;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
      StatsCountExitDeal(HistoryDealGetTicket(i));
}

//+------------------------------------------------------------------+
void RedrawChart(const string sym, const ENUM_TIMEFRAMES tf)
{
   DeleteObjectsByPrefix(OBJ_CH_PFX);

   string panel = StringFormat("MyICT | %s %s\n", sym, EnumToString(tf));
   panel += StateBlock() + "\n";
   if(InpUseSessionFilter && !IsTradeSessionAllowed())
      panel += "  >> Session CLOSED — không đặt lệnh mới\n";
   if(g_state == ICT_STATE_WAITING_TRIGGER && g_setup.valid)
   {
      const double rrPrev = CalcRiskReward(g_setup.isBuy, g_setup.entry, g_setup.sl, g_setup.tp);
      if(InpUseMinRR && rrPrev > 0.0 && rrPrev < InpMinRR - 1e-8)
         panel += StringFormat("  >> MSS OK nhưng R:R 1:%.2f < 1:%.1f — bỏ qua\n", rrPrev, InpMinRR);
      else
         panel += "  >> MSS setup OK — chờ limit breaker\n";
   }
   else if(g_state == ICT_STATE_LIMIT_ORDERED)
      panel += "  >> Limit breaker đang chờ khớp\n";
   panel += LayerBlock("BigTrend", InpBigSwingRange, g_big) + "\n";
   panel += LayerBlock("SmallTrend", InpSmallSwingRange, g_small);

   DrawPanel(panel);
   DrawLayer("BIG", g_big, InpClrBigHigh, InpClrBigLow, 2);
   DrawLayer("SML", g_small, InpClrSmallHigh, InpClrSmallLow, 1);
   DrawZones(sym, tf);

   if(g_state == ICT_STATE_LIMIT_ORDERED)
   {
      // giữ setup đã đặt limit
   }
   else if(g_state == ICT_STATE_WAITING_TRIGGER || g_state == ICT_STATE_PULLBACK)
   {
      IctMssSetup tmp;
      if(DetectMssSetup(sym, tf, tmp))
         g_setup = tmp;
      else if(g_state != ICT_STATE_WAITING_TRIGGER)
         g_setup.valid = false;
   }
   else
      g_setup.valid = false;

   DrawMssSetup(sym, tf);
   StatsUpdate();
   ChartRedraw(ActChart());
}

//+------------------------------------------------------------------+
void OnNewBar(const string sym)
{
   const ENUM_TIMEFRAMES tf = ChartTf();

   AnalyzeLayer(sym, tf, InpBigSwingRange, g_big);
   AnalyzeLayer(sym, tf, InpSmallSwingRange, g_small);

   if(g_big.hasH0 && g_big.hasL0)
      CalcBigWaveZone(sym, tf);

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
   g_lastTriggerBar = 0;
   g_limitPlacedBar = 0;
   ZeroMemory(g_setup);
   g_state = ICT_STATE_NO_TREND;
   g_statePrev = ICT_STATE_NO_TREND;

   g_hAtr = iATR(_Symbol, ChartTf(), InpATRPeriod);
   if(g_hAtr == INVALID_HANDLE)
   {
      Print("[MyICT] Không tạo ATR");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   SetTradeFilling();

   StatsRebuildFromHistory();
   OnNewBar(_Symbol);
   Print("[MyICT] Init state=", StateText(g_state));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteObjectsByPrefix(OBJ_CH_PFX);
   ObjectDelete(ActChart(), STAT_LINE1);
   ObjectDelete(ActChart(), STAT_LINE2);
   if(g_hAtr != INVALID_HANDLE)
      IndicatorRelease(g_hAtr);
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

   StatsCountExitDeal(deal);
   g_state = ICT_STATE_NONE;
   Dbg("OnTradeTransaction → NONE (đóng lệnh)");
   RedrawChart(_Symbol, ChartTf());
}

//+------------------------------------------------------------------+
void RefreshZoneDraw(const string sym, const ENUM_TIMEFRAMES tf)
{
   if(!g_big.hasH0 || !g_big.hasL0)
      return;
   CalcBigWaveZone(sym, tf);
   if(InpDrawZones && g_zone.valid)
   {
      DrawZones(sym, tf);
      ChartRedraw(ActChart());
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   const string sym = _Symbol;
   const ENUM_TIMEFRAMES tf = ChartTf();
   const datetime t0 = iTime(sym, tf, 0);
   if(t0 == 0)
      return;

   if(t0 != g_lastBar)
   {
      g_lastBar = t0;
      OnNewBar(sym);
      return;
   }

   RefreshZoneDraw(sym, tf);
   ManagePendingLimits(sym, tf);
}

//+------------------------------------------------------------------+
ENUM_ICT_STATE GetIctState()     { return g_state; }
ENUM_ICT_TREND GetBigTrend()     { return g_big.trend; }
ENUM_ICT_TREND GetSmallTrend()   { return g_small.trend; }
