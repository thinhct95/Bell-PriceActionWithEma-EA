//+------------------------------------------------------------------+
//| SignalDebug.mqh — đánh dấu cross RSI×WMA45: OK / SKIP + tooltip    |
//+------------------------------------------------------------------+
#ifndef RSI_MOM_SIGNAL_DEBUG_MQH
#define RSI_MOM_SIGNAL_DEBUG_MQH

#include <RsiMom/PhaseEntry.mqh>

struct SignalEvalResult
{
   bool   signalOk;
   bool   tradeOk;
   string summary;
   string detail;
   string failTag;     // lý do chính: P1-mở rộng, P2-cuộn, EMA200, ATR, …
};

void SignalEval_Append(string &detail, const string part)
{
   if(StringLen(detail) > 0)
      detail += " | ";
   detail += part;
}

void SignalEval_SetFail(string &failTag, const string tag)
{
   if(StringLen(failTag) == 0 && StringLen(tag) > 0)
      failTag = tag;
}

string SignalEval_FormatTooltip(const bool isBuy, const SignalEvalResult &ev)
{
   const string side = isBuy ? "BUY" : "SELL";
   string tip = side + " @ " + ev.summary;
   if(StringLen(ev.failTag) > 0 && !ev.signalOk)
      tip += "\nFail: " + ev.failTag;
   tip += "\n---\n" + ev.detail;
   return tip;
}

string SignalEval_ChartLabel(const SignalEvalResult &ev)
{
   if(ev.tradeOk)
      return "OK";
   if(ev.signalOk)
      return "SIG";
   if(StringLen(ev.failTag) > 0)
   {
      string tag = ev.failTag;
      StringTrimRight(tag);
      StringTrimLeft(tag);
      return "SKIP " + tag;
   }
   return "SKIP";
}

