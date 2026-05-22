//+------------------------------------------------------------------+
//| EmaPullbackBasic.mq5 — EMA50 pullback EA (phased build)           |
//| Phase 4: breakout khỏi nến touch (cửa sổ N nến)                   |
//| Phase 5: risk 1% R, TP 1.5R                                       |
//+------------------------------------------------------------------+
#property copyright "EMA Pullback Basic"
#property version   "0.52"
#property description "EMA pullback + reject entry, 1% risk, TP 1.5R"

#include <Trade\Trade.mqh>

enum ENUM_MARKET_STATE {
   MARKET_NO_TRADE   = 0,
   MARKET_SIDEWAY    = 1,
   MARKET_TREND_UP   = 2,
   MARKET_TREND_DOWN = 3
};

enum ENUM_SETUP_STATE {
   SETUP_IDLE             = 0,
   SETUP_PULLBACK_ACTIVE  = 1,
   SETUP_TOUCHED          = 2
};

//--- inputs
input group           "=== Indicators ==="
input int             InpEmaPeriod          = 50;
input int             InpAdxPeriod          = 14;
input int             InpAtrPeriod          = 14;

input group           "=== Regime (Phase 2) ==="
input bool            InpRegimeEnabled      = true;
input double          InpMinAdx             = 22.0;
input double          InpSidewayAdxMax      = 20.0;
input int             InpEmaSlopeBars       = 10;
input double          InpMinEmaSlope        = 0.50;
input double          InpSidewayMaxEmaSlope = 0.35;
input bool            InpRequireEmaDirection = true;

input group           "=== Pullback & touch (Phase 3) ==="
input double          InpTouchEmaAtr        = 0.25;
input int             InpPullbackLookback   = 20;
input double          InpPullbackMinDistAtr = 1;
input double          InpPullbackRetraceFrac = 0.40;
input int             InpMaxBarsPullback    = 20;
input bool            InpRequireCloseVsEmaOnTouch = true;
input bool            InpDrawSetupMarkers   = true;

input group           "=== Entry breakout (Phase 4) ==="
input int             InpMaxBarsWaitBreakout = 5;     // Sau touch: chờ breakout tối đa N nến
input bool            InpBreakoutUseTouchHighLow = true; // Buy: Close > High touch; Sell: Close < Low touch
input bool            InpRequireBreakoutCandleColor = true; // Buy: bullish, Sell: bearish

input group           "=== Risk (Phase 5) ==="
input bool            InpTradeEnabled       = true;
input double          InpRiskPercent        = 1.0;    // R = % balance
input double          InpTpRR               = 1.5;    // TP = InpTpRR × SL distance
input double          InpSlBufferAtr        = 0.10;   // SL dưới đáy/ trên đỉnh + buffer × ATR
input int             InpMaxBarsInTrade     = 0;      // 0 = không đóng theo thời gian

input group           "=== EA ==="
input ulong           InpMagic              = 20260522;
input int             InpSlippage           = 10;
input bool            InpLogEachBar         = true;
input bool            InpLogStateChange     = true;
input bool            InpShowComment        = true;
input bool            InpShowStatsPanel     = true;   // Thống kê góc dưới trái

//--- globals
CTrade   g_trade;
int      g_hEma     = INVALID_HANDLE;
int      g_hAdx     = INVALID_HANDLE;
int      g_hAtr     = INVALID_HANDLE;
datetime g_lastBarTime = 0;

ENUM_MARKET_STATE g_marketState = MARKET_NO_TRADE;
string   g_regimeDetail = "";

ENUM_SETUP_STATE g_setupState = SETUP_IDLE;
int      g_setupDir = 0;
int      g_barsInSetupState = 0;
datetime g_touchBarTime = 0;
string   g_setupDetail = "";
string   g_lastStateLog = "";

int      g_statTotal = 0;
int      g_statTP     = 0;
int      g_statSL     = 0;

const string OBJ_PREFIX = "EPB_";

string StatPfx() { return "EPB_ST_" + IntegerToString((int)InpMagic) + "_"; }

//+------------------------------------------------------------------+
string MarketStateToString(const ENUM_MARKET_STATE state) {
   switch(state) {
      case MARKET_TREND_UP:   return "TREND_UP";
      case MARKET_TREND_DOWN: return "TREND_DOWN";
      case MARKET_SIDEWAY:    return "SIDEWAY";
      default:                return "NO_TRADE";
   }
}

