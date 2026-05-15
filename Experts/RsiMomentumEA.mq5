//+------------------------------------------------------------------+
//| RsiMomentumEA.mq5                                                |
//| EA tự động — logic độc lập (không đọc RsiMomentumIndicator).     |
//| RSI + EMA9/WMA45 trên RSI + EMA200(close), signal, mũi tên, panel |
//+------------------------------------------------------------------+
#property copyright "RsiMomentumEA"
#property version   "3.13"

#include <Trade/Trade.mqh>

//--- Input (khớp Indicators/RsiMomentumIndicator/Lib/Inputs.mqh)
input group "Chỉ báo"
input int    InpRSIPeriod         = 14;
input int    InpEMA9Period        = 9;
input int    InpWMA45Period       = 45;
input int    InpEMATrendPeriod    = 200;

input group "Bộ lọc trend"
input int    InpTrendConfirmBars  = 1;

input group "Bộ lọc RSI"
input double InpRSIOverbought     = 70.0;
input double InpRSIOversold       = 30.0;

input group "Bộ lọc EMA9 vs WMA45 (chống nhiễu)"
input int    InpEma9PersistBars   = 3;

input group "Mũi tên giao cắt"
input color  InpArrowUpColor      = clrLime;
input color  InpArrowDownColor    = clrTomato;
input int    InpArrowOffsetPts    = 30;
input int    InpArrowSize         = 1;

input group "Panel thông tin"
input bool   InpShowPanel         = true;
input color  InpPanelColorEMA9   = clrGold;        // chữ giá trị EMA9 (vàng)
input color  InpPanelColorWMA45  = clrDodgerBlue; // chữ giá trị WMA45 (xanh dương)

input group "Cảnh báo / Notification (khi có entry mới)"
input bool   InpAlertPush         = true;
input bool   InpAlertPopup        = true;
input bool   InpAlertSound        = true;
input string InpSoundBuy          = "alert.wav";
input string InpSoundSell         = "alert2.wav";
input bool   InpAlertEmail        = false;
input bool   InpAlertOnBar0       = false;

input group "Giao dịch tự động"
input bool   InpTradeEnabled      = true;
input ulong  InpMagic             = 202602;
input double InpRiskPercent       = 1.0;   // % balance mất nếu SL khớp (theo lot tính từ SL)
input double InpRewardRiskRatio   = 1.1;   // R:R — khoảng TP = tỷ lệ này × khoảng SL (ví dụ 1.5 = 1:1.5)
input int    InpSwingMaxBars      = 30;   // quét swing pivot / fallback min-max
input int    InpSlippagePoints    = 30;
input bool   InpOnePositionFlat   = true;

input group "Thống kê (góc dưới-trái chart)"
input bool   InpShowStats          = true;
input int    InpStatFontSize       = 9;
input color  InpStatColor          = clrSilver;

//--- Buffers & state (trùng State.mqh)
double buf_RSI[];
double buf_EMA9[];
double buf_WMA45[];
double buf_Signal[];
double buf_EMA200[];
double buf_Trend[];

int h_RSI    = INVALID_HANDLE;
int h_EMA9   = INVALID_HANDLE;
int h_WMA45  = INVALID_HANDLE;
int h_EMA200 = INVALID_HANDLE;

const string OBJ_PREFIX   = "RsiMomEA_";
const string LBL_TITLE    = OBJ_PREFIX + "title";
const string LBL_TREND    = OBJ_PREFIX + "trend";
const string LBL_RSI_VAL  = OBJ_PREFIX + "rsi";
const string LBL_EMA9VAL  = OBJ_PREFIX + "ema9";
const string LBL_WMA45VAL = OBJ_PREFIX + "wma45";

const string STAT_PREFIX = "RsiMomEA_ST_";
const string STAT_L1     = STAT_PREFIX + "line1";
const string STAT_L2     = STAT_PREFIX + "line2";
const string STAT_L3     = STAT_PREFIX + "line3";
// Khoảng cách dọc giữa các dòng thống kê (pixel): bước = fontSize + STAT_LINE_PAD
const int    STAT_Y_ANCHOR = 18;
const int    STAT_LINE_PAD = 16;

long   g_statExitDeals = 0;
long   g_statSL        = 0;
long   g_statTP        = 0;
long   g_statOther     = 0;
long   g_statWins      = 0;
double g_statSumProfit = 0.0;

datetime g_lastAlertBuyBar  = 0;
datetime g_lastAlertSellBar = 0;
bool     g_firstCalc        = true;
static int g_prevCalculated = 0;