SignalEvalResult Signal_EvaluateBuyAt(const int shift, const int rates_total, const int trendN,
                                      const double &rsi[], const double &ema9[], const double &wma[],
                                      const double &closeArr[], const double &ema200Arr[],
                                      const PhaseEntryConfig &phaseCfg,
                                      const bool phaseFilterEnabled,
                                      const bool trendFilterEnabled,
                                      const bool atrFilterEnabled,
                                      const bool adxFilterEnabled,
                                      const bool adxOkAtBar,
                                      const double adxVal,
                                      const double plusDi,
                                      const double minusDi,
                                      const string adxFailWhy,
                                      const bool swingFilterEnabled,
                                      const bool swingOkAtBar,
                                      const double swingBodyOld,
                                      const double swingBodyNew,
                                      const string swingFailWhy,
                                      const bool rsiObOsFilterEnabled,
                                      const double rsiOverbought,
                                      const double rsiOversold,
                                      const bool sessionFilterEnabled,
                                      const bool atrExpAtBar,
                                      const bool sessionAtBar,
                                      const string sessionFailWhy = "")
{
   SignalEvalResult r;
   r.signalOk = false;
   r.tradeOk  = false;
   r.summary  = "";
   r.detail   = "";
   r.failTag  = "";

   const bool cross = (shift + 1 < rates_total) &&
                    (rsi[shift + 1] <= wma[shift + 1]) && (rsi[shift] > wma[shift + 1]);
   if(!cross)
   {
      r.summary = "no cross";
      SignalEval_Append(r.detail, "RSI chưa cắt lên WMA45");
      return r;
   }

   SignalEval_Append(r.detail, "RSI↑WMA45");

   bool coreOk = true;
   string phaseFail = "";
   if(phaseFilterEnabled)
   {
      coreOk = Phase_BuyPasses(shift, rates_total, rsi, ema9, wma, phaseCfg, phaseFail);
      double maxSp = 0.0;
      const bool p1 = Phase_FindMaxSpreadDown(shift, phaseCfg.expandLookback, rates_total,
                                              rsi, ema9, wma, phaseCfg.minExpandSpread, maxSp);
      const int xc = Phase_CountRsiEma9Crosses(shift, phaseCfg.coilLookback, rates_total, rsi, ema9);
      const bool p3 = Phase_Ema9TurningBuy(shift, phaseCfg, ema9);
      const bool p4 = Phase_Wma45FlatteningBuyCfg(shift, phaseCfg, wma);
      const double gap = wma[shift] - ema9[shift];
      const bool p5 = Phase_Ema9NearWmaBuy(shift, phaseCfg.maxEma9WmaGap, ema9, wma);

      SignalEval_Append(r.detail, p1
                        ? StringFormat("P1:OK(sp=%.1f>=%.1f)", maxSp, phaseCfg.minExpandSpread)
                        : StringFormat("P1:FAIL(sp=%.1f<%.1f)", maxSp, phaseCfg.minExpandSpread));
      SignalEval_Append(r.detail, StringFormat("P2:%s(x=%d)", xc >= phaseCfg.minRsiEma9Crosses ? "OK" : "FAIL", xc));
      SignalEval_Append(r.detail, p3 ? "P3:OK" : "P3:FAIL");
      SignalEval_Append(r.detail, p4 ? "P4:OK" : "P4:FAIL");
      SignalEval_Append(r.detail, p5 ? StringFormat("P5:OK(gap=%.1f)", gap) : StringFormat("P5:FAIL(gap=%.1f)", gap));

      if(!p1)           SignalEval_SetFail(r.failTag, "P1-mở rộng");
      else if(xc < phaseCfg.minRsiEma9Crosses)
         SignalEval_SetFail(r.failTag, "P2-cuộn");
      else if(!p3)      SignalEval_SetFail(r.failTag, "P3-EMA9↑");
      else if(!p4)      SignalEval_SetFail(r.failTag, "P4-WMA45 phẳng");
      else if(!p5)      SignalEval_SetFail(r.failTag, "P5-EMA9 xa WMA45");
      else if(!coreOk && StringLen(phaseFail) > 0)
         SignalEval_SetFail(r.failTag, phaseFail);
   }
   else
   {
      coreOk = (ema9[shift] < wma[shift]);
      SignalEval_Append(r.detail, coreOk ? "EMA9<WMA45" : "EMA9>=WMA45 FAIL");
      if(!coreOk)
         SignalEval_SetFail(r.failTag, "EMA9>=WMA45");
   }

   bool trendUp = true;
   if(!trendFilterEnabled)
      SignalEval_Append(r.detail, "EMA200:OFF");
   else
   {
      for(int k = 0; k < trendN; k++)
      {
         const int idx = shift + k;
         if(closeArr[idx] <= ema200Arr[idx])
         {
            trendUp = false;
            break;
         }
      }
      SignalEval_Append(r.detail, trendUp ? "EMA200:OK" : "EMA200:FAIL");
      if(!trendUp)
         SignalEval_SetFail(r.failTag, "EMA200");
   }

   SignalEval_Append(r.detail, !atrFilterEnabled ? "ATR:OFF" : (atrExpAtBar ? "ATR:OK" : "ATR:FAIL"));
   if(atrFilterEnabled && !atrExpAtBar)
      SignalEval_SetFail(r.failTag, "ATR co");

   if(!adxFilterEnabled)
      SignalEval_Append(r.detail, "ADX:OFF");
   else if(adxOkAtBar)
      SignalEval_Append(r.detail, StringFormat("ADX:OK(%.1f +DI=%.1f -DI=%.1f)", adxVal, plusDi, minusDi));
   else
   {
      SignalEval_Append(r.detail, StringLen(adxFailWhy) > 0
                        ? StringFormat("ADX:FAIL(%.1f %s)", adxVal, adxFailWhy)
                        : StringFormat("ADX:FAIL(%.1f)", adxVal));
      SignalEval_SetFail(r.failTag, "ADX yếu");
   }

   if(!swingFilterEnabled)
      SignalEval_Append(r.detail, "Swing2:OFF");
   else if(swingOkAtBar)
      SignalEval_Append(r.detail, StringFormat("Swing2:OK(đáy %.5f→%.5f)", swingBodyOld, swingBodyNew));
   else
   {
      SignalEval_Append(r.detail, StringLen(swingFailWhy) > 0
                        ? "Swing2:FAIL " + swingFailWhy
                        : "Swing2:FAIL");
      SignalEval_SetFail(r.failTag, "2 đáy");
   }

   bool rsiOk = true;
   if(!rsiObOsFilterEnabled)
      SignalEval_Append(r.detail, "RSI OB/OS:OFF");
   else
   {
      rsiOk = (rsi[shift] < rsiOverbought);
      if(rsiOk)
         SignalEval_Append(r.detail, StringFormat("RSI:OK(%.1f<%g)", rsi[shift], rsiOverbought));
      else
      {
         SignalEval_Append(r.detail, StringFormat("RSI:OB %.1f>=%g", rsi[shift], rsiOverbought));
         SignalEval_SetFail(r.failTag, "RSI quá mua");
      }
   }

   const bool envBar = (!sessionFilterEnabled) || sessionAtBar;
   if(!sessionFilterEnabled)
      SignalEval_Append(r.detail, "Phiên:OFF");
   else if(envBar)
      SignalEval_Append(r.detail, "Phiên(bar):OK");
   else
   {
      SignalEval_Append(r.detail, StringLen(sessionFailWhy) > 0
                        ? "Phiên(bar):FAIL " + sessionFailWhy
                        : "Phiên(bar):FAIL");
      SignalEval_SetFail(r.failTag, "Phiên");
   }

   r.signalOk = cross && coreOk && trendUp
                && (!atrFilterEnabled || atrExpAtBar)
                && (!adxFilterEnabled || adxOkAtBar)
                && (!swingFilterEnabled || swingOkAtBar)
                && rsiOk && envBar;
   r.tradeOk  = r.signalOk;

   if(r.signalOk && r.tradeOk)
      r.summary = "HỢP LỆ → vào lệnh";
   else if(r.signalOk)
      r.summary = "Tín hiệu OK | chờ đặt lệnh";
   else
      r.summary = StringLen(r.failTag) > 0
                  ? "SKIP → " + r.failTag
                  : "SKIP";

   return r;
}