string SetupStateToString(const ENUM_SETUP_STATE state) {
   switch(state) {
      case SETUP_PULLBACK_ACTIVE: return "PULLBACK_ACTIVE";
      case SETUP_TOUCHED:       return "TOUCHED";
      default:                  return "IDLE";
   }
}

double NormalizePrice(const double price) {
   const double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   return NormalizeDouble(MathRound(price / tick) * tick, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeLots(double v) {
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) return 0.0;
   v = MathFloor(v / step) * step;
   if(v < vmin - 1e-12) return 0.0;
   if(v > vmax) v = vmax;
   return NormalizeDouble(v, 8);
}

bool Copy1(const int handle, const int bufferIndex, const int shift, double &value) {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, buf) < 1)
      return false;
   value = buf[0];
   return true;
}

bool GetEma(const int shift, double &ema) {
   return Copy1(g_hEma, 0, shift, ema);
}

bool GetAdx(const int shift, double &adx) {
   return Copy1(g_hAdx, 0, shift, adx);
}

bool GetAtr(const int shift, double &atr) {
   return Copy1(g_hAtr, 0, shift, atr);
}

bool ReadIndicatorsAtShift(const int shift,
                           double &ema,
                           double &adx,
                           double &atr,
                           string &err) {
   err = "";
   if(!GetEma(shift, ema)) { err = "EMA CopyBuffer failed"; return false; }
   if(!GetAdx(shift, adx)) { err = "ADX CopyBuffer failed"; return false; }
   if(!GetAtr(shift, atr)) { err = "ATR CopyBuffer failed"; return false; }
   return true;
}

double CalcEmaSlopeAtr(const int shift, const double atr) {
   if(atr <= 0.0 || InpEmaSlopeBars < 1) return 0.0;
   double emaNear = 0.0, emaFar = 0.0;
   if(!GetEma(shift, emaNear) || !GetEma(shift + InpEmaSlopeBars, emaFar))
      return 0.0;
   return MathAbs(emaNear - emaFar) / atr;
}

bool EmaSlopesUp(const int shift) {
   double emaNear = 0.0, emaFar = 0.0;
   if(!GetEma(shift, emaNear) || !GetEma(shift + InpEmaSlopeBars, emaFar))
      return false;
   return emaNear > emaFar + _Point;
}

bool EmaSlopesDown(const int shift) {
   double emaNear = 0.0, emaFar = 0.0;
   if(!GetEma(shift, emaNear) || !GetEma(shift + InpEmaSlopeBars, emaFar))
      return false;
   return emaNear < emaFar - _Point;
}

ENUM_MARKET_STATE ClassifyMarketState(const int shift, string &detail) {
   detail = "";
   if(!InpRegimeEnabled) {
      detail = "regime filter OFF";
      return MARKET_NO_TRADE;
   }

   double ema = 0.0, adx = 0.0, atr = 0.0;
   string err = "";
   if(!ReadIndicatorsAtShift(shift, ema, adx, atr, err)) {
      detail = err;
      return MARKET_NO_TRADE;
   }
   if(atr <= 0.0) {
      detail = "ATR=0";
      return MARKET_NO_TRADE;
   }

   const double emaSlope = CalcEmaSlopeAtr(shift, atr);
   const double close = iClose(_Symbol, _Period, shift);

   if(adx < InpSidewayAdxMax) {
      detail = StringFormat("sideway: ADX %.1f < %.1f", adx, InpSidewayAdxMax);
      return MARKET_SIDEWAY;
   }
   if(emaSlope < InpSidewayMaxEmaSlope) {
      detail = StringFormat("sideway: slope %.2f < %.2f", emaSlope, InpSidewayMaxEmaSlope);
      return MARKET_SIDEWAY;
   }
   if(adx < InpMinAdx) {
      detail = StringFormat("ADX %.1f < %.1f", adx, InpMinAdx);
      return MARKET_NO_TRADE;
   }
   if(emaSlope < InpMinEmaSlope) {
      detail = StringFormat("slope %.2f < %.2f", emaSlope, InpMinEmaSlope);
      return MARKET_NO_TRADE;
   }

   if(close > ema + _Point) {
      if(InpRequireEmaDirection && !EmaSlopesUp(shift)) {
         detail = "giá trên EMA, EMA không dốc lên";
         return MARKET_NO_TRADE;
      }
      detail = StringFormat("OK UP | ADX=%.1f", adx);
      return MARKET_TREND_UP;
   }

   if(close < ema - _Point) {
      if(InpRequireEmaDirection && !EmaSlopesDown(shift)) {
         detail = "giá dưới EMA, EMA không dốc xuống";
         return MARKET_NO_TRADE;
      }
      detail = StringFormat("OK DOWN | ADX=%.1f", adx);
      return MARKET_TREND_DOWN;
   }

   detail = "Close ≈ EMA";
   return MARKET_NO_TRADE;
}