datetime g_tradeBarAnchor = 0;

CTrade g_trade;

long ActChart() { return ChartID(); }

void   SetTradeFillingFromSymbol();
bool   NearestSwingSlTp(const bool isBuy, const double entry, const int dig, double &sl, double &tp);
bool   StopsValid(const bool isBuy, const double price, const double sl, const double tp);
int    CountMyMagicPositions();
double NormalizeLots(double v);
double VolumeForRiskPercent(const bool isBuy, const double entryRef, const double slPrice);
void   TradeTryOnBarOpen(const int calcRet);
void   Stats_CreateObjects();
void   Stats_UpdateDisplay();
void   OnTradeTransaction(const MqlTradeTransaction &trans,
                          const MqlTradeRequest &request,
                          const MqlTradeResult &result);

//+------------------------------------------------------------------+
bool Handles_CreateAll()
{
  h_RSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
  if (h_RSI == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle RSI");
    return false;
  }
  h_EMA9 = iMA(_Symbol, _Period, InpEMA9Period, 0, MODE_EMA, h_RSI);
  if (h_EMA9 == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle EMA9(RSI)");
    return false;
  }
  h_WMA45 = iMA(_Symbol, _Period, InpWMA45Period, 0, MODE_LWMA, h_RSI);
  if (h_WMA45 == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle WMA45(RSI)");
    return false;
  }
  h_EMA200 = iMA(_Symbol, _Period, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
  if (h_EMA200 == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle EMA200");
    return false;
  }
  return true;
}

//+------------------------------------------------------------------+
void Handles_ReleaseAll()
{
  if (h_RSI    != INVALID_HANDLE) IndicatorRelease(h_RSI);
  if (h_EMA9   != INVALID_HANDLE) IndicatorRelease(h_EMA9);
  if (h_WMA45  != INVALID_HANDLE) IndicatorRelease(h_WMA45);
  if (h_EMA200 != INVALID_HANDLE) IndicatorRelease(h_EMA200);
  h_RSI = h_EMA9 = h_WMA45 = h_EMA200 = INVALID_HANDLE;
}

//+------------------------------------------------------------------+
void CreateLabel(const string name, const string text, const color clr,
                 const int x, const int y, const int fontSize = 9)
{
  const long ch = ActChart();
  if (ObjectFind(ch, name) >= 0) return;
  ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(ch, name, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
  ObjectSetInteger(ch, name, OBJPROP_XDISTANCE,  x);
  ObjectSetInteger(ch, name, OBJPROP_YDISTANCE,  y);
  ObjectSetInteger(ch, name, OBJPROP_FONTSIZE,   fontSize);
  ObjectSetString (ch, name, OBJPROP_FONT,       "Consolas");
  ObjectSetInteger(ch, name, OBJPROP_BACK,       false);
  ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(ch, name, OBJPROP_HIDDEN,     true);
  ObjectSetInteger(ch, name, OBJPROP_COLOR,      clr);
  ObjectSetString (ch, name, OBJPROP_TEXT,       text);
}

//+------------------------------------------------------------------+
void UpdateLabel(const string name, const string text, const color clr)
{
  const long ch = ActChart();
  if (ObjectFind(ch, name) < 0) return;
  ObjectSetString (ch, name, OBJPROP_TEXT,  text);
  ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
void Panel_CreateAll()
{
  if (!InpShowPanel) return;
  CreateLabel(LBL_TITLE,    "─ RSI MOMENTUM (EA) ─", clrWhite,        10, 14, 10);
  CreateLabel(LBL_TREND,    "Trend : ---",         clrSilver,        10, 34, 9);
  CreateLabel(LBL_RSI_VAL,  "RSI   : ---",         clrMediumOrchid,  10, 51, 9);
  CreateLabel(LBL_EMA9VAL,  "EMA9  : ---",         InpPanelColorEMA9,   10, 68, 9);
  CreateLabel(LBL_WMA45VAL, "WMA45 : ---",         InpPanelColorWMA45,  10, 85, 9);
}

//+------------------------------------------------------------------+
void Panel_Update(const double &closeArr[], const double &ema200Arr[],
                  const int trendN, const int rates_total)
{
  if (!InpShowPanel) return;
  if (rates_total <= trendN + 1) return;
  if (ema200Arr[1] <= 0.0) return;

  bool panelTrendUp   = true;
  bool panelTrendDown = true;
  for (int k = 0; k < trendN; k++)
  {
    const int idx = 1 + k;
    if (ema200Arr[idx] <= 0.0) { panelTrendUp = false; panelTrendDown = false; break; }
    if (closeArr[idx] <= ema200Arr[idx]) panelTrendUp   = false;
    if (closeArr[idx] >= ema200Arr[idx]) panelTrendDown = false;
  }

  string trendTxt;
  color  trendClr;
  if      (panelTrendUp)   { trendTxt = StringFormat("Trend :  UPTREND   (%d closes > EMA200)", trendN); trendClr = InpArrowUpColor; }
  else if (panelTrendDown) { trendTxt = StringFormat("Trend :  DOWNTREND (%d closes < EMA200)", trendN); trendClr = InpArrowDownColor; }
  else                     { trendTxt = "Trend :  RANGE / SWITCHING";                                    trendClr = clrSilver; }

  UpdateLabel(LBL_TREND,    trendTxt, trendClr);
  UpdateLabel(LBL_RSI_VAL,  StringFormat("RSI   : %6.2f", buf_RSI[1]),  clrMediumOrchid);
  UpdateLabel(LBL_EMA9VAL,  StringFormat("EMA9  : %6.2f", buf_EMA9[1]), InpPanelColorEMA9);
  UpdateLabel(LBL_WMA45VAL, StringFormat("WMA45 : %6.2f", buf_WMA45[1]), InpPanelColorWMA45);
}

//+------------------------------------------------------------------+
void FireSignalAlert(const bool isBuy, const datetime barTime, const double price,
                     const double rsiVal, const double ema9Val, const double wma45Val, const double ema200Val)
{
  const string dir   = isBuy ? "BUY" : "SELL";
  const string tf    = EnumToString((ENUM_TIMEFRAMES)_Period);
  const string tfTxt = StringSubstr(tf, 7);
  const int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

  const string pushMsg = StringFormat("[RsiMomEA] %s %s %s @ %s | RSI=%.1f EMA9=%.1f WMA45=%.1f",
                                      dir, _Symbol, tfTxt, DoubleToString(price, dig), rsiVal, ema9Val, wma45Val);
  const string fullMsg = StringFormat("RsiMomEA %s signal\n%s %s @ %s\nRSI=%.2f  EMA9=%.2f  WMA45=%.2f\nEMA200=%s\nBar: %s",
                                      dir, _Symbol, tfTxt, DoubleToString(price, dig),
                                      rsiVal, ema9Val, wma45Val, DoubleToString(ema200Val, dig),
                                      TimeToString(barTime, TIME_DATE|TIME_MINUTES));

  if (InpAlertPush)
  {
    if (!SendNotification(pushMsg))
      PrintFormat("[RsiMomEA] SendNotification FAILED err=%d", GetLastError());
  }
  if (InpAlertPopup)
    Alert(pushMsg);
  if (InpAlertSound)
  {
    const string snd = isBuy ? InpSoundBuy : InpSoundSell;
    if (StringLen(snd) > 0)
      PlaySound(snd);
  }
  if (InpAlertEmail)
    SendMail(StringFormat("RsiMomEA %s %s %s", dir, _Symbol, tfTxt), fullMsg);

  Print("[RsiMomEA] >>> ", pushMsg);
}

//+------------------------------------------------------------------+
void Alerts_CheckAndFire(const datetime &timeArr[], const double &closeArr[],
                         const double &ema200Arr[], const int need, const int rates_total)
{
  if (g_firstCalc)
  {
    if (need > 1)
    {
      g_lastAlertBuyBar  = timeArr[1];
      g_lastAlertSellBar = timeArr[1];
    }
    g_firstCalc = false;
    return;
  }

  const int alertShift = InpAlertOnBar0 ? 0 : 1;
  if (alertShift >= need || alertShift + 1 >= rates_total) return;

  const datetime alertBarTime = timeArr[alertShift];

  if (buf_Signal[alertShift] > 0.5 && alertBarTime != g_lastAlertBuyBar)
  {
    FireSignalAlert(true, alertBarTime, closeArr[alertShift],
                    buf_RSI[alertShift], buf_EMA9[alertShift], buf_WMA45[alertShift], ema200Arr[alertShift]);
    g_lastAlertBuyBar = alertBarTime;
  }
  else if (buf_Signal[alertShift] < -0.5 && alertBarTime != g_lastAlertSellBar)
  {
    FireSignalAlert(false, alertBarTime, closeArr[alertShift],
                    buf_RSI[alertShift], buf_EMA9[alertShift], buf_WMA45[alertShift], ema200Arr[alertShift]);
    g_lastAlertSellBar = alertBarTime;
  }
}

//+------------------------------------------------------------------+
void SignalScan_Run(const int barsToScan, const int rates_total, const int need, const int trendN,
                    const datetime &timeArr[], const double &highArr[], const double &lowArr[],
                    const double &closeArr[], const double &ema200Arr[])
{
  const long   ch    = ActChart();
  const double arrowOffset = InpArrowOffsetPts * _Point;

  buf_Signal[0] = 0.0;
  buf_Trend[0]  = 0.0;
  buf_EMA200[0] = (need > 0) ? ema200Arr[0] : 0.0;

  for (int i = barsToScan; i >= 1; i--)
  {
    buf_Signal[i] = 0.0;
    buf_Trend[i]  = 0.0;
    buf_EMA200[i] = (i < need) ? ema200Arr[i] : 0.0;

    if (i + 1 >= rates_total) continue;
    if (i + trendN >= need) continue;
    if (ema200Arr[i] <= 0.0) continue;

    bool trendUp   = true;
    bool trendDown = true;
    for (int k = 0; k < trendN; k++)
    {
      const int idx = i + k;
      if (ema200Arr[idx] <= 0.0) { trendUp = false; trendDown = false; break; }
      if (closeArr[idx] <= ema200Arr[idx]) trendUp   = false;
      if (closeArr[idx] >= ema200Arr[idx]) trendDown = false;
      if (!trendUp && !trendDown) break;
    }
    buf_Trend[i] = trendUp ? 1.0 : (trendDown ? -1.0 : 0.0);

    const bool crossUp   = (buf_RSI[i+1] <= buf_WMA45[i+1]) && (buf_RSI[i] > buf_WMA45[i]);
    const bool crossDown = (buf_RSI[i+1] >= buf_WMA45[i+1]) && (buf_RSI[i] < buf_WMA45[i]);
    if (!crossUp && !crossDown) continue;

    const bool ema9BelowWma  = (buf_EMA9[i] < buf_WMA45[i]);
    const bool ema9AboveWma = (buf_EMA9[i] > buf_WMA45[i]);

    const int persistN = MathMax(1, InpEma9PersistBars);
    bool ema9PersistBelow = ema9BelowWma;
    bool ema9PersistAbove = ema9AboveWma;
    if (persistN > 1)
    {
      if (i + persistN - 1 >= rates_total)
      {
        ema9PersistBelow = false;
        ema9PersistAbove = false;
      }
      else
      {
        for (int k = 1; k < persistN; k++)
        {
          if (buf_EMA9[i+k] >= buf_WMA45[i+k]) ema9PersistBelow = false;
          if (buf_EMA9[i+k] <= buf_WMA45[i+k]) ema9PersistAbove = false;
          if (!ema9PersistBelow && !ema9PersistAbove) break;
        }
      }
    }

    const bool ema9SlopeUp   = (buf_EMA9[i] > buf_EMA9[i+1]);
    const bool ema9SlopeDown = (buf_EMA9[i] < buf_EMA9[i+1]);
    const bool rsiOkBuy     = (buf_RSI[i] < InpRSIOverbought);
    const bool rsiOkSell    = (buf_RSI[i] > InpRSIOversold);

    const bool validBuy  = crossUp   && trendUp   && ema9PersistBelow && ema9SlopeUp   && rsiOkBuy;
    const bool validSell = crossDown && trendDown && ema9PersistAbove && ema9SlopeDown && rsiOkSell;
    if (!validBuy && !validSell) continue;

    const string arrowName = OBJ_PREFIX + "CR_" + IntegerToString((int)timeArr[i]);
    if (ObjectFind(ch, arrowName) >= 0) continue;

    if (validBuy)
    {
      buf_Signal[i] = 1.0;
      const double price = lowArr[i] - arrowOffset;
      ObjectCreate(ch, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(ch, arrowName, OBJPROP_ARROWCODE,  233);
      ObjectSetInteger(ch, arrowName, OBJPROP_ANCHOR,     ANCHOR_TOP);
      ObjectSetInteger(ch, arrowName, OBJPROP_COLOR,      InpArrowUpColor);
      ObjectSetInteger(ch, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(ch, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ch, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (ch, arrowName, OBJPROP_TOOLTIP, "BUY (EA)");
    }
    else
    {
      buf_Signal[i] = -1.0;
      const double price = highArr[i] + arrowOffset;
      ObjectCreate(ch, arrowName, OBJ_ARROW, 0, timeArr[i], price);
      ObjectSetInteger(ch, arrowName, OBJPROP_ARROWCODE,  234);
      ObjectSetInteger(ch, arrowName, OBJPROP_ANCHOR,     ANCHOR_BOTTOM);
      ObjectSetInteger(ch, arrowName, OBJPROP_COLOR,      InpArrowDownColor);
      ObjectSetInteger(ch, arrowName, OBJPROP_WIDTH,      InpArrowSize);
      ObjectSetInteger(ch, arrowName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ch, arrowName, OBJPROP_HIDDEN,     true);
      ObjectSetString (ch, arrowName, OBJPROP_TOOLTIP, "SELL (EA)");
    }
  }
}

//+------------------------------------------------------------------+
void Diagnostics_FirstPass(const int rates_total, const int copyN, const int trendN,
                           const int need, const double &closeArr[])
{
  static bool firstSuccess = false;
  if (firstSuccess || copyN < rates_total) return;
  firstSuccess = true;

  int upCount = 0, downCount = 0, rangeCount = 0, zeroEma = 0;
  const int n = MathMin(500, rates_total - 2);
  for (int i = 1; i <= n; i++)
  {
    if (buf_EMA200[i] <= 0.0) zeroEma++;
    if      (buf_Trend[i] >  0.5) upCount++;
    else if (buf_Trend[i] < -0.5) downCount++;
    else                          rangeCount++;
  }
  PrintFormat("[RsiMomEA] First-pass OK rates_total=%d copyN=%d trendN=%d need=%d", rates_total, copyN, trendN, need);
  PrintFormat("[RsiMomEA]   bar1: RSI=%.2f EMA9=%.2f WMA45=%.2f EMA200=%.5f Trend=%.0f Signal=%.0f close[1]=%.5f",
              buf_RSI[1], buf_EMA9[1], buf_WMA45[1], buf_EMA200[1], buf_Trend[1], buf_Signal[1], closeArr[1]);
  PrintFormat("[RsiMomEA]   last %d bars trend dist: UP=%d DOWN=%d RANGE=%d (zeroEma200=%d)",
              n, upCount, downCount, rangeCount, zeroEma);
}

//+------------------------------------------------------------------+
void EnsureBuffers(const int rates_total)
{
  if (rates_total <= 0) return;
  ArrayResize(buf_RSI,    rates_total);
  ArrayResize(buf_EMA9, rates_total);
  ArrayResize(buf_WMA45,rates_total);
  ArrayResize(buf_Signal,rates_total);
  ArrayResize(buf_EMA200,rates_total);
  ArrayResize(buf_Trend, rates_total);
  ArraySetAsSeries(buf_RSI,    true);
  ArraySetAsSeries(buf_EMA9,   true);
  ArraySetAsSeries(buf_WMA45,  true);
  ArraySetAsSeries(buf_Signal, true);
  ArraySetAsSeries(buf_EMA200, true);
  ArraySetAsSeries(buf_Trend,  true);
}

//+------------------------------------------------------------------+
int RsiMomentum_OnCalculate(const int rates_total, const int prev_calculated)
{
  const int minBars = InpWMA45Period + InpRSIPeriod + 5;
  if (rates_total < minBars) return 0;

  EnsureBuffers(rates_total);

  const int rsiBars    = BarsCalculated(h_RSI);
  const int ema9Bars   = BarsCalculated(h_EMA9);
  const int wmaBars    = BarsCalculated(h_WMA45);
  const int ema200Bars = BarsCalculated(h_EMA200);
  if (rsiBars <= 0 || ema9Bars <= 0 || wmaBars <= 0 || ema200Bars <= 0)
  {
    static datetime lastWarn = 0;
    if (TimeCurrent() - lastWarn > 30)
    {
      PrintFormat("[RsiMomEA] Source not ready: RSI=%d EMA9=%d WMA45=%d EMA200=%d (rates=%d)",
                  rsiBars, ema9Bars, wmaBars, ema200Bars, rates_total);
      lastWarn = TimeCurrent();
    }
    return 0;
  }

  const int srcMin = MathMin(MathMin(MathMin(rsiBars, ema9Bars), wmaBars), ema200Bars);
  const int copyN  = MathMin(srcMin, rates_total);
  if (copyN < minBars) return 0;

  if (CopyBuffer(h_RSI,   0, 0, copyN, buf_RSI)    <= 0) return 0;
  if (CopyBuffer(h_EMA9,  0, 0, copyN, buf_EMA9)   <= 0) return 0;
  if (CopyBuffer(h_WMA45, 0, 0, copyN, buf_WMA45)  <= 0) return 0;

  int barsToScan = (prev_calculated == 0)
                   ? rates_total - 2
                   : (rates_total - prev_calculated + 2);
  barsToScan = MathMin(barsToScan, rates_total - 2);

  const int trendN = MathMax(1, InpTrendConfirmBars);
  const int need   = MathMin(barsToScan + 2 + trendN, copyN);

  datetime timeArr[];
  double   highArr[], lowArr[], closeArr[], ema200Arr[];
  ArraySetAsSeries(timeArr,   true);
  ArraySetAsSeries(highArr,   true);
  ArraySetAsSeries(lowArr,    true);
  ArraySetAsSeries(closeArr,  true);
  ArraySetAsSeries(ema200Arr, true);

  if (CopyTime  (_Symbol, _Period, 0, need, timeArr)   < need) return prev_calculated;
  if (CopyHigh  (_Symbol, _Period, 0, need, highArr)   < need) return prev_calculated;
  if (CopyLow   (_Symbol, _Period, 0, need, lowArr)    < need) return prev_calculated;
  if (CopyClose (_Symbol, _Period, 0, need, closeArr) < need) return prev_calculated;
  if (CopyBuffer(h_EMA200, 0, 0, need, ema200Arr)      < need) return prev_calculated;

  SignalScan_Run(barsToScan, rates_total, need, trendN, timeArr, highArr, lowArr, closeArr, ema200Arr);
  Alerts_CheckAndFire(timeArr, closeArr, ema200Arr, need, rates_total);
  Panel_Update(closeArr, ema200Arr, trendN, rates_total);

  ChartRedraw(ActChart());
  Diagnostics_FirstPass(rates_total, copyN, trendN, need, closeArr);

  return copyN;
}

//+------------------------------------------------------------------+
int OnInit()
{
  g_lastAlertBuyBar  = 0;
  g_lastAlertSellBar = 0;
  g_firstCalc        = true;
  g_prevCalculated   = 0;
  g_tradeBarAnchor   = iTime(_Symbol, _Period, 0);

  g_statExitDeals = 0;
  g_statSL        = 0;
  g_statTP        = 0;
  g_statOther     = 0;
  g_statWins      = 0;
  g_statSumProfit = 0.0;

  g_trade.SetExpertMagicNumber(InpMagic);
  g_trade.SetDeviationInPoints(InpSlippagePoints);
  SetTradeFillingFromSymbol();

  if (!Handles_CreateAll())
    return INIT_FAILED;

  Panel_CreateAll();
  Stats_CreateObjects();
  Stats_UpdateDisplay();
  Print("[RsiMomEA] Init OK — trade=", InpTradeEnabled ? "on" : "off", " risk%=", InpRiskPercent);
  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  Handles_ReleaseAll();
  ObjectsDeleteAll(ActChart(), OBJ_PREFIX);
  ObjectsDeleteAll(ActChart(), STAT_PREFIX);
  ChartRedraw(ActChart());
}

//+------------------------------------------------------------------+
void OnTick()
{
  const int rates_total = Bars(_Symbol, _Period);
  const int ret = RsiMomentum_OnCalculate(rates_total, g_prevCalculated);
  if (ret != 0)
    g_prevCalculated = ret;

  const datetime t0 = iTime(_Symbol, _Period, 0);
  if (t0 != 0 && t0 != g_tradeBarAnchor)
  {
    g_tradeBarAnchor = t0;
    TradeTryOnBarOpen(ret);
  }
}

//+------------------------------------------------------------------+
void TradeTryOnBarOpen(const int calcRet)
{
  if (!InpTradeEnabled)
    return;
  if (!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    return;
  if (calcRet <= 0)
    return;
  if (ArraySize(buf_Signal) < 2)
    return;

  const double s = buf_Signal[1];
  if (s > -0.5 && s < 0.5)
    return;

  const bool isBuy = (s > 0.5);

  if (InpOnePositionFlat && CountMyMagicPositions() > 0)
    return;

  MqlTick tk;
  if (!SymbolInfoTick(_Symbol, tk))
    return;

  const int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  const double entry = isBuy ? tk.ask : tk.bid;
  double       sl = 0.0, tp = 0.0;

  if (!NearestSwingSlTp(isBuy, entry, dig, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: SL/TP swing không hợp lệ");
    return;
  }
  if (!StopsValid(isBuy, entry, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: STOPS_LEVEL / FREEZE");
    return;
  }

  const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
  const double riskMoney = balance * (InpRiskPercent / 100.0);
  double       vol       = VolumeForRiskPercent(isBuy, entry, sl);
  vol = NormalizeLots(vol);
  if (vol <= 0.0)
  {
    Print("[RsiMomEA] Trade skip: volume=0");
    return;
  }

  const bool ok = isBuy
                  ? g_trade.Buy(vol, _Symbol, tk.ask, sl, tp, "RsiMom BUY")
                  : g_trade.Sell(vol, _Symbol, tk.bid, sl, tp, "RsiMom SELL");

  if (!ok)
    Print("[RsiMomEA] Order fail ", g_trade.ResultRetcode(), " ", g_trade.ResultComment());
  else
    Print("[RsiMomEA] Order OK #", g_trade.ResultOrder(), " ", isBuy ? "BUY" : "SELL",
          " vol=", vol, " SL=", DoubleToString(sl, dig), " TP=", DoubleToString(tp, dig));
}

//+------------------------------------------------------------------+
bool NearestSwingSlTp(const bool isBuy, const double entry, const int dig, double &sl, double &tp)
{
  const double rr = MathMax(0.01, InpRewardRiskRatio);
  const int mx = MathMax(5, InpSwingMaxBars);
  const int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  const double buf = spr * _Point;

  if (isBuy)
  {
    double pivotLow = 0.0;
    bool   found = false;
    for (int i = 2; i <= mx; i++)
    {
      const double L = iLow(_Symbol, _Period, i);
      if (L < iLow(_Symbol, _Period, i - 1) && L < iLow(_Symbol, _Period, i + 1))
      {
        pivotLow = L;
        found = true;
        break;
      }
    }
    if (!found)
    {
      pivotLow = iLow(_Symbol, _Period, 2);
      for (int j = 3; j <= mx; j++)
        pivotLow = MathMin(pivotLow, iLow(_Symbol, _Period, j));
    }
    sl = NormalizeDouble(pivotLow - buf, dig);
    const double risk = entry - sl;
    if (risk <= _Point * 2)
      return false;
    tp = NormalizeDouble(entry + risk * rr, dig);
  }
  else
  {
    double pivotHigh = 0.0;
    bool   found = false;
    for (int i = 2; i <= mx; i++)
    {
      const double H = iHigh(_Symbol, _Period, i);
      if (H > iHigh(_Symbol, _Period, i - 1) && H > iHigh(_Symbol, _Period, i + 1))
      {
        pivotHigh = H;
        found = true;
        break;
      }
    }
    if (!found)
    {
      pivotHigh = iHigh(_Symbol, _Period, 2);
      for (int j = 3; j <= mx; j++)
        pivotHigh = MathMax(pivotHigh, iHigh(_Symbol, _Period, j));
    }
    sl = NormalizeDouble(pivotHigh + buf, dig);
    const double risk = sl - entry;
    if (risk <= _Point * 2)
      return false;
    tp = NormalizeDouble(entry - risk * rr, dig);
  }
  return true;
}

//+------------------------------------------------------------------+
bool StopsValid(const bool isBuy, const double price, const double sl, const double tp)
{
  const int    stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  const int    freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
  const double md = (stops > freeze ? stops : freeze) * _Point;
  if (md <= 0.0)
    return true;

  if (isBuy)
  {
    if (price - sl < md - _Point) return false;
    if (tp - price < md - _Point) return false;
  }
  else
  {
    if (sl - price < md - _Point) return false;
    if (price - tp < md - _Point) return false;
  }
  return true;
}

//+------------------------------------------------------------------+
int CountMyMagicPositions()
{
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    if (!PositionGetTicket(i))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      continue;
    n++;
  }
  return n;
}

//+------------------------------------------------------------------+
double VolumeForRiskPercent(const bool isBuy, const double entryRef, const double slPrice)
{
  if (MathAbs(entryRef - slPrice) < _Point)
    return 0.0;

  const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
  const double riskMoney = balance * (InpRiskPercent / 100.0);

  double profit = 0.0;
  if (!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol, 1.0, entryRef, slPrice, profit))
    return 0.0;

  const double lossPerLot = MathAbs(profit);
  if (lossPerLot < DBL_EPSILON)
    return 0.0;

  return riskMoney / lossPerLot;
}

//+------------------------------------------------------------------+
double NormalizeLots(double v)
{
  const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step <= 0.0)
    return 0.0;
  v = MathFloor(v / step) * step;
  if (v < vmin - 1e-12)
    return 0.0;
  if (v > vmax)
    v = vmax;
  return NormalizeDouble(v, 8);
}

//+------------------------------------------------------------------+
void SetTradeFillingFromSymbol()
{
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)
    g_trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0)
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);
  else
    g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
void Stats_CreateObjects()
{
  const long ch = ActChart();
  const int  fs = MathMax(7, InpStatFontSize);
  const int  step = fs + STAT_LINE_PAD;

  for (int k = 0; k < 3; k++)
  {
    const string name = (k == 0) ? STAT_L1 : ((k == 1) ? STAT_L2 : STAT_L3);
    if (ObjectFind(ch, name) >= 0)
      continue;
    ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(ch, name, OBJPROP_CORNER,      CORNER_LEFT_LOWER);
    ObjectSetInteger(ch, name, OBJPROP_XDISTANCE,   8);
    ObjectSetInteger(ch, name, OBJPROP_YDISTANCE,   STAT_Y_ANCHOR + k * step);
    ObjectSetInteger(ch, name, OBJPROP_FONTSIZE,    fs);
    ObjectSetString (ch, name, OBJPROP_FONT,      "Consolas");
    ObjectSetInteger(ch, name, OBJPROP_COLOR,       InpStatColor);
    ObjectSetInteger(ch, name, OBJPROP_BACK,      false);
    ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(ch, name, OBJPROP_HIDDEN,    false);
    ObjectSetString (ch, name, OBJPROP_TEXT,      "");
  }
}

//+------------------------------------------------------------------+
void Stats_UpdateDisplay()
{
  const long ch = ActChart();

  if (ObjectFind(ch, STAT_L1) < 0)
    return;

  if (!InpShowStats)
  {
    ObjectSetString(ch, STAT_L1, OBJPROP_TEXT, "");
    ObjectSetString(ch, STAT_L2, OBJPROP_TEXT, "");
    ObjectSetString(ch, STAT_L3, OBJPROP_TEXT, "");
    ChartRedraw(ch);
    return;
  }

  const int fs   = MathMax(7, InpStatFontSize);
  const int step = fs + STAT_LINE_PAD;
  for (int k = 0; k < 3; k++)
  {
    const string nm = (k == 0) ? STAT_L1 : ((k == 1) ? STAT_L2 : STAT_L3);
    ObjectSetInteger(ch, nm, OBJPROP_FONTSIZE,  fs);
    ObjectSetInteger(ch, nm, OBJPROP_YDISTANCE, STAT_Y_ANCHOR + k * step);
  }

  string line1 = StringFormat("Total: %I64d | SL %I64d | TP %I64d",
                              g_statExitDeals, g_statSL, g_statTP);
  if (g_statOther > 0)
    line1 += StringFormat(" | Other %I64d", g_statOther);

  double winrate = 0.0;
  if (g_statExitDeals > 0)
    winrate = 100.0 * (double)g_statWins / (double)g_statExitDeals;

  const string cur = AccountInfoString(ACCOUNT_CURRENCY);
  double avg = 0.0;
  if (g_statExitDeals > 0)
    avg = g_statSumProfit / (double)g_statExitDeals;

  const string line2 = StringFormat("Winrate: %.1f%%", winrate);
  const string line3 = StringFormat("Average Profit / trade: %s %s",
                                     DoubleToString(avg, 2), cur);

  ObjectSetString (ch, STAT_L1, OBJPROP_TEXT, line1);
  ObjectSetInteger(ch, STAT_L1, OBJPROP_COLOR, InpStatColor);
  ObjectSetString (ch, STAT_L2, OBJPROP_TEXT, line2);
  ObjectSetInteger(ch, STAT_L2, OBJPROP_COLOR, InpStatColor);
  ObjectSetString (ch, STAT_L3, OBJPROP_TEXT, line3);
  ObjectSetInteger(ch, STAT_L3, OBJPROP_COLOR, InpStatColor);
  ChartRedraw(ch);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD)
    return;

  const ulong dealTicket = trans.deal;
  if (dealTicket == 0)
    return;

  if (!HistoryDealSelect(dealTicket))
    return;

  if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
    return;
  if ((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
    return;

  const long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
  if (entry != DEAL_ENTRY_OUT)
    return;

  const double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

  const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);

  g_statExitDeals++;
  g_statSumProfit += profit;
  if (profit > 0.0)
    g_statWins++;

  if (reason == DEAL_REASON_SL)
    g_statSL++;
  else if (reason == DEAL_REASON_TP)
    g_statTP++;
  else
    g_statOther++;

  Stats_UpdateDisplay();
}

//+------------------------------------------------------------------+