SignalEvalResult Signal_EvaluateSellAt(const int shift, const int rates_total, const int trendN,
                                       const double &rsi[], const double &ema9[], const double &wma[],
                                       const double &closeArr[], const double &ema200Arr[],
                                       const PhaseEntryConfig &phaseCfg,
                                       const bool phaseFilterEnabled,
                                       const bool trendFilterEnabled,
                                       const bool atrFilterEnabled,
                                       const bool adxFilterEnabled,
                                       const bool adxOkAtBar,
                                       const double adxVal,
                                       const double plusDi,
                                       const double minusDi,
                                       const string adxFailWhy,
                                       const bool swingFilterEnabled,
                                       const bool swingOkAtBar,
                                       const double swingBodyOld,
                                       const double swingBodyNew,
                                       const string swingFailWhy,
                                       const bool rsiObOsFilterEnabled,
                                       const double rsiOverbought,
                                       const double rsiOversold,
                                       const bool sessionFilterEnabled,
                                       const bool atrExpAtBar,
                                       const bool sessionAtBar,
                                       const string sessionFailWhy = "")
{
   SignalEvalResult r;
   r.signalOk = false;
   r.tradeOk  = false;
   r.summary  = "";
   r.detail   = "";
   r.failTag  = "";

   const bool cross = (shift + 1 < rates_total) &&
                    (rsi[shift + 1] >= wma[shift + 1]) && (rsi[shift] < wma[shift + 1]);
   if(!cross)
   {
      r.summary = "no cross";
      SignalEval_Append(r.detail, "RSI chưa cắt xuống WMA45");
      return r;
   }

   SignalEval_Append(r.detail, "RSI↓WMA45");

   bool coreOk = true;
   string phaseFail = "";
   if(phaseFilterEnabled)
   {
      coreOk = Phase_SellPasses(shift, rates_total, rsi, ema9, wma, phaseCfg, phaseFail);
      double maxSp = 0.0;
      const bool p1 = Phase_FindMaxSpreadUp(shift, phaseCfg.expandLookback, rates_total,
                                           rsi, ema9, wma, phaseCfg.minExpandSpread, maxSp);
      const int xc = Phase_CountRsiEma9Crosses(shift, phaseCfg.coilLookback, rates_total, rsi, ema9);
      const bool p3 = Phase_Ema9TurningSell(shift, phaseCfg, ema9);
      const bool p4 = Phase_Wma45FlatteningSellCfg(shift, phaseCfg, wma);
      const double gap = ema9[shift] - wma[shift];
      const bool p5 = Phase_Ema9NearWmaSell(shift, phaseCfg.maxEma9WmaGap, ema9, wma);

      SignalEval_Append(r.detail, p1
                        ? StringFormat("P1:OK(sp=%.1f>=%.1f)", maxSp, phaseCfg.minExpandSpread)
                        : StringFormat("P1:FAIL(sp=%.1f<%.1f)", maxSp, phaseCfg.minExpandSpread));
      SignalEval_Append(r.detail, StringFormat("P2:%s(x=%d)", xc >= phaseCfg.minRsiEma9Crosses ? "OK" : "FAIL", xc));
      SignalEval_Append(r.detail, p3 ? "P3:OK" : "P3:FAIL");
      SignalEval_Append(r.detail, p4 ? "P4:OK" : "P4:FAIL");
      SignalEval_Append(r.detail, p5 ? StringFormat("P5:OK(gap=%.1f)", gap) : StringFormat("P5:FAIL(gap=%.1f)", gap));

      if(!p1)           SignalEval_SetFail(r.failTag, "P1-mở rộng");
      else if(xc < phaseCfg.minRsiEma9Crosses) SignalEval_SetFail(r.failTag, "P2-cuộn");
      else if(!p3)      SignalEval_SetFail(r.failTag, "P3-EMA9↓");
      else if(!p4)      SignalEval_SetFail(r.failTag, "P4-WMA45 phẳng");
      else if(!p5)      SignalEval_SetFail(r.failTag, "P5-EMA9 xa WMA45");
      else if(!coreOk && StringLen(phaseFail) > 0)
         SignalEval_SetFail(r.failTag, phaseFail);
   }
   else
   {
      coreOk = (ema9[shift] > wma[shift]);
      SignalEval_Append(r.detail, coreOk ? "EMA9>WMA45" : "EMA9<=WMA45 FAIL");
      if(!coreOk)
         SignalEval_SetFail(r.failTag, "EMA9<=WMA45");
   }

   bool trendDown = true;
   if(!trendFilterEnabled)
      SignalEval_Append(r.detail, "EMA200:OFF");
   else
   {
      for(int k = 0; k < trendN; k++)
      {
         const int idx = shift + k;
         if(closeArr[idx] >= ema200Arr[idx])
         {
            trendDown = false;
            break;
         }
      }
      SignalEval_Append(r.detail, trendDown ? "EMA200:OK" : "EMA200:FAIL");
      if(!trendDown)
         SignalEval_SetFail(r.failTag, "EMA200");
   }

   SignalEval_Append(r.detail, !atrFilterEnabled ? "ATR:OFF" : (atrExpAtBar ? "ATR:OK" : "ATR:FAIL"));
   if(atrFilterEnabled && !atrExpAtBar)
      SignalEval_SetFail(r.failTag, "ATR co");

   if(!adxFilterEnabled)
      SignalEval_Append(r.detail, "ADX:OFF");
   else if(adxOkAtBar)
      SignalEval_Append(r.detail, StringFormat("ADX:OK(%.1f +DI=%.1f -DI=%.1f)", adxVal, plusDi, minusDi));
   else
   {
      SignalEval_Append(r.detail, StringLen(adxFailWhy) > 0
                        ? StringFormat("ADX:FAIL(%.1f %s)", adxVal, adxFailWhy)
                        : StringFormat("ADX:FAIL(%.1f)", adxVal));
      SignalEval_SetFail(r.failTag, "ADX yếu");
   }

   if(!swingFilterEnabled)
      SignalEval_Append(r.detail, "Swing2:OFF");
   else if(swingOkAtBar)
      SignalEval_Append(r.detail, StringFormat("Swing2:OK(đỉnh %.5f→%.5f)", swingBodyOld, swingBodyNew));
   else
   {
      SignalEval_Append(r.detail, StringLen(swingFailWhy) > 0
                        ? "Swing2:FAIL " + swingFailWhy
                        : "Swing2:FAIL");
      SignalEval_SetFail(r.failTag, "2 đỉnh");
   }

   bool rsiOk = true;
   if(!rsiObOsFilterEnabled)
      SignalEval_Append(r.detail, "RSI OB/OS:OFF");
   else
   {
      rsiOk = (rsi[shift] > rsiOversold);
      if(rsiOk)
         SignalEval_Append(r.detail, StringFormat("RSI:OK(%.1f>%g)", rsi[shift], rsiOversold));
      else
      {
         SignalEval_Append(r.detail, StringFormat("RSI:OS %.1f<=%g", rsi[shift], rsiOversold));
         SignalEval_SetFail(r.failTag, "RSI quá bán");
      }
   }

   const bool envBar = (!sessionFilterEnabled) || sessionAtBar;
   if(!sessionFilterEnabled)
      SignalEval_Append(r.detail, "Phiên:OFF");
   else if(envBar)
      SignalEval_Append(r.detail, "Phiên(bar):OK");
   else
   {
      SignalEval_Append(r.detail, StringLen(sessionFailWhy) > 0
                        ? "Phiên(bar):FAIL " + sessionFailWhy
                        : "Phiên(bar):FAIL");
      SignalEval_SetFail(r.failTag, "Phiên");
   }

   r.signalOk = cross && coreOk && trendDown
                && (!atrFilterEnabled || atrExpAtBar)
                && (!adxFilterEnabled || adxOkAtBar)
                && (!swingFilterEnabled || swingOkAtBar)
                && rsiOk && envBar;
   r.tradeOk  = r.signalOk;

   if(r.signalOk && r.tradeOk)
      r.summary = "HỢP LỆ → vào lệnh";
   else if(r.signalOk)
      r.summary = "Tín hiệu OK | chờ đặt lệnh";
   else
      r.summary = StringLen(r.failTag) > 0
                  ? "SKIP → " + r.failTag
                  : "SKIP";

   return r;
}