bool CanTradeRegime(const ENUM_MARKET_STATE state) {
   return state == MARKET_TREND_UP || state == MARKET_TREND_DOWN;
}

int TradeDirection(const ENUM_MARKET_STATE state) {
   if(state == MARKET_TREND_UP)   return 1;
   if(state == MARKET_TREND_DOWN) return -1;
   return 0;
}

bool PriceTouchedEmaAtShift(const int shift, const double ema, const double atr) {
   const double tol = InpTouchEmaAtr * atr;
   const double h = iHigh(_Symbol, _Period, shift);
   const double l = iLow(_Symbol, _Period, shift);
   return (l <= ema + tol && h >= ema - tol);
}

bool PriceTouchedEmaBuy(const int shift, const double ema, const double atr) {
   if(!PriceTouchedEmaAtShift(shift, ema, atr)) return false;
   if(!InpRequireCloseVsEmaOnTouch) return true;
   return iClose(_Symbol, _Period, shift) >= ema - _Point;
}

bool PriceTouchedEmaSell(const int shift, const double ema, const double atr) {
   if(!PriceTouchedEmaAtShift(shift, ema, atr)) return false;
   if(!InpRequireCloseVsEmaOnTouch) return true;
   return iClose(_Symbol, _Period, shift) <= ema + _Point;
}

bool CalcPullbackExtensionBuy(const int shift, const double atr,
                              double &maxDistAtr, double &distCloseAtr) {
   maxDistAtr = 0.0;
   distCloseAtr = 0.0;
   if(atr <= 0.0) return false;

   const int lb = MathMax(3, InpPullbackLookback);
   for(int s = shift; s < shift + lb; s++) {
      double emaS = 0.0;
      if(!GetEma(s, emaS)) return false;
      const double dist = (iHigh(_Symbol, _Period, s) - emaS) / atr;
      if(dist > maxDistAtr) maxDistAtr = dist;
   }

   double ema0 = 0.0;
   if(!GetEma(shift, ema0)) return false;
   distCloseAtr = (iClose(_Symbol, _Period, shift) - ema0) / atr;
   return true;
}

bool CalcPullbackExtensionSell(const int shift, const double atr,
                               double &maxDistAtr, double &distCloseAtr) {
   maxDistAtr = 0.0;
   distCloseAtr = 0.0;
   if(atr <= 0.0) return false;

   const int lb = MathMax(3, InpPullbackLookback);
   for(int s = shift; s < shift + lb; s++) {
      double emaS = 0.0;
      if(!GetEma(s, emaS)) return false;
      const double dist = (emaS - iLow(_Symbol, _Period, s)) / atr;
      if(dist > maxDistAtr) maxDistAtr = dist;
   }

   double ema0 = 0.0;
   if(!GetEma(shift, ema0)) return false;
   distCloseAtr = (ema0 - iClose(_Symbol, _Period, shift)) / atr;
   return true;
}

bool PullbackStartBuy(const int shift, const double ema, const double atr, string &why) {
   why = "";
   if(iClose(_Symbol, _Period, shift) <= ema + _Point) {
      why = "Close không trên EMA";
      return false;
   }

   double maxDist = 0.0, distClose = 0.0;
   if(!CalcPullbackExtensionBuy(shift, atr, maxDist, distClose)) {
      why = "không tính extension";
      return false;
   }
   if(maxDist < InpPullbackMinDistAtr) {
      why = StringFormat("chưa extension (%.2f)", maxDist);
      return false;
   }
   if(distClose > maxDist * InpPullbackRetraceFrac) {
      why = "chưa hồi đủ về EMA";
      return false;
   }
   why = StringFormat("pullback UP max=%.2f now=%.2f", maxDist, distClose);
   return true;
}

bool PullbackStartSell(const int shift, const double ema, const double atr, string &why) {
   why = "";
   if(iClose(_Symbol, _Period, shift) >= ema - _Point) {
      why = "Close không dưới EMA";
      return false;
   }

   double maxDist = 0.0, distClose = 0.0;
   if(!CalcPullbackExtensionSell(shift, atr, maxDist, distClose)) {
      why = "không tính extension";
      return false;
   }
   if(maxDist < InpPullbackMinDistAtr) {
      why = StringFormat("chưa extension (%.2f)", maxDist);
      return false;
   }
   if(distClose > maxDist * InpPullbackRetraceFrac) {
      why = "chưa hồi đủ về EMA";
      return false;
   }
   why = StringFormat("pullback DOWN max=%.2f now=%.2f", maxDist, distClose);
   return true;
}