const string DBG_HOVER_LABEL = "RsiMomEA_dbg_hover";

void Signal_DebugSetTooltip(const long chartId, const string name, const string tip)
{
   ObjectSetString(chartId, name, OBJPROP_TOOLTIP, tip);
}

void Signal_DebugEnsureHoverLabel(const long chartId)
{
   if(ObjectFind(chartId, DBG_HOVER_LABEL) >= 0)
      return;

   ObjectCreate(chartId, DBG_HOVER_LABEL, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_CORNER,     CORNER_LEFT_LOWER);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_XDISTANCE,  8);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_YDISTANCE,  72);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_FONTSIZE,   8);
   ObjectSetString (chartId, DBG_HOVER_LABEL, OBJPROP_FONT,       "Consolas");
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_COLOR,      clrWhite);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_BACK,       true);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_BGCOLOR,    clrBlack);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chartId, DBG_HOVER_LABEL, OBJPROP_HIDDEN,     true);
   ObjectSetString (chartId, DBG_HOVER_LABEL, OBJPROP_TEXT,       "");
}

void Signal_DebugShowHoverHint(const long chartId, const string tip)
{
   if(StringLen(tip) == 0)
      return;
   Signal_DebugEnsureHoverLabel(chartId);
   ObjectSetString(chartId, DBG_HOVER_LABEL, OBJPROP_TEXT, tip);
   ChartRedraw(chartId);
}

void Signal_DebugHideHoverHint(const long chartId)
{
   if(ObjectFind(chartId, DBG_HOVER_LABEL) < 0)
      return;
   const string cur = ObjectGetString(chartId, DBG_HOVER_LABEL, OBJPROP_TEXT);
   if(StringLen(cur) == 0)
      return;
   ObjectSetString(chartId, DBG_HOVER_LABEL, OBJPROP_TEXT, "");
   ChartRedraw(chartId);
}

bool Signal_DebugObjectHasPrefix(const string name, const string prefix)
{
   return (StringLen(name) >= StringLen(prefix) && StringSubstr(name, 0, StringLen(prefix)) == prefix);
}

bool Signal_DebugReadTipFromMark(const long chartId, const string objName, string &tip)
{
   tip = "";
   if(ObjectFind(chartId, objName) < 0)
      return false;
   tip = ObjectGetString(chartId, objName, OBJPROP_TOOLTIP);
   return (StringLen(tip) > 0);
}

bool Signal_DebugFindTipAtMouse(const long chartId, const string prefix,
                                const int mouseX, const int mouseY, string &tip)
{
   tip = "";
   datetime tMouse = 0;
   double   pMouse = 0.0;
   int      subwin   = 0;
   if(!ChartXYToTimePrice(chartId, mouseX, mouseY, subwin, tMouse, pMouse))
      return false;

   const int total = ObjectsTotal(chartId, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(chartId, i, 0, -1);
      if(!Signal_DebugObjectHasPrefix(name, prefix))
         continue;

      const bool isHit   = (StringFind(name, "_hit") >= 0);
      const bool isArrow = (StringFind(name, "_ar") >= 0);
      if(!isHit && !isArrow)
         continue;

      if(isHit)
      {
         const datetime t0 = (datetime)ObjectGetInteger(chartId, name, OBJPROP_TIME, 0);
         const datetime t1 = (datetime)ObjectGetInteger(chartId, name, OBJPROP_TIME, 1);
         const double   p0 = ObjectGetDouble(chartId, name, OBJPROP_PRICE, 0);
         const double   p1 = ObjectGetDouble(chartId, name, OBJPROP_PRICE, 1);
         if(tMouse < t0 || tMouse > t1)
            continue;
         if(pMouse < MathMin(p0, p1) || pMouse > MathMax(p0, p1))
            continue;
         return Signal_DebugReadTipFromMark(chartId, name, tip);
      }

      if(isArrow)
      {
         const datetime ta = (datetime)ObjectGetInteger(chartId, name, OBJPROP_TIME, 0);
         const int halfSec = MathMax(1, PeriodSeconds(_Period) / 2);
         if(MathAbs((int)(tMouse - ta)) > halfSec)
            continue;
         return Signal_DebugReadTipFromMark(chartId, name, tip);
      }
   }

   const int sh = iBarShift(_Symbol, _Period, tMouse, false);
   if(sh < 0)
      return false;

   for(int d = -1; d <= 1; d++)
   {
      const int s = sh + d;
      if(s < 0)
         continue;
      const datetime bt = iTime(_Symbol, _Period, s);
      const string btKey = prefix + IntegerToString((int)bt);
      if(Signal_DebugReadTipFromMark(chartId, btKey + "_B_hit", tip))
         return true;
      if(Signal_DebugReadTipFromMark(chartId, btKey + "_S_hit", tip))
         return true;
      if(Signal_DebugReadTipFromMark(chartId, btKey + "_B_ar", tip))
         return true;
      if(Signal_DebugReadTipFromMark(chartId, btKey + "_S_ar", tip))
         return true;
   }
   return false;
}