bool TrendStructureBrokenBuy(const int shift, const double ema) {
   return iClose(_Symbol, _Period, shift) < ema - _Point;
}

bool TrendStructureBrokenSell(const int shift, const double ema) {
   return iClose(_Symbol, _Period, shift) > ema + _Point;
}

// Tìm shift của bar touch theo thời gian (shift thay đổi khi có bar mới)
int FindTouchBarShift() {
   if(g_touchBarTime == 0)
      return -1;
   const int maxScan = MathMax(InpMaxBarsWaitBreakout + InpMaxBarsPullback + 5, 50);
   for(int s = 1; s <= maxScan; s++) {
      if(iTime(_Symbol, _Period, s) == g_touchBarTime)
         return s;
   }
   return -1;
}

// Số nến đã đóng sau bar touch (signalShift=1 → bar mới nhất)
int BarsAfterTouch(const int touchShift, const int signalShift) {
   if(touchShift < 1 || signalShift >= touchShift)
      return -1;
   return touchShift - signalShift;
}

// Phase 4: breakout khỏi nến touch trong cửa sổ InpMaxBarsWaitBreakout
bool BreakoutSignalBuy(const int signalShift, const int touchShift, string &why) {
   why = "";
   if(touchShift < 1) {
      why = "không có touch bar";
      return false;
   }
   if(signalShift >= touchShift) {
      why = "chờ bar sau touch";
      return false;
   }

   const int barsAfter = BarsAfterTouch(touchShift, signalShift);
   if(barsAfter < 1) {
      why = "chưa có bar sau touch";
      return false;
   }
   if(barsAfter > InpMaxBarsWaitBreakout) {
      why = StringFormat("quá cửa sổ breakout (%d > %d)", barsAfter, InpMaxBarsWaitBreakout);
      return false;
   }

   const double cSig = iClose(_Symbol, _Period, signalShift);
   const double oSig = iOpen(_Symbol, _Period, signalShift);
   const double hTch = iHigh(_Symbol, _Period, touchShift);
   const double cTch = iClose(_Symbol, _Period, touchShift);

   if(InpRequireBreakoutCandleColor && cSig <= oSig + _Point) {
      why = StringFormat("bar+%d chưa bullish", barsAfter);
      return false;
   }

   if(InpBreakoutUseTouchHighLow) {
      if(cSig <= hTch + _Point) {
         why = StringFormat("bar+%d chưa phá High touch %.*f (close=%.*f)",
                            barsAfter, _Digits, hTch, _Digits, cSig);
         return false;
      }
      why = StringFormat("breakout BUY bar+%d close>%.*f (High touch)", barsAfter, _Digits, hTch);
      return true;
   }

   if(cSig <= cTch + _Point) {
      why = StringFormat("bar+%d close <= close touch", barsAfter);
      return false;
   }
   why = StringFormat("breakout BUY bar+%d close>close touch", barsAfter);
   return true;
}

bool BreakoutSignalSell(const int signalShift, const int touchShift, string &why) {
   why = "";
   if(touchShift < 1) {
      why = "không có touch bar";
      return false;
   }
   if(signalShift >= touchShift) {
      why = "chờ bar sau touch";
      return false;
   }

   const int barsAfter = BarsAfterTouch(touchShift, signalShift);
   if(barsAfter < 1) {
      why = "chưa có bar sau touch";
      return false;
   }
   if(barsAfter > InpMaxBarsWaitBreakout) {
      why = StringFormat("quá cửa sổ breakout (%d > %d)", barsAfter, InpMaxBarsWaitBreakout);
      return false;
   }

   const double cSig = iClose(_Symbol, _Period, signalShift);
   const double oSig = iOpen(_Symbol, _Period, signalShift);
   const double lTch = iLow(_Symbol, _Period, touchShift);
   const double cTch = iClose(_Symbol, _Period, touchShift);

   if(InpRequireBreakoutCandleColor && cSig >= oSig - _Point) {
      why = StringFormat("bar+%d chưa bearish", barsAfter);
      return false;
   }

   if(InpBreakoutUseTouchHighLow) {
      if(cSig >= lTch - _Point) {
         why = StringFormat("bar+%d chưa phá Low touch %.*f (close=%.*f)",
                            barsAfter, _Digits, lTch, _Digits, cSig);
         return false;
      }
      why = StringFormat("breakout SELL bar+%d close<%.*f (Low touch)", barsAfter, _Digits, lTch);
      return true;
   }

   if(cSig >= cTch - _Point) {
      why = StringFormat("bar+%d close >= close touch", barsAfter);
      return false;
   }
   why = StringFormat("breakout SELL bar+%d close<close touch", barsAfter);
   return true;
}