void Signal_DebugOnMouseMove(const long chartId, const string prefix, const int mouseX, const int mouseY)
{
   string tip = "";
   if(Signal_DebugFindTipAtMouse(chartId, prefix, mouseX, mouseY, tip))
      Signal_DebugShowHoverHint(chartId, tip);
   else
      Signal_DebugHideHoverHint(chartId);
}

bool Signal_DebugMarkExists(const long chartId, const string prefix,
                            const datetime barTime, const bool isBuy)
{
   const string arrowName = prefix + IntegerToString((int)barTime) + (isBuy ? "_B" : "_S") + "_ar";
   return (ObjectFind(chartId, arrowName) >= 0);
}

void Signal_DebugPruneOlderThan(const long chartId, const string prefix, const int keepBars)
{
   if(keepBars < 1)
      return;

   const datetime cutoff = iTime(_Symbol, _Period, keepBars);
   if(cutoff == 0)
      return;

   const int total = ObjectsTotal(chartId, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(chartId, i, 0, -1);
      if(!Signal_DebugObjectHasPrefix(name, prefix))
         continue;

      const int pfxLen = StringLen(prefix);
      const int und = StringFind(name, "_", pfxLen);
      if(und <= pfxLen)
         continue;

      const datetime bt = (datetime)StringToInteger(StringSubstr(name, pfxLen, und - pfxLen));
      if(bt > 0 && bt < cutoff)
         ObjectDelete(chartId, name);
   }
}