bool HasOurPosition() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      return true;
   }
   return false;
}

double VolumeForRisk(const bool isBuy, const double entry, const double sl) {
   if(MathAbs(entry - sl) < _Point) return 0.0;
   const double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double profit = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, profit))
      return 0.0;
   const double lossPerLot = MathAbs(profit);
   if(lossPerLot < DBL_EPSILON) return 0.0;
   return riskMoney / lossPerLot;
}

// Phase 5: SL dưới min(low touch, low reject), TP = 1.5R
bool CalcSlTpFromSetup(const bool isBuy,
                       const int touchShift,
                       const int rejectShift,
                       const double entry,
                       const double atr,
                       double &sl,
                       double &tp,
                       string &err) {
   err = "";
   if(atr <= 0.0) {
      err = "ATR=0";
      return false;
   }

   const double buffer = InpSlBufferAtr * atr;
   const double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(isBuy) {
      const double slBase = MathMin(iLow(_Symbol, _Period, touchShift),
                                  iLow(_Symbol, _Period, rejectShift));
      sl = NormalizePrice(slBase - buffer);
      tp = NormalizePrice(entry + InpTpRR * (entry - sl));
      if(entry - sl < MathMax(_Point, minStop)) {
         err = "SL quá gần entry (buy)";
         return false;
      }
   } else {
      const double slBase = MathMax(iHigh(_Symbol, _Period, touchShift),
                                  iHigh(_Symbol, _Period, rejectShift));
      sl = NormalizePrice(slBase + buffer);
      tp = NormalizePrice(entry - InpTpRR * (sl - entry));
      if(sl - entry < MathMax(_Point, minStop)) {
         err = "SL quá gần entry (sell)";
         return false;
      }
   }
   return true;
}

bool OpenMarketFromReject(const bool isBuy,
                          const int touchShift,
                          const int rejectShift,
                          const double atr) {
   const double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = 0.0, tp = 0.0;
   string err = "";
   if(!CalcSlTpFromSetup(isBuy, touchShift, rejectShift, entry, atr, sl, tp, err)) {
      Print("[EPB] Entry skip — ", err);
      return false;
   }

   const double lot = NormalizeLots(VolumeForRisk(isBuy, entry, sl));
   if(lot <= 0.0) {
      Print("[EPB] Entry skip — lot=0");
      return false;
   }

   const double riskDist = MathAbs(entry - sl);
   const double rr = (riskDist > 0.0) ? MathAbs(tp - entry) / riskDist : 0.0;

   const string cmt = StringFormat("EPB %s R%.1f%% RR1:%.1f",
                                   isBuy ? "Buy" : "Sell",
                                   InpRiskPercent,
                                   InpTpRR);

   const bool ok = isBuy
                   ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt)
                   : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt);

   if(!ok) {
      PrintFormat("[EPB] Order fail retcode=%d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("[EPB] %s | entry=%.*f SL=%.*f TP=%.*f lot=%.2f risk=%.1f%% R:R=1:%.2f",
               isBuy ? "BUY" : "SELL",
               _Digits, entry,
               _Digits, sl,
               _Digits, tp,
               lot,
               InpRiskPercent,
               rr);

   const datetime t = iTime(_Symbol, _Period, rejectShift);
   const double px = isBuy ? iHigh(_Symbol, _Period, rejectShift) : iLow(_Symbol, _Period, rejectShift);
   DrawSetupMarker("SIG", t, px, isBuy ? clrLime : clrOrangeRed, isBuy ? "Entry Buy" : "Entry Sell");
   return true;
}

void ManageOpenPosition() {
   if(InpMaxBarsInTrade <= 0 || !HasOurPosition())
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
      const int barsIn = iBarShift(_Symbol, _Period, openT, false);
      if(barsIn >= 0 && barsIn >= InpMaxBarsInTrade) {
         g_trade.PositionClose(t);
         Print("[EPB] Đóng lệnh — quá ", InpMaxBarsInTrade, " bar");
      }
      break;
   }
}

void ResetSetupState(const string reason) {
   if(g_setupState != SETUP_IDLE && InpLogStateChange)
      Print("[EPB] Setup → IDLE | ", reason);

   g_setupState = SETUP_IDLE;
   g_setupDir = 0;
   g_barsInSetupState = 0;
   g_touchBarTime = 0;
   g_setupDetail = reason;
}

void DrawSetupMarker(const string tag,
                     const datetime t,
                     const double price,
                     const color clr,
                     const string tip) {
   if(!InpDrawSetupMarkers)
      return;

   const string name = OBJ_PREFIX + tag + "_" + IntegerToString((long)t);
   if(ObjectFind(0, name) >= 0)
      return;

   int arrowCode = 159;
   if(tag == "TCH") arrowCode = 241;
   else if(tag == "SIG") arrowCode = (StringFind(tip, "Buy") >= 0) ? 233 : 234;

   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DeleteSetupMarkers() {
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--) {
      const string n = ObjectName(0, i, 0, -1);
      if(StringFind(n, OBJ_PREFIX) == 0)
         ObjectDelete(0, n);
   }
}

void TransitionSetupState(const ENUM_SETUP_STATE newState,
                          const int dir,
                          const string detail,
                          const int shift) {
   const ENUM_SETUP_STATE prev = g_setupState;
   g_setupState = newState;
   g_setupDir = dir;
   g_barsInSetupState = 0;
   g_setupDetail = detail;

   const string logLine = StringFormat("Setup %s → %s | dir=%d | %s",
                                       SetupStateToString(prev),
                                       SetupStateToString(newState),
                                       dir,
                                       detail);
   g_lastStateLog = logLine;
   if(InpLogStateChange)
      Print("[EPB] ", logLine);

   if(!InpDrawSetupMarkers || shift < 1)
      return;

   const datetime t = iTime(_Symbol, _Period, shift);
   const double px = (dir > 0) ? iLow(_Symbol, _Period, shift) : iHigh(_Symbol, _Period, shift);

   if(newState == SETUP_PULLBACK_ACTIVE)
      DrawSetupMarker("PB", t, px, clrDodgerBlue, "Pullback active");
   else if(newState == SETUP_TOUCHED)
      DrawSetupMarker("TCH", t, px, clrGold, "Touch EMA");
}

bool TryEntryOnBreakout(const int signalShift, const double atr) {
   if(!InpTradeEnabled) {
      g_setupDetail = "breakout OK — InpTradeEnabled=false";
      return false;
   }
   if(HasOurPosition()) {
      g_setupDetail = "đã có position";
      return false;
   }

   const int touchShift = FindTouchBarShift();
   string why = "";
   const bool isBuy = (g_setupDir > 0);
   const bool signal = isBuy
                       ? BreakoutSignalBuy(signalShift, touchShift, why)
                       : BreakoutSignalSell(signalShift, touchShift, why);

   if(!signal) {
      g_setupDetail = why;
      return false;
   }

   if(InpLogStateChange)
      Print("[EPB] ", why);

   if(OpenMarketFromReject(isBuy, touchShift, signalShift, atr)) {
      ResetSetupState("entry opened");
      return true;
   }
   return false;
}