void Signal_DebugDrawMark(const long chartId, const string prefix,
                          const datetime barTime, const double barHigh, const double barLow,
                          const double markPrice, const bool isBuy, const SignalEvalResult &ev)
{
   const string base = prefix + IntegerToString((int)barTime) + (isBuy ? "_B" : "_S");
   const string arrowName = base + "_ar";
   const string hitName   = base + "_hit";

   // Giữ dấu cũ — không xóa/vẽ lại khi có nến mới (hover xem lý do skip sau)
   if(ObjectFind(chartId, arrowName) >= 0)
      return;

   const string tip = SignalEval_FormatTooltip(isBuy, ev);

   color clr = clrDimGray;
   int arrowCode = 251;
   int arrowW = 2;
   if(ev.signalOk && ev.tradeOk)
   {
      clr = clrLime;
      arrowCode = isBuy ? 233 : 234;
      arrowW = 1;
   }
   else if(ev.signalOk)
   {
      clr = clrGold;
      arrowCode = isBuy ? 233 : 234;
      arrowW = 1;
   }
   else
   {
      clr = clrOrangeRed;
      arrowCode = 251;
      arrowW = 3;
   }

   if(ObjectCreate(chartId, arrowName, OBJ_ARROW, 0, barTime, markPrice))
   {
      ObjectSetInteger(chartId, arrowName, OBJPROP_ARROWCODE,  arrowCode);
      ObjectSetInteger(chartId, arrowName, OBJPROP_COLOR,      clr);
      ObjectSetInteger(chartId, arrowName, OBJPROP_WIDTH,      arrowW);
      ObjectSetInteger(chartId, arrowName, OBJPROP_ANCHOR,     isBuy ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(chartId, arrowName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(chartId, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(chartId, arrowName, OBJPROP_BACK,       false);
      Signal_DebugSetTooltip(chartId, arrowName, tip);
   }

   const datetime tEnd = barTime + (datetime)PeriodSeconds(_Period);
   const double pad = MathMax(_Point * 8.0, (barHigh - barLow) * 0.08);
   const double rHi = barHigh + pad;
   const double rLo = barLow - pad;
   const color hitFill = (color)ColorToARGB(clr, (uchar)24);

   if(ObjectCreate(chartId, hitName, OBJ_RECTANGLE, 0, barTime, rHi, tEnd, rLo))
   {
      ObjectSetInteger(chartId, hitName, OBJPROP_COLOR, hitFill);
      ObjectSetInteger(chartId, hitName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(chartId, hitName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(chartId, hitName, OBJPROP_FILL, true);
      ObjectSetInteger(chartId, hitName, OBJPROP_BACK, true);
      ObjectSetInteger(chartId, hitName, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(chartId, hitName, OBJPROP_HIDDEN, true);
      Signal_DebugSetTooltip(chartId, hitName, tip);
   }
}

void Signal_DebugConfigureChart(const long chartId)
{
   ChartSetInteger(chartId, CHART_SHOW_OBJECT_DESCR, false);
   ChartSetInteger(chartId, CHART_EVENT_MOUSE_MOVE, true);
   Signal_DebugEnsureHoverLabel(chartId);
}

#endif