void UpdateSetupStateMachine(const int shift,
                             const ENUM_MARKET_STATE market,
                             const double ema,
                             const double atr) {
   const int trendDir = TradeDirection(market);

   if(!CanTradeRegime(market)) {
      if(g_setupState != SETUP_IDLE)
         ResetSetupState("regime: " + MarketStateToString(market));
      return;
   }

   if(g_setupState != SETUP_IDLE && g_setupDir != 0 && trendDir != g_setupDir) {
      ResetSetupState("đổi hướng trend");
      return;
   }

   const bool isBuy = (trendDir > 0);
   const bool broken = isBuy ? TrendStructureBrokenBuy(shift, ema)
                             : TrendStructureBrokenSell(shift, ema);
   if(broken) {
      if(g_setupState != SETUP_IDLE)
         ResetSetupState(isBuy ? "Close phá dưới EMA" : "Close phá trên EMA");
      return;
   }

   switch(g_setupState) {
      case SETUP_IDLE: {
         string why = "";
         const bool start = isBuy
                            ? PullbackStartBuy(shift, ema, atr, why)
                            : PullbackStartSell(shift, ema, atr, why);
         if(start)
            TransitionSetupState(SETUP_PULLBACK_ACTIVE, trendDir, why, shift);
         else
            g_setupDetail = why;
         return;
      }

      case SETUP_PULLBACK_ACTIVE: {
         g_barsInSetupState++;

         const bool touched = isBuy
                              ? PriceTouchedEmaBuy(shift, ema, atr)
                              : PriceTouchedEmaSell(shift, ema, atr);
         if(touched) {
            g_touchBarTime = iTime(_Symbol, _Period, shift);
            TransitionSetupState(SETUP_TOUCHED, g_setupDir,
                                 StringFormat("touch EMA @ %s", TimeToString(g_touchBarTime)),
                                 shift);
            return;
         }

         if(g_barsInSetupState >= InpMaxBarsPullback) {
            ResetSetupState(StringFormat("timeout pullback (%d bar)", InpMaxBarsPullback));
            return;
         }

         g_setupDetail = StringFormat("chờ touch (%d/%d)", g_barsInSetupState, InpMaxBarsPullback);
         return;
      }

      case SETUP_TOUCHED: {
         g_barsInSetupState++;

         // Phase 4+5: chờ breakout khỏi nến touch (tối đa InpMaxBarsWaitBreakout nến)
         if(TryEntryOnBreakout(shift, atr))
            return;

         if(g_barsInSetupState > InpMaxBarsWaitBreakout) {
            ResetSetupState(StringFormat("timeout chờ breakout (%d nến)", InpMaxBarsWaitBreakout));
            return;
         }

         const int touchShift = FindTouchBarShift();
         const int barsAfter = (touchShift > 0) ? BarsAfterTouch(touchShift, shift) : -1;
         g_setupDetail = StringFormat("touch@%s — chờ breakout bar+%d (%d/%d) | %s",
                                      TimeToString(g_touchBarTime),
                                      barsAfter,
                                      g_barsInSetupState,
                                      InpMaxBarsWaitBreakout,
                                      g_setupDetail);
         return;
      }
   }
}

//--- Thống kê lệnh (góc dưới trái chart)
void CreateStatsPanel() {
   if(!InpShowStatsPanel)
      return;

   const string bg = StatPfx() + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 8);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 420);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 52);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_COLOR, C'80,80,120');
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   const string labels[] = {"TITLE", "MAIN"};
   const string texts[] = {
      "▶ EmaPullbackBasic",
      "Tổng số lệnh: 0 | SL: 0 | TP: 0 | Winrate: —"
   };
   const int yMain = 14;
   const int yTitle = 34;

   for(int i = 0; i < 2; i++) {
      const string n = StatPfx() + labels[i];
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 14);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, i == 0 ? yMain : yTitle);
      ObjectSetString(0, n, OBJPROP_TEXT, texts[i]);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, i == 0 ? 9 : 8);
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_COLOR, i == 0 ? clrWhite : clrSilver);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   }
}

void UpdateStatsPanel() {
   if(!InpShowStatsPanel)
      return;

   const double winrate = (g_statTotal > 0) ? (100.0 * g_statTP / g_statTotal) : 0.0;
   const string mainText = (g_statTotal > 0)
      ? StringFormat("Tổng số lệnh: %d | SL: %d | TP: %d | Winrate: %.1f%%",
                     g_statTotal, g_statSL, g_statTP, winrate)
      : "Tổng số lệnh: 0 | SL: 0 | TP: 0 | Winrate: —";

   ObjectSetString(0, StatPfx() + "MAIN", OBJPROP_TEXT, mainText);
   ChartRedraw(0);
}

void DeleteStatsPanel() {
   const string p = StatPfx();
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--) {
      if(StringFind(ObjectName(0, i, 0, -1), p) == 0)
         ObjectDelete(0, ObjectName(0, i, 0, -1));
   }
}

void RecordClosedDeal(const ulong dealTicket) {
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   g_statTotal++;
   const long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   if(reason == DEAL_REASON_SL)
      g_statSL++;
   else if(reason == DEAL_REASON_TP)
      g_statTP++;
   else if(HistoryDealGetDouble(dealTicket, DEAL_PROFIT) >= 0.0)
      g_statTP++;
   else
      g_statSL++;

   UpdateStatsPanel();
}

void UpdateChartComment(const int shift,
                        const double ema,
                        const double adx,
                        const double atr,
                        const ENUM_MARKET_STATE state,
                        const string &regimeDetail) {
   if(!InpShowComment)
      return;

   const datetime barTime = iTime(_Symbol, _Period, shift);
   const int touchShift = FindTouchBarShift();

   Comment(
      "EmaPullbackBasic — Phase 4/5\n",
      "Bar: ", TimeToString(barTime), "\n",
      "Regime: ", MarketStateToString(state),
      "  |  Setup: ", SetupStateToString(g_setupState), "\n",
      "Regime: ", regimeDetail, "\n",
      "Setup: ", g_setupDetail, "\n",
      "Touch: ", (g_touchBarTime > 0 ? TimeToString(g_touchBarTime) : "—"),
      "  shift=", touchShift, "\n",
      "Trade: ", (InpTradeEnabled ? "ON" : "OFF"),
      "  Pos: ", (HasOurPosition() ? "YES" : "NO"),
      "  Risk: ", DoubleToString(InpRiskPercent, 1), "%  TP=", DoubleToString(InpTpRR, 1), "R\n",
      "Close/EMA/ADX: ", DoubleToString(iClose(_Symbol, _Period, shift), _Digits),
      " / ", DoubleToString(ema, _Digits),
      " / ", DoubleToString(adx, 1)
   );
}

void OnNewClosedBar() {
   ManageOpenPosition();

   const int shift = 1;

   double ema = 0.0, adx = 0.0, atr = 0.0;
   string err = "";
   if(!ReadIndicatorsAtShift(shift, ema, adx, atr, err)) {
      Print("[EPB] ", TimeToString(iTime(_Symbol, _Period, 0)), " — ", err);
      return;
   }

   string regimeDetail = "";
   g_marketState = ClassifyMarketState(shift, regimeDetail);
   g_regimeDetail = regimeDetail;

   if(!HasOurPosition())
      UpdateSetupStateMachine(shift, g_marketState, ema, atr);

   if(InpLogEachBar) {
      PrintFormat(
         "[EPB] %s | %s | %s | %s | pos=%s",
         TimeToString(iTime(_Symbol, _Period, shift)),
         MarketStateToString(g_marketState),
         SetupStateToString(g_setupState),
         g_setupDetail,
         HasOurPosition() ? "Y" : "N"
      );
   }

   UpdateChartComment(shift, ema, adx, atr, g_marketState, regimeDetail);
   UpdateStatsPanel();
}

//+------------------------------------------------------------------+
int OnInit() {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(InpTpRR <= 0.0) {
      Print("[EPB] Init failed — InpTpRR phải > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_hEma = iMA(_Symbol, _Period, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdx = iADX(_Symbol, _Period, InpAdxPeriod);
   g_hAtr = iATR(_Symbol, _Period, InpAtrPeriod);

   if(g_hEma == INVALID_HANDLE || g_hAdx == INVALID_HANDLE || g_hAtr == INVALID_HANDLE) {
      Print("[EPB] Init failed — invalid indicator handle");
      return INIT_FAILED;
   }

   ResetSetupState("init");

   double probe = 0.0;
   string err = "";
   if(!ReadIndicatorsAtShift(1, probe, probe, probe, err))
      Print("[EPB] Init warning — ", err);

   g_lastBarTime = iTime(_Symbol, _Period, 0);
   CreateStatsPanel();
   UpdateStatsPanel();
   OnNewClosedBar();

   if(InpMaxBarsWaitBreakout < 1) {
      Print("[EPB] Init failed — InpMaxBarsWaitBreakout phải >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   PrintFormat(
      "[EPB] Init — trade=%s risk=%.1f%% TP=%.1fR | breakout %d bar, %s High/Low touch",
      InpTradeEnabled ? "ON" : "OFF",
      InpRiskPercent,
      InpTpRR,
      InpMaxBarsWaitBreakout,
      InpBreakoutUseTouchHighLow ? "Close>" : "Close>Close"
   );
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(g_hEma != INVALID_HANDLE) IndicatorRelease(g_hEma);
   if(g_hAdx != INVALID_HANDLE) IndicatorRelease(g_hAdx);
   if(g_hAtr != INVALID_HANDLE) IndicatorRelease(g_hAtr);
   g_hEma = g_hAdx = g_hAtr = INVALID_HANDLE;

   DeleteSetupMarkers();
   DeleteStatsPanel();
   Comment("");
   Print("[EPB] Deinit — reason=", reason);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   RecordClosedDeal(trans.deal);
}

void OnTick() {
   const datetime barOpen = iTime(_Symbol, _Period, 0);
   if(barOpen == g_lastBarTime)
      return;

   g_lastBarTime = barOpen;
   OnNewClosedBar();
}
//+------------------------------------------------------------------+
