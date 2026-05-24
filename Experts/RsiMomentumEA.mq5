//+------------------------------------------------------------------+
//| RsiMomentumEA.mq5                                                |
//| EA tự động — logic độc lập (không đọc RsiMomentumIndicator).     |
//| RSI×WMA45 + 5phase | ATR↑ ADX trend EMA200 phiên | Limit 50% body |
//+------------------------------------------------------------------+
#property copyright "RsiMomentumEA"
#property version   "4.31"

#include <Trade/Trade.mqh>
#include <RsiMom/TradeJournal.mqh>
#include <RsiMom/PhaseEntry.mqh>
#include <RsiMom/AdxFilter.mqh>
#include <RsiMom/SwingStructure.mqh>
#include <RsiMom/SignalDebug.mqh>

//--- Cơ chế vào lệnh (switch test — logic Limit giữ nguyên trong TradeExecuteLimitOrder)
enum ENUM_RSI_MOM_ENTRY_MODE
{
   RSI_MOM_ENTRY_LIMIT_BODY50 = 0,  // Limit @ 50% thân nến tín hiệu (mặc định)
   RSI_MOM_ENTRY_MARKET       = 1   // Market ngay khi nến mới sau tín hiệu
};

//--- Input (khớp Indicators/RsiMomentumIndicator/Lib/Inputs.mqh)
input group "Chỉ báo"
input int    InpRSIPeriod         = 14;
input int    InpEMA9Period        = 9;
input int    InpWMA45Period       = 45;
input int    InpEMATrendPeriod    = 200;

input group "Bộ lọc tín hiệu (RSI + ATR + trend EMA200)"
input bool   InpTrendFilterEnabled   = true;   // BUY: close > EMA200 | SELL: close < EMA200
input int    InpTrendConfirmBars    = 1;     // BUY: N close > EMA200 | SELL: N close < EMA200
input bool   InpAtrExpFilterEnabled  = false;  // tắt tạm — test riêng ADX
input int    InpAtrExpPeriod         = 14;
input int    InpAtrExpCompareBars    = 3;      // so ATR[shift] vs ATR[shift+N]
input double InpAtrExpMinRatio       = 1.005;  // ≥1.005 = +0.5% (tối ưu 1.003–1.02)
input int    InpAtrExpRiseBars       = 2;      // ATR tăng liên tiếp N nến (1 = lỏng hơn)

input group "ADX — trend mạnh (pullback hiệu quả)"
input bool   InpAdxFilterEnabled     = true;   // ADX + hướng +DI/-DI tại nến tín hiệu
input int    InpAdxPeriod            = 14;
input double InpAdxMinLevel          = 22.0;   // ADX >= ngưỡng (sideway ~<20, trend 22–35+)
input double InpAdxMaxLevel          = 0.0;    // 0=tắt; ví dụ 45 tránh trend quá già
input bool   InpAdxRequireDiDirection = true; // BUY +DI>-DI | SELL -DI>+DI
input double InpAdxMinDiSpread       = 0.0;    // |+DI−(-DI)| tối thiểu (5–10 = chặt hơn)
input int    InpAdxRiseBars          = 0;     // ADX tăng vs N nến trước (0=tắt, 1–2 bật)

input group "2 swing — đáy tăng / đỉnh giảm (thân nến)"
input bool   InpSwingStructFilterEnabled = true;
input int    InpSwingStructRange         = 2;     // pivot: N nến mỗi bên mỗi đáy/đỉnh
input int    InpSwingStructLookback      = 120;   // quét tối đa N nến trước tín hiệu
input double InpSwingStructTolPts        = 0.0;   // cho phép 2 đáy/đỉnh bằng nhau (points)

input group "Lọc RSI quá mua / quá bán (nến tín hiệu)"
input bool   InpRsiObOsFilterEnabled = true;   // BUY khi RSI<70 | SELL khi RSI>30
input double InpRSIOverbought        = 70.0;  // RSI ≥ ngưỡng → bỏ BUY
input double InpRSIOversold          = 30.0;  // RSI ≤ ngưỡng → bỏ SELL

input group "Entry 5 phase (mở rộng → cuộn EMA9 → EMA9 hướng → WMA45 phẳng → cắt gần)"
input bool   InpPhaseFilterEnabled   = true;
input int    InpPhaseExpandLookback  = 25;    // P1: quét mở rộng 3 đường
input double InpPhaseMinExpandSpread = 10.0;  // P1: min max(WMA45-RSI) pt RSI [tối ưu ~6–18, step 1]
input int    InpPhaseCoilLookback    = 12;    // P2: quét cuộn trước nến tín hiệu
input int    InpPhaseMinRsiEma9Cross = 2;     // P2: RSI cắt EMA9 ≥ N lần (chống xuyên 1 lần)
input double InpPhaseCoilBand        = 6.0;   // P2: |RSI-EMA9| ≤ band = quanh EMA9
input int    InpPhaseEma9SlopeBars   = 2;     // P3: cửa sổ so sánh EMA9 (nhỏ hơn = lỏng hơn)
input double InpPhaseEma9SlopeTol    = 1.5;   // P3: cho phép EMA9 lệch ngược tối đa (pt RSI)
input int    InpPhaseWmaFlatBars     = 4;     // P4: WMA45 phẳng — cửa sổ slope
input double InpPhaseWmaWasSlopeMin  = 0.08;  // P4: dốc tối thiểu quá khứ (khi RelaxPrior=false)
input double InpPhaseWmaFlatMaxSlope  = 0.55;  // P4: |slope| WMA45 gần 0 tại signal (lớn hơn = lỏng)
input bool   InpPhaseWmaRelaxPrior   = true;  // P4: chỉ cần WMA45 từng đi đúng hướng, không cần dốc mạnh
input double InpPhaseMaxEma9WmaGap   = 16.0;  // P5: EMA9–WMA45 tối đa khi cắt (lớn hơn = lỏng)

input group "Cơ chế vào lệnh (switch test)"
input ENUM_RSI_MOM_ENTRY_MODE InpEntryMode = RSI_MOM_ENTRY_MARKET;

input group "Entry — Limit 50% thân nến (chỉ InpEntryMode=Limit)"
input int    InpSignalBarShift      = 1;     // nến tín hiệu (1 = nến vừa đóng)

input group "Quản lý Limit pending (chỉ InpEntryMode=Limit)"
input int    InpLimitExpireBars     = 40;    // hủy Limit nếu không khớp sau N nến

input group "Debug — đánh dấu RSI×WMA45 (tắt = backtest nhanh)"
input bool   InpDebugMarkSignals  = false;  // mọi cross: OK xanh | SIG vàng | SKIP đỏ
input int    InpDebugMarkMaxBars  = 400;    // chỉ tạo mới trong N nến gần nhất
input bool   InpDebugLogExperts   = false;  // 1 dòng Experts / nến tín hiệu
input bool   InpDebugHoverHint    = false;  // rê chuột lên dấu X

input group "Mũi tên giao cắt"
input color  InpArrowUpColor      = clrLime;
input color  InpArrowDownColor    = clrTomato;
input int    InpArrowOffsetPts    = 30;
input int    InpArrowSize         = 1;

input group "Panel trạng thái (góc trên-trái)"
input bool   InpShowPanel         = false;  // tắt = tester nhanh hơn
input int    InpPanelFontSize     = 8;
input int    InpPanelLinePad      = 14;     // khoảng cách dọc giữa các dòng
input int    InpPanelLeftMargin   = 8;
input int    InpPanelTopMargin    = 10;
input color  InpPanelColorEMA9   = clrGold;
input color  InpPanelColorWMA45  = clrDodgerBlue;

input group "Cảnh báo / Notification (khi có entry mới)"
input bool   InpAlertPush         = false;
input bool   InpAlertPopup        = false;
input bool   InpAlertSound        = false;
input string InpSoundBuy          = "alert.wav";
input string InpSoundSell         = "alert2.wav";
input bool   InpAlertEmail        = false;
input bool   InpAlertOnBar0       = false;

input group "Giao dịch tự động"
input bool   InpTradeEnabled      = true;
input ulong  InpMagic             = 202602;
input double InpRiskPercent       = 1;   // % balance mất nếu SL khớp (theo lot tính từ SL)
input double InpRewardRiskRatio   = 1.05;   // R:R — TP = tỷ lệ × khoảng SL (2.0 = 1:2)
input int    InpSwingMaxBars      = 30;   // quét swing pivot / fallback min-max
input int    InpSlippagePoints    = 30;
input bool   InpOnePositionFlat   = true;

input group "Phiên & spread (chỉ trade khi pass)"
input bool   InpSessionFilterEnabled    = true;  // London/NY + chặn giao phiên
input bool   InpEnvUseUtc               = false;  // false = giờ server/broker
input int    InpLondonStartHour         = 8;
input int    InpLondonEndHour           = 17;
input int    InpNYStartHour             = 13;
input int    InpNYEndHour               = 22;
input int    InpSessionAvoidLastMin     = 15;     // bỏ N phút cuối mỗi phiên
input bool   InpTransitionBlockEnabled  = true;   // chặn giao phiên / thanh khoản thấp
input int    InpTransition1StartHour    = 7;      // ví dụ trước London
input int    InpTransition1EndHour      = 8;
input int    InpTransition2StartHour    = 21;     // ví dụ đóng NY / rollover
input int    InpTransition2EndHour      = 22;
input bool   InpSpreadFilterEnabled     = true;
input int    InpMaxSpreadPoints         = 60;     // SYMBOL_SPREAD (points) tối đa
input bool   InpSpreadSkipInTester      = true;   // Tester: bỏ lọc spread (spread cố định thường quá cao)
input bool   InpTesterCalcOnNewBarOnly  = true;   // Tester: OnCalculate chỉ khi nến mới (tránh chậm dần)

input group "Quản lý lệnh mở @ 1R"
input bool   InpManageAt1R          = false;  // @1R: chốt một phần + dời SL về entry
input double InpPartialCloseRatio   = 0.5;   // tỷ lệ volume chốt khi đạt 1R (0.5 = 50%)
input int    InpBreakevenOffsetPts  = 0;    // SL tại entry ± point (0 = đúng entry)

input group "SL buffer theo ATR (đẩy SL xa đáy/đỉnh swing)"
input bool   InpSlAtrBufferEnabled = true;
input int    InpSlAtrPeriod         = 14;
input double InpSlAtrMultiplier     = 0.5;   // khoảng cách thêm = ATR(shift 1) × hệ số
input bool   InpSlAtrAddSpread      = true;  // cộng thêm buffer spread vào SL

input group "Xuất CSV thống kê (FILE_COMMON)"
input bool   InpExportTradeJournal = false;  // bật lại khi cần phân tích CSV (chậm hơn một chút)
input bool   InpJournalResetOnInit = true;   // Tester: xóa CSV cũ mỗi lần chạy backtest mới

input group "Thống kê (góc dưới-trái chart)"
input bool   InpShowStats          = true;  // tắt = tester nhanh hơn
input int    InpStatFontSize       = 9;
input int    InpStatLinePad        = 26;    // khoảng cách dọc giữa các dòng (pixel)
input int    InpStatBottomMargin   = 28;    // lề dưới block thống kê
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
int h_ATR        = INVALID_HANDLE;
int h_ATR_Regime = INVALID_HANDLE;
int h_ADX        = INVALID_HANDLE;

const string OBJ_PREFIX   = "RsiMomEA_";
const string DBG_PREFIX   = OBJ_PREFIX + "DBG_";
#define PANEL_LINE_COUNT 25
#define PANEL_IDX_MARKET 19   // dòng 19+ = RSI / signal (sau block trạng thái)
const string PNL_PREFIX = OBJ_PREFIX + "pnl_";
const string EA_VERSION_STR = "4.31";

datetime g_dbgLogBarTime = 0;  // chống spam Experts: 1 dòng / (nến, BUY|SELL)
int      g_dbgLogSide    = 0;  // 1=BUY, -1=SELL

const string STAT_PREFIX = "RsiMomEA_ST_";
const string STAT_L1     = STAT_PREFIX + "line1";
const string STAT_L2     = STAT_PREFIX + "line2";
const string STAT_L3     = STAT_PREFIX + "line3";

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
datetime g_pendingPlacedBarTime = 0;

ulong    g_pmTicket = 0;
double   g_pmInitialRisk = 0.0;
bool     g_pmAt1RDone = false;

CTrade g_trade;

long ActChart() { return ChartID(); }

bool IsStrategyTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

bool IsTesterVisualMode()
{
   return IsStrategyTester() && (bool)MQLInfoInteger(MQL_VISUAL_MODE);
}

bool DebugMarksEffective()
{
   if(!InpDebugMarkSignals)
      return false;
   // Tester không visual: không vẽ object (tránh hàng nghìn object làm chậm)
   if(IsStrategyTester() && !IsTesterVisualMode())
      return false;
   return true;
}

bool ChartRedrawEffective()
{
   return !IsStrategyTester() || IsTesterVisualMode();
}

void   SetTradeFillingFromSymbol();
double Sl_GetBufferDistance(const int atrShift = 1);
bool   NearestSwingSlTp(const bool isBuy, const double entry, const int dig, double &sl, double &tp);
bool   StopsValid(const bool isBuy, const double price, const double sl, const double tp);
int    CountMyMagicPositions();
int    CountMyMagicPendingOrders();
bool   HasMyMagicPositionOrPending();
double NormalizeLots(double v);
double VolumeForRiskPercent(const bool isBuy, const double entryRef, const double slPrice);
void   TradeTryOnBarOpen(const int calcRet);
void   TradeExecuteOrder(const bool isBuy);
void   TradeExecuteLimitOrder(const bool isBuy);
void   TradeExecuteMarketOrder(const bool isBuy);
bool   EntryModeIsLimit();
bool   EntryModeIsMarket();
string EntryModeLabel();
bool   Signal_BodyMidPrice(const int shift, double &midOut);
bool   LimitPriceValid(const bool isBuy, const double limitPx);
void   Pending_ManageExpiry();
void   Pending_EnvCancelIfBad();
bool   Pending_CancelMine();
void   Position_ResetPmState();
ulong  Position_FindMyTicket();
void   Position_ManageAt1R();
bool   AtrExp_GetAt(const int shift, double &atr);
bool   AtrExp_IsExpandingAt(const int shift);
bool   AtrExp_AllowsAt(const int shift);
bool   AtrExp_AllowsNow();
bool   Adx_AllowsBuyAt(const int shift, string &why);
bool   Adx_AllowsSellAt(const int shift, string &why);
void   Adx_GetAtBar(const int shift, double &adx, double &plusDi, double &minusDi);
bool   SwingStruct_AllowsBuyAt(const int shift, string &why, double &bodyOld, double &bodyNew);
bool   SwingStruct_AllowsSellAt(const int shift, string &why, double &bodyOld, double &bodyNew);
int    Env_CurrentSpreadPts();
bool   Env_SpreadAllows();
bool   Env_AllowsSessionAt(const datetime t, string &why);
bool   Env_AllowsTradeNow(string &why);
bool   Env_AllowsTradeAtBar(const int sigShift, string &why);
bool   Trend_IsUpAt(const int shift, const int trendN, const double &closeArr[], const double &ema200Arr[]);
bool   Trend_IsDownAt(const int shift, const int trendN, const double &closeArr[], const double &ema200Arr[]);
bool   Signal_Ema9CoreBuyOkAt(const int shift);
bool   Signal_Ema9CoreSellOkAt(const int shift);
string Signal_ReasonBuy(const bool trendUp, const bool ema9CoreOk, const bool phaseOk, const string phaseFail,
                        const bool atrExpOk, const bool envOk, const bool valid);
string Signal_ReasonSell(const bool trendDown, const bool ema9CoreOk, const bool phaseOk, const string phaseFail,
                         const bool atrExpOk, const bool envOk, const bool valid);
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
  h_ATR = iATR(_Symbol, _Period, MathMax(1, InpSlAtrPeriod));
  if (h_ATR == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle ATR (SL)");
    return false;
  }
  h_ATR_Regime = iATR(_Symbol, _Period, MathMax(1, InpAtrExpPeriod));
  if (h_ATR_Regime == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle ATR (regime)");
    return false;
  }
  h_ADX = iADX(_Symbol, _Period, MathMax(2, InpAdxPeriod));
  if (h_ADX == INVALID_HANDLE)
  {
    Print("[RsiMomEA] Không tạo được handle ADX");
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
  if (h_ATR        != INVALID_HANDLE) IndicatorRelease(h_ATR);
  if (h_ATR_Regime != INVALID_HANDLE) IndicatorRelease(h_ATR_Regime);
  if (h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
  h_RSI = h_EMA9 = h_WMA45 = h_EMA200 = h_ATR = h_ATR_Regime = h_ADX = INVALID_HANDLE;
}

//+------------------------------------------------------------------+
string Panel_LineName(const int idx)
{
  return PNL_PREFIX + IntegerToString(idx);
}

int Panel_LineStepPx()
{
  return MathMax(11, InpPanelFontSize + MathMax(6, InpPanelLinePad));
}

void Panel_SetLine(const int idx, const string text, const color clr)
{
  const long ch = ActChart();
  const string name = Panel_LineName(idx);
  if(ObjectFind(ch, name) < 0)
    return;
  ObjectSetString(ch, name, OBJPROP_TEXT, text);
  ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
}

void Panel_CreateLine(const int idx)
{
  const long ch = ActChart();
  const string name = Panel_LineName(idx);
  if(ObjectFind(ch, name) >= 0)
    return;

  const int step = Panel_LineStepPx();
  const int y    = InpPanelTopMargin + idx * step;

  ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(ch, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
  ObjectSetInteger(ch, name, OBJPROP_XDISTANCE,  InpPanelLeftMargin);
  ObjectSetInteger(ch, name, OBJPROP_YDISTANCE,  y);
  ObjectSetInteger(ch, name, OBJPROP_FONTSIZE,   MathMax(7, InpPanelFontSize));
  ObjectSetString (ch, name, OBJPROP_FONT,       "Consolas");
  ObjectSetInteger(ch, name, OBJPROP_BACK,       false);
  ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(ch, name, OBJPROP_HIDDEN,     true);
  ObjectSetInteger(ch, name, OBJPROP_COLOR,      clrSilver);
  ObjectSetString (ch, name, OBJPROP_TEXT,       "");
}

string Panel_FmtOnOff(const bool on)
{
  return on ? "ON " : "OFF";
}

color Panel_ClrOnOff(const bool on)
{
  return on ? clrLime : clrDimGray;
}

void Panel_GetSessionLive(string &status, color &clr)
{
  status = "";
  clr    = clrSilver;

  if(!InpSessionFilterEnabled)
  {
    status = "Phiên: filter OFF (mọi giờ)";
    clr    = clrSilver;
    return;
  }

  const int mins = Env_MinutesFromTime(TimeCurrent());
  if(Env_IsTransitionAt(mins))
  {
    status = "Phiên: GIAO PHIÊN (chặn)";
    clr    = clrOrange;
    return;
  }

  const int avoid = MathMax(0, InpSessionAvoidLastMin);
  const bool inLondon = Env_IsWithinWindow(mins, InpLondonStartHour, InpLondonEndHour, avoid);
  const bool inNY     = Env_IsWithinWindow(mins, InpNYStartHour, InpNYEndHour, avoid);

  if(inLondon && inNY)
  {
    status = "Phiên: London + NY";
    clr    = clrLime;
  }
  else if(inLondon)
  {
    status = "Phiên: London";
    clr    = clrLime;
  }
  else if(inNY)
  {
    status = "Phiên: New York";
    clr    = clrLime;
  }
  else
  {
    status = "Phiên: NGOÀI PHIÊN";
    clr    = clrTomato;
  }
}

//+------------------------------------------------------------------+
void Panel_CreateAll()
{
  if(!InpShowPanel)
    return;

  for(int i = 0; i < PANEL_LINE_COUNT; i++)
    Panel_CreateLine(i);
}

//+------------------------------------------------------------------+
void Panel_UpdateStatus()
{
  if(!InpShowPanel)
    return;

  int ln = 0;
  const string tfTxt = StringSubstr(EnumToString((ENUM_TIMEFRAMES)_Period), 7);

  Panel_SetLine(ln++, StringFormat("RSI MOMENTUM EA  v%s  |  %s %s",
                                   EA_VERSION_STR, _Symbol, tfTxt), clrWhite);
  Panel_SetLine(ln++, "────────────────────────────────────", clrDarkGray);

  Panel_SetLine(ln++, StringFormat("Trade: %s  Magic %I64u  SignalBar[%d]",
                                   Panel_FmtOnOff(InpTradeEnabled), InpMagic,
                                   MathMax(1, InpSignalBarShift)),
                Panel_ClrOnOff(InpTradeEnabled));

  Panel_SetLine(ln++, StringFormat("Entry: %s", EntryModeLabel()),
                InpEntryMode == RSI_MOM_ENTRY_MARKET ? clrGold : clrSilver);
  Panel_SetLine(ln++, StringFormat("Risk %.2f%%  |  R:R 1:%.2f%s",
                                   InpRiskPercent, InpRewardRiskRatio,
                                   EntryModeIsLimit()
                                     ? StringFormat("  |  Limit exp %d bar", InpLimitExpireBars) : ""),
                clrSilver);

  Panel_SetLine(ln++, StringFormat("Manage @1R: %s  (partial %.0f%%)",
                                   Panel_FmtOnOff(InpManageAt1R),
                                   InpPartialCloseRatio * 100.0),
                Panel_ClrOnOff(InpManageAt1R));

  Panel_SetLine(ln++, "────────────────────────────────────", clrDarkGray);

  Panel_SetLine(ln++, StringFormat("5 phase: %s  P1>=%.1f  LB%d  |  EMA200: %s  (%d bar)",
                                   Panel_FmtOnOff(InpPhaseFilterEnabled),
                                   InpPhaseMinExpandSpread,
                                   InpPhaseExpandLookback,
                                   Panel_FmtOnOff(InpTrendFilterEnabled),
                                   MathMax(1, InpTrendConfirmBars)),
                InpPhaseFilterEnabled ? clrWhite : clrDimGray);

  Panel_SetLine(ln++, StringFormat("ATR expand: %s  |  ADX: %s  >=%.0f  DI: %s",
                                   Panel_FmtOnOff(InpAtrExpFilterEnabled),
                                   Panel_FmtOnOff(InpAdxFilterEnabled),
                                   InpAdxMinLevel,
                                   Panel_FmtOnOff(InpAdxRequireDiDirection)),
                clrSilver);

  Panel_SetLine(ln++, StringFormat("Swing2 body: %s  range=%d  LB=%d",
                                   Panel_FmtOnOff(InpSwingStructFilterEnabled),
                                   InpSwingStructRange, InpSwingStructLookback),
                clrSilver);

  Panel_SetLine(ln++, StringFormat("RSI OB/OS: %s  (%.0f / %.0f)",
                                   Panel_FmtOnOff(InpRsiObOsFilterEnabled),
                                   InpRSIOverbought, InpRSIOversold),
                clrSilver);

  const bool spreadEffective = InpSpreadFilterEnabled &&
                               !(MQLInfoInteger(MQL_TESTER) && InpSpreadSkipInTester);
  Panel_SetLine(ln++, StringFormat("Session: %s  L%d-%d NY%d-%d  |  Spread: %s%s",
                                   Panel_FmtOnOff(InpSessionFilterEnabled),
                                   InpLondonStartHour, InpLondonEndHour,
                                   InpNYStartHour, InpNYEndHour,
                                   Panel_FmtOnOff(spreadEffective),
                                   (InpSpreadFilterEnabled && InpSpreadSkipInTester && MQLInfoInteger(MQL_TESTER))
                                     ? " (skip tester)" : ""),
                Panel_ClrOnOff(InpSessionFilterEnabled));

  Panel_SetLine(ln++, StringFormat("Giao phiên: %s  |  Debug marks: %s  |  Journal: %s",
                                   Panel_FmtOnOff(InpTransitionBlockEnabled && InpSessionFilterEnabled),
                                   Panel_FmtOnOff(InpDebugMarkSignals),
                                   Panel_FmtOnOff(InpExportTradeJournal)),
                clrSilver);

  Panel_SetLine(ln++, "────────────────────────────────────", clrDarkGray);

  string sessTxt = "";
  color  sessClr = clrSilver;
  Panel_GetSessionLive(sessTxt, sessClr);
  Panel_SetLine(ln++, sessTxt, sessClr);

  string envWhy = "";
  const bool tradeEnvOk = Env_AllowsTradeNow(envWhy);
  Panel_SetLine(ln++, StringFormat("Trade env: %s%s",
                                   tradeEnvOk ? "OK" : "BLOCK",
                                   (StringLen(envWhy) > 0 ? " — " + envWhy : "")),
                tradeEnvOk ? clrLime : clrOrangeRed);

  const int spr = Env_CurrentSpreadPts();
  const bool sprOk = Env_SpreadAllows();
  Panel_SetLine(ln++, StringFormat("Spread: %d pts  (max %d)  %s",
                                   spr, InpMaxSpreadPoints, sprOk ? "OK" : "HIGH"),
                sprOk ? clrSilver : clrOrange);

  Panel_SetLine(ln++, StringFormat("Giờ lọc: %s  |  %s",
                                   InpEnvUseUtc ? "UTC" : "SERVER",
                                   TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES)),
                clrSilver);

  while(ln < PANEL_IDX_MARKET)
    Panel_SetLine(ln++, "", clrSilver);
}

//+------------------------------------------------------------------+
void Panel_Update(const double &closeArr[], const double &ema200Arr[],
                  const int trendN, const int rates_total)
{
  Panel_UpdateStatus();

  if(!InpShowPanel)
    return;
  if(rates_total <= trendN + 1)
    return;
  if(ema200Arr[1] <= 0.0)
    return;
  if(ArraySize(buf_RSI) < 2)
    return;

  int ln = PANEL_IDX_MARKET;

  bool panelTrendUp   = true;
  bool panelTrendDown = true;
  for(int k = 0; k < trendN; k++)
  {
    const int idx = 1 + k;
    if(ema200Arr[idx] <= 0.0)
    {
      panelTrendUp   = false;
      panelTrendDown = false;
      break;
    }
    if(closeArr[idx] <= ema200Arr[idx])
      panelTrendUp = false;
    if(closeArr[idx] >= ema200Arr[idx])
      panelTrendDown = false;
  }

  string trendTxt = "RANGE";
  color  trendClr = clrSilver;
  if(panelTrendUp)
  {
    trendTxt = StringFormat("UPTREND (close>%d>EMA200)", trendN);
    trendClr = InpArrowUpColor;
  }
  else if(panelTrendDown)
  {
    trendTxt = StringFormat("DOWNTREND (close<%d<EMA200)", trendN);
    trendClr = InpArrowDownColor;
  }

  string sigTxt = "none";
  color  sigClr = clrSilver;
  if(buf_Signal[1] > 0.5)
  {
    sigTxt = "BUY";
    sigClr = InpArrowUpColor;
  }
  else if(buf_Signal[1] < -0.5)
  {
    sigTxt = "SELL";
    sigClr = InpArrowDownColor;
  }

  Panel_SetLine(ln++, StringFormat("Bar[1] Signal: %s  |  %s", sigTxt, trendTxt), sigClr);

  Panel_SetLine(ln++, StringFormat("RSI   %6.2f", buf_RSI[1]), clrMediumOrchid);
  Panel_SetLine(ln++, StringFormat("EMA9  %6.2f", buf_EMA9[1]), InpPanelColorEMA9);
  Panel_SetLine(ln++, StringFormat("WMA45 %6.2f", buf_WMA45[1]), InpPanelColorWMA45);
  if(InpAdxFilterEnabled)
  {
    double adx = 0.0, pdi = 0.0, mdi = 0.0;
    Adx_GetAtBar(1, adx, pdi, mdi);
    string adxWhy = "";
    const bool adxOk = panelTrendUp ? Adx_AllowsBuyAt(1, adxWhy)
                    : (panelTrendDown ? Adx_AllowsSellAt(1, adxWhy) : true);
    Panel_SetLine(ln++, StringFormat("ADX   %5.1f  +DI=%.1f -DI=%.1f  %s",
                                     adx, pdi, mdi, adxOk ? "OK" : "FAIL"),
                  adxOk ? clrSilver : clrOrangeRed);
  }
  Panel_SetLine(ln++, StringFormat("EMA200 close[1] %s  %.5f",
                                   panelTrendUp ? ">" : (panelTrendDown ? "<" : "~"),
                                   ema200Arr[1]), trendClr);

  while(ln < PANEL_LINE_COUNT)
    Panel_SetLine(ln++, "", clrSilver);
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
//| Regime: ATR mở rộng tại bar tín hiệu (ATR tăng vs N bar + liên tiếp) |
//+------------------------------------------------------------------+
bool AtrExp_GetAt(const int shift, double &atr)
{
  atr = 0.0;
  if(h_ATR_Regime == INVALID_HANDLE || shift < 0)
    return false;

  double buf[];
  ArraySetAsSeries(buf, true);
  if(CopyBuffer(h_ATR_Regime, 0, shift, 1, buf) < 1)
    return false;

  atr = buf[0];
  return (atr > 0.0);
}

bool AtrExp_IsExpandingAt(const int shift)
{
  if(!InpAtrExpFilterEnabled)
    return true;

  const int cmpBars = MathMax(1, InpAtrExpCompareBars);
  const int riseBars = MathMax(1, InpAtrExpRiseBars);
  const int needShift = shift + cmpBars + riseBars;
  if(needShift >= Bars(_Symbol, _Period))
    return false;

  double atrNow = 0.0, atrRef = 0.0;
  if(!AtrExp_GetAt(shift, atrNow) || !AtrExp_GetAt(shift + cmpBars, atrRef))
    return false;
  if(atrRef <= 0.0)
    return false;

  const double minRatio = MathMax(1.0, InpAtrExpMinRatio);
  if(atrNow / atrRef < minRatio - 1e-8)
    return false;

  for(int k = 0; k < riseBars; k++)
  {
    double atrA = 0.0, atrB = 0.0;
    if(!AtrExp_GetAt(shift + k, atrA) || !AtrExp_GetAt(shift + k + 1, atrB))
      return false;
    if(atrA <= atrB + 1e-8)
      return false;
  }
  return true;
}

bool AtrExp_AllowsAt(const int shift)
{
  return AtrExp_IsExpandingAt(shift);
}

bool AtrExp_AllowsNow()
{
  return AtrExp_AllowsAt(1);
}

//+------------------------------------------------------------------+
AdxFilterConfig GetAdxFilterConfig()
{
  AdxFilterConfig c;
  c.enabled       = InpAdxFilterEnabled;
  c.period        = MathMax(2, InpAdxPeriod);
  c.minLevel      = MathMax(0.0, InpAdxMinLevel);
  c.maxLevel      = MathMax(0.0, InpAdxMaxLevel);
  c.requireDiDir  = InpAdxRequireDiDirection;
  c.minDiSpread   = MathMax(0.0, InpAdxMinDiSpread);
  c.riseBars      = MathMax(0, InpAdxRiseBars);
  return c;
}

void Adx_GetAtBar(const int shift, double &adx, double &plusDi, double &minusDi)
{
  adx = plusDi = minusDi = 0.0;
  if(!InpAdxFilterEnabled || h_ADX == INVALID_HANDLE)
    return;
  AdxFilter_GetAt(h_ADX, shift, adx, plusDi, minusDi);
}

bool Adx_AllowsBuyAt(const int shift, string &why)
{
  why = "";
  if(!InpAdxFilterEnabled)
    return true;
  return AdxFilter_PassesBuy(h_ADX, shift, GetAdxFilterConfig(), why);
}

bool Adx_AllowsSellAt(const int shift, string &why)
{
  why = "";
  if(!InpAdxFilterEnabled)
    return true;
  return AdxFilter_PassesSell(h_ADX, shift, GetAdxFilterConfig(), why);
}

SwingStructConfig SwingStruct_BuildConfig()
{
  SwingStructConfig c;
  c.enabled    = InpSwingStructFilterEnabled;
  c.pivotRange = MathMax(1, InpSwingStructRange);
  c.lookback   = MathMax(20, InpSwingStructLookback);
  c.tolPts     = MathMax(0.0, InpSwingStructTolPts);
  return c;
}

bool SwingStruct_AllowsBuyAt(const int shift, string &why, double &bodyOld, double &bodyNew)
{
  why = "";
  bodyOld = bodyNew = 0.0;
  if(!InpSwingStructFilterEnabled)
    return true;

  SwingStructPoint older, newer;
  const SwingStructConfig cfg = SwingStruct_BuildConfig();
  const bool ok = SwingStruct_PassesBuyAt(_Symbol, _Period, shift, cfg, why, older, newer);
  bodyOld = older.bodyPrice;
  bodyNew = newer.bodyPrice;
  return ok;
}

bool SwingStruct_AllowsSellAt(const int shift, string &why, double &bodyOld, double &bodyNew)
{
  why = "";
  bodyOld = bodyNew = 0.0;
  if(!InpSwingStructFilterEnabled)
    return true;

  SwingStructPoint older, newer;
  const SwingStructConfig cfg = SwingStruct_BuildConfig();
  const bool ok = SwingStruct_PassesSellAt(_Symbol, _Period, shift, cfg, why, older, newer);
  bodyOld = older.bodyPrice;
  bodyNew = newer.bodyPrice;
  return ok;
}

//+------------------------------------------------------------------+
//| Phiên London/NY + chặn giao phiên + spread tối đa (trade env)    |
//+------------------------------------------------------------------+
int Env_GmtOffsetSec()
{
  return (int)(TimeGMT() - TimeCurrent());
}

datetime Env_ToFilterTime(const datetime t)
{
  if(!InpEnvUseUtc)
    return t;
  return t + Env_GmtOffsetSec();
}

int Env_ClampHour(const int h)
{
  return MathMax(0, MathMin(23, h));
}

int Env_MinutesFromTime(const datetime t)
{
  MqlDateTime tm;
  TimeToStruct(Env_ToFilterTime(t), tm);
  return tm.hour * 60 + tm.min;
}

bool Env_IsWithinWindow(const int currentMinutes,
                        const int startHour, const int endHour,
                        const int avoidLastMin)
{
  const int startMin = Env_ClampHour(startHour) * 60;
  int endMin = Env_ClampHour(endHour) * 60;
  if(endMin <= startMin)
    endMin += 24 * 60;

  int cur = currentMinutes;
  if(endMin > 24 * 60 && cur < startMin)
    cur += 24 * 60;

  if(cur < startMin || cur >= endMin)
    return false;

  const int avoid = MathMax(0, avoidLastMin);
  if(avoid > 0 && cur >= endMin - avoid)
    return false;

  return true;
}

bool Env_IsTransitionAt(const int mins)
{
  if(!InpTransitionBlockEnabled)
    return false;

  return (Env_IsWithinWindow(mins, InpTransition1StartHour, InpTransition1EndHour, 0) ||
          Env_IsWithinWindow(mins, InpTransition2StartHour, InpTransition2EndHour, 0));
}

bool Env_InActiveSessionAt(const int mins)
{
  if(!InpSessionFilterEnabled)
    return true;

  const int avoid = MathMax(0, InpSessionAvoidLastMin);
  return (Env_IsWithinWindow(mins, InpLondonStartHour, InpLondonEndHour, avoid) ||
          Env_IsWithinWindow(mins, InpNYStartHour, InpNYEndHour, avoid));
}

int Env_CurrentSpreadPts()
{
  return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

bool Env_SpreadAllows()
{
  if(!InpSpreadFilterEnabled)
    return true;

  if(MQLInfoInteger(MQL_TESTER) && InpSpreadSkipInTester)
    return true;

  const int maxSp = MathMax(1, InpMaxSpreadPoints);
  return (Env_CurrentSpreadPts() <= maxSp);
}

bool Env_AllowsSessionAt(const datetime t, string &why)
{
  why = "";
  if(!InpSessionFilterEnabled)
    return true;

  const int mins = Env_MinutesFromTime(t);

  if(Env_IsTransitionAt(mins))
  {
    why = "giao phiên ";
    return false;
  }

  if(!Env_InActiveSessionAt(mins))
  {
    why = "ngoài phiên ";
    return false;
  }

  return true;
}

bool Env_AllowsTradeNow(string &why)
{
  return Env_AllowsTradeAtBar(MathMax(1, InpSignalBarShift), why);
}

bool Env_AllowsTradeAtBar(const int sigShift, string &why)
{
  why = "";

  const datetime barT = iTime(_Symbol, _Period, sigShift);
  if(barT == 0)
  {
    why = "no bar time ";
    return false;
  }

  if(!Env_AllowsSessionAt(barT, why))
    return false;

  if(!Env_SpreadAllows())
  {
    why = StringFormat("spread %d>%d ", Env_CurrentSpreadPts(), InpMaxSpreadPoints);
    return false;
  }

  return true;
}

bool Trend_IsUpAt(const int shift, const int trendN, const double &closeArr[], const double &ema200Arr[])
{
  const int n = MathMax(1, trendN);
  for(int k = 0; k < n; k++)
  {
    const int idx = shift + k;
    if(ema200Arr[idx] <= 0.0)
      return false;
    if(closeArr[idx] <= ema200Arr[idx])
      return false;
  }
  return true;
}

bool Trend_IsDownAt(const int shift, const int trendN, const double &closeArr[], const double &ema200Arr[])
{
  const int n = MathMax(1, trendN);
  for(int k = 0; k < n; k++)
  {
    const int idx = shift + k;
    if(ema200Arr[idx] <= 0.0)
      return false;
    if(closeArr[idx] >= ema200Arr[idx])
      return false;
  }
  return true;
}

//+------------------------------------------------------------------+
bool Signal_Ema9CoreBuyOkAt(const int shift)
{
  return (buf_EMA9[shift] < buf_WMA45[shift]);
}

bool Signal_Ema9CoreSellOkAt(const int shift)
{
  return (buf_EMA9[shift] > buf_WMA45[shift]);
}

PhaseEntryConfig GetPhaseEntryConfig()
{
  PhaseEntryConfig c;
  c.enabled           = InpPhaseFilterEnabled;
  c.expandLookback    = MathMax(5, InpPhaseExpandLookback);
  c.minExpandSpread   = MathMax(1.0, InpPhaseMinExpandSpread);
  c.coilLookback      = MathMax(3, InpPhaseCoilLookback);
  c.minRsiEma9Crosses = MathMax(1, InpPhaseMinRsiEma9Cross);
  c.coilBand          = MathMax(0.5, InpPhaseCoilBand);
  c.ema9SlopeBars     = MathMax(1, InpPhaseEma9SlopeBars);
  c.ema9SlopeTol      = MathMax(0.0, InpPhaseEma9SlopeTol);
  c.wmaFlatBars       = MathMax(2, InpPhaseWmaFlatBars);
  c.wmaWasSlopeMin    = MathMax(0.0, InpPhaseWmaWasSlopeMin);
  c.wmaFlatMaxSlope   = MathMax(0.05, InpPhaseWmaFlatMaxSlope);
  c.wmaRelaxPrior     = InpPhaseWmaRelaxPrior;
  c.maxEma9WmaGap     = MathMax(0.5, InpPhaseMaxEma9WmaGap);
  return c;
}

//+------------------------------------------------------------------+
bool Signal_RsiOkBuyAt(const int shift)
{
  if(!InpRsiObOsFilterEnabled)
    return true;
  return (buf_RSI[shift] < InpRSIOverbought);
}

bool Signal_RsiOkSellAt(const int shift)
{
  if(!InpRsiObOsFilterEnabled)
    return true;
  return (buf_RSI[shift] > InpRSIOversold);
}

//+------------------------------------------------------------------+
string Signal_ReasonBuy(const bool trendUp, const bool ema9CoreOk, const bool phaseOk, const string phaseFail,
                        const bool atrExpOk, const bool adxOk, const bool swingOk,
                        const bool rsiObOsOk, const bool envOk, const bool valid)
{
  if(valid)
  {
    string s = InpPhaseFilterEnabled
             ? "RSI↑WMA45 | 5phase OK | EMA200 UP"
             : "RSI↑WMA45 EMA9<WMA45 | EMA200 UP";
    s += StringFormat(" (%d bar) | %s", MathMax(1, InpTrendConfirmBars), EntryModeLabel());
    if(InpAtrExpFilterEnabled)
      s += StringFormat(" | ATR↑ x%.0f%% %d bar", (InpAtrExpMinRatio - 1.0) * 100.0, InpAtrExpRiseBars);
    if(InpAdxFilterEnabled)
      s += StringFormat(" | ADX>=%.0f", InpAdxMinLevel);
    if(InpSwingStructFilterEnabled)
      s += " | 2đáy↑";
    return s;
  }

  string f = "";
  if(!InpPhaseFilterEnabled && !ema9CoreOk)
    f += "EMA9>=WMA45 ";
  if(InpPhaseFilterEnabled && !phaseOk)
    f += phaseFail;
  if(InpTrendFilterEnabled && !trendUp)
    f += "ngược EMA200 ";
  if(InpAtrExpFilterEnabled && !atrExpOk)
    f += "ATR co ";
  if(InpAdxFilterEnabled && !adxOk)
    f += "ADX yếu ";
  if(InpSwingStructFilterEnabled && !swingOk)
    f += "2 đáy ";
  if(InpRsiObOsFilterEnabled && !rsiObOsOk)
    f += "RSI quá mua ";
  if(!envOk)
    f += "phiên/spread ";
  if(StringLen(f) == 0)
    f = "no cross ";
  return f;
}

string Signal_ReasonSell(const bool trendDown, const bool ema9CoreOk, const bool phaseOk, const string phaseFail,
                         const bool atrExpOk, const bool adxOk, const bool swingOk,
                         const bool rsiObOsOk, const bool envOk, const bool valid)
{
  if(valid)
  {
    string s = InpPhaseFilterEnabled
             ? "RSI↓WMA45 | 5phase OK | EMA200 DOWN"
             : "RSI↓WMA45 EMA9>WMA45 | EMA200 DOWN";
    s += StringFormat(" (%d bar) | %s", MathMax(1, InpTrendConfirmBars), EntryModeLabel());
    if(InpAtrExpFilterEnabled)
      s += StringFormat(" | ATR↑ x%.0f%% %d bar", (InpAtrExpMinRatio - 1.0) * 100.0, InpAtrExpRiseBars);
    if(InpAdxFilterEnabled)
      s += StringFormat(" | ADX>=%.0f", InpAdxMinLevel);
    if(InpSwingStructFilterEnabled)
      s += " | 2đỉnh↓";
    return s;
  }

  string f = "";
  if(!InpPhaseFilterEnabled && !ema9CoreOk)
    f += "EMA9<=WMA45 ";
  if(InpPhaseFilterEnabled && !phaseOk)
    f += phaseFail;
  if(InpTrendFilterEnabled && !trendDown)
    f += "ngược EMA200 ";
  if(InpAtrExpFilterEnabled && !atrExpOk)
    f += "ATR co ";
  if(InpAdxFilterEnabled && !adxOk)
    f += "ADX yếu ";
  if(InpSwingStructFilterEnabled && !swingOk)
    f += "2 đỉnh ";
  if(InpRsiObOsFilterEnabled && !rsiObOsOk)
    f += "RSI quá bán ";
  if(!envOk)
    f += "phiên/spread ";
  if(StringLen(f) == 0)
    f = "no cross ";
  return f;
}

//+------------------------------------------------------------------+
void Signal_DebugApplyTradeLayer(SignalEvalResult &ev, const int shift)
{
  const int sigShift = MathMax(1, InpSignalBarShift);
  if(shift != sigShift || !ev.signalOk)
    return;

  if(!InpTradeEnabled)
  {
    ev.tradeOk = false;
    ev.failTag = "Trade-OFF";
    SignalEval_Append(ev.detail, "Đặt lệnh:OFF (InpTradeEnabled=false)");
    ev.summary = "SIG → Trade tắt";
    return;
  }

  string tradeWhy = "";
  ev.tradeOk = Env_AllowsTradeAtBar(shift, tradeWhy);
  if(ev.tradeOk)
  {
    ev.summary = "HỢP LỆ → vào lệnh";
    SignalEval_Append(ev.detail, "Đặt lệnh:OK");
  }
  else
  {
    ev.failTag = "Đặt lệnh";
    ev.summary = "SIG → " + tradeWhy;
    SignalEval_Append(ev.detail, StringLen(tradeWhy) > 0
                      ? "Đặt lệnh:FAIL " + tradeWhy
                      : "Đặt lệnh:FAIL");
  }
}

//+------------------------------------------------------------------+
bool Signal_DebugShouldLogExperts(const datetime barTime, const bool isBuy)
{
   const int side = isBuy ? 1 : -1;
   if(barTime == g_dbgLogBarTime && side == g_dbgLogSide)
      return false;
   g_dbgLogBarTime = barTime;
   g_dbgLogSide    = side;
   return true;
}

//+------------------------------------------------------------------+
void Signal_DebugMarkCross(const long ch, const int shift, const datetime barTime,
                           const double barHigh, const double barLow, const double markPrice,
                           const bool isBuy, const int rates_total, const int trendN,
                           const double &closeArr[], const double &ema200Arr[],
                           const PhaseEntryConfig &phaseCfg,
                           const bool atrExpOkBar, const bool sessionAtBar,
                           const string sessionFailWhy)
{
  if(DebugMarksEffective() && Signal_DebugMarkExists(ch, DBG_PREFIX, barTime, isBuy))
      return;

  double adxVal = 0.0, plusDi = 0.0, minusDi = 0.0;
  string adxWhy = "";
  Adx_GetAtBar(shift, adxVal, plusDi, minusDi);
  const bool adxOkBar = isBuy ? Adx_AllowsBuyAt(shift, adxWhy) : Adx_AllowsSellAt(shift, adxWhy);

  string swingWhy = "";
  double swingOld = 0.0, swingNew = 0.0;
  const bool swingOkBar = isBuy
                        ? SwingStruct_AllowsBuyAt(shift, swingWhy, swingOld, swingNew)
                        : SwingStruct_AllowsSellAt(shift, swingWhy, swingOld, swingNew);

  SignalEvalResult ev;
  if(isBuy)
    ev = Signal_EvaluateBuyAt(shift, rates_total, trendN,
                              buf_RSI, buf_EMA9, buf_WMA45, closeArr, ema200Arr,
                              phaseCfg, InpPhaseFilterEnabled, InpTrendFilterEnabled,
                              InpAtrExpFilterEnabled, InpAdxFilterEnabled, adxOkBar,
                              adxVal, plusDi, minusDi, adxWhy,
                              InpSwingStructFilterEnabled, swingOkBar,
                              swingOld, swingNew, swingWhy,
                              InpRsiObOsFilterEnabled,
                              InpRSIOverbought, InpRSIOversold,
                              InpSessionFilterEnabled,
                              atrExpOkBar, sessionAtBar, sessionFailWhy);
  else
    ev = Signal_EvaluateSellAt(shift, rates_total, trendN,
                               buf_RSI, buf_EMA9, buf_WMA45, closeArr, ema200Arr,
                               phaseCfg, InpPhaseFilterEnabled, InpTrendFilterEnabled,
                               InpAtrExpFilterEnabled, InpAdxFilterEnabled, adxOkBar,
                               adxVal, plusDi, minusDi, adxWhy,
                               InpSwingStructFilterEnabled, swingOkBar,
                               swingOld, swingNew, swingWhy,
                               InpRsiObOsFilterEnabled,
                               InpRSIOverbought, InpRSIOversold,
                               InpSessionFilterEnabled,
                               atrExpOkBar, sessionAtBar, sessionFailWhy);

  Signal_DebugApplyTradeLayer(ev, shift);
  Signal_DebugDrawMark(ch, DBG_PREFIX, barTime, barHigh, barLow, markPrice, isBuy, ev);

  const int sigShift = MathMax(1, InpSignalBarShift);
  if(InpDebugLogExperts && shift == sigShift
     && Signal_DebugShouldLogExperts(barTime, isBuy))
  {
    PrintFormat("[RsiMomEA DBG] %s %s %s fail=[%s] | %s",
                TimeToString(barTime, TIME_DATE | TIME_MINUTES),
                isBuy ? "BUY" : "SELL",
                ev.summary,
                ev.failTag,
                ev.detail);
    if(ev.signalOk && MathAbs(buf_Signal[shift]) < 0.5)
      Print("[RsiMomEA DBG]   → buf_Signal=0 (mũi tên CR không vẽ) nhưng debug vẫn pass signal — kiểm tra ObjectFind trùng tên");
  }
}

//+------------------------------------------------------------------+
void SignalScan_Run(const int barsToScan, const int rates_total, const int need, const int trendN,
                    const datetime &timeArr[], const double &highArr[], const double &lowArr[],
                    const double &closeArr[], const double &ema200Arr[])
{
  const long   ch    = ActChart();
  const double arrowOffset = InpArrowOffsetPts * _Point;
  const int    dbgMax = MathMax(50, InpDebugMarkMaxBars);

  const bool dbgMarks = DebugMarksEffective();
  if(dbgMarks)
  {
    Signal_DebugConfigureChart(ch);
    Signal_DebugPruneOlderThan(ch, DBG_PREFIX, MathMax(50, InpDebugMarkMaxBars) + 5);
  }

  buf_Signal[0] = 0.0;
  buf_Trend[0]  = 0.0;
  buf_EMA200[0] = (need > 0) ? ema200Arr[0] : 0.0;

  for (int i = barsToScan; i >= 1; i--)
  {
    buf_Signal[i] = 0.0;
    buf_Trend[i]  = 0.0;
    buf_EMA200[i] = (i < need) ? ema200Arr[i] : 0.0;

    if (i + 1 >= rates_total) continue;
    if (InpTrendFilterEnabled && i + trendN >= need) continue;
    const int phaseLb = InpPhaseFilterEnabled
                      ? MathMax(InpPhaseExpandLookback, InpPhaseCoilLookback) + InpPhaseWmaFlatBars * 2 + 3
                      : 0;
    if (i + phaseLb >= rates_total) continue;
    if (ema200Arr[i] <= 0.0) continue;

    const bool trendUp   = !InpTrendFilterEnabled || Trend_IsUpAt(i, trendN, closeArr, ema200Arr);
    const bool trendDown = !InpTrendFilterEnabled || Trend_IsDownAt(i, trendN, closeArr, ema200Arr);
    buf_Trend[i] = trendUp ? 1.0 : (trendDown ? -1.0 : 0.0);

    // BUY: RSI↑WMA45 + EMA9<WMA45 | SELL: RSI↓WMA45 + EMA9>WMA45
    const bool crossUpWma45   = (buf_RSI[i+1] <= buf_WMA45[i+1]) && (buf_RSI[i] > buf_WMA45[i]);
    const bool crossDownWma45 = (buf_RSI[i+1] >= buf_WMA45[i+1]) && (buf_RSI[i] < buf_WMA45[i]);
    if (!crossUpWma45 && !crossDownWma45) continue;

    const bool ema9BuyOk  = Signal_Ema9CoreBuyOkAt(i);
    const bool ema9SellOk = Signal_Ema9CoreSellOkAt(i);
    const PhaseEntryConfig phaseCfg = GetPhaseEntryConfig();
    string phaseFailBuy = "";
    string phaseFailSell = "";
    const bool phaseBuyOk  = Phase_BuyPasses(i, rates_total, buf_RSI, buf_EMA9, buf_WMA45, phaseCfg, phaseFailBuy);
    const bool phaseSellOk = Phase_SellPasses(i, rates_total, buf_RSI, buf_EMA9, buf_WMA45, phaseCfg, phaseFailSell);
    const bool coreBuyOk   = InpPhaseFilterEnabled ? phaseBuyOk  : ema9BuyOk;
    const bool coreSellOk  = InpPhaseFilterEnabled ? phaseSellOk : ema9SellOk;
    const bool atrExpOkBar = AtrExp_AllowsAt(i);
    string adxWhyB = "", adxWhyS = "";
    const bool adxOkBuy  = Adx_AllowsBuyAt(i, adxWhyB);
    const bool adxOkSell = Adx_AllowsSellAt(i, adxWhyS);
    string swingWhyB = "", swingWhyS = "";
    double swOld = 0.0, swNew = 0.0;
    const bool swingOkBuy  = SwingStruct_AllowsBuyAt(i, swingWhyB, swOld, swNew);
    const bool swingOkSell = SwingStruct_AllowsSellAt(i, swingWhyS, swOld, swNew);
    const bool rsiOkBuy    = Signal_RsiOkBuyAt(i);
    const bool rsiOkSell   = Signal_RsiOkSellAt(i);
    string envWhy = "";
    const bool envOkBar = Env_AllowsSessionAt(timeArr[i], envWhy);

    if(crossUpWma45)
    {
      const bool validBuy = coreBuyOk && trendUp && atrExpOkBar && adxOkBuy
                            && swingOkBuy && rsiOkBuy && envOkBar;

      if(dbgMarks && i <= dbgMax)
      {
        string envDbg = envWhy;
        Signal_DebugMarkCross(ch, i, timeArr[i], highArr[i], lowArr[i],
                              lowArr[i] - arrowOffset, true,
                              rates_total, trendN, closeArr, ema200Arr, phaseCfg,
                              atrExpOkBar, envOkBar, envDbg);
      }

      if(validBuy)
      {
        const string reason = Signal_ReasonBuy(trendUp, ema9BuyOk, phaseBuyOk, phaseFailBuy,
                                               atrExpOkBar, adxOkBuy, swingOkBuy,
                                               rsiOkBuy, envOkBar, true);
        const double arrowPrice = lowArr[i] - arrowOffset;
        const string arrowName = OBJ_PREFIX + "CR_" + IntegerToString((int)timeArr[i]);
        if(ObjectFind(ch, arrowName) < 0)
        {
          buf_Signal[i] = 1.0;
          ObjectCreate(ch, arrowName, OBJ_ARROW, 0, timeArr[i], arrowPrice);
          ObjectSetInteger(ch, arrowName, OBJPROP_ARROWCODE,  233);
          ObjectSetInteger(ch, arrowName, OBJPROP_ANCHOR,     ANCHOR_TOP);
          ObjectSetInteger(ch, arrowName, OBJPROP_COLOR,      InpArrowUpColor);
          ObjectSetInteger(ch, arrowName, OBJPROP_WIDTH,      InpArrowSize);
          ObjectSetInteger(ch, arrowName, OBJPROP_SELECTABLE, false);
          ObjectSetInteger(ch, arrowName, OBJPROP_HIDDEN,     true);
          ObjectSetString (ch, arrowName, OBJPROP_TOOLTIP, "BUY | " + reason);
        }
      }
    }

    if(crossDownWma45)
    {
      const bool validSell = coreSellOk && trendDown && atrExpOkBar && adxOkSell
                             && swingOkSell && rsiOkSell && envOkBar;

      if(dbgMarks && i <= dbgMax)
      {
        string envDbg = envWhy;
        Signal_DebugMarkCross(ch, i, timeArr[i], highArr[i], lowArr[i],
                              highArr[i] + arrowOffset, false,
                              rates_total, trendN, closeArr, ema200Arr, phaseCfg,
                              atrExpOkBar, envOkBar, envDbg);
      }

      if(validSell)
      {
        const string reason = Signal_ReasonSell(trendDown, ema9SellOk, phaseSellOk, phaseFailSell,
                                                atrExpOkBar, adxOkSell, swingOkSell,
                                                rsiOkSell, envOkBar, true);
        const double arrowPrice = highArr[i] + arrowOffset;
        const string arrowName = OBJ_PREFIX + "CR_" + IntegerToString((int)timeArr[i]);
        if(ObjectFind(ch, arrowName) < 0)
        {
          buf_Signal[i] = -1.0;
          ObjectCreate(ch, arrowName, OBJ_ARROW, 0, timeArr[i], arrowPrice);
          ObjectSetInteger(ch, arrowName, OBJPROP_ARROWCODE,  234);
          ObjectSetInteger(ch, arrowName, OBJPROP_ANCHOR,     ANCHOR_BOTTOM);
          ObjectSetInteger(ch, arrowName, OBJPROP_COLOR,      InpArrowDownColor);
          ObjectSetInteger(ch, arrowName, OBJPROP_WIDTH,      InpArrowSize);
          ObjectSetInteger(ch, arrowName, OBJPROP_SELECTABLE, false);
          ObjectSetInteger(ch, arrowName, OBJPROP_HIDDEN,     true);
          ObjectSetString (ch, arrowName, OBJPROP_TOOLTIP, "SELL | " + reason);
        }
      }
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

  {
    int crossUp = 0, crossDn = 0, passTrendUp = 0, passTrendDn = 0, passAtrUp = 0, passAtrDn = 0;
    int passAdxUp = 0, passAdxDn = 0;
    int passSwingUp = 0, passSwingDn = 0;
    int passEnvUp = 0, passEnvDn = 0;
    int passEma9Up = 0, passEma9Dn = 0;
    int passPhaseUp = 0, passPhaseDn = 0;
    int validBuy = 0, validSell = 0;
    const int needSh = MathMax(1, InpAtrExpCompareBars) + MathMax(1, InpAtrExpRiseBars)
                     + (InpAdxFilterEnabled ? MathMax(0, InpAdxRiseBars) : 0);
    const int phaseLb = InpPhaseFilterEnabled
                      ? MathMax(InpPhaseExpandLookback, InpPhaseCoilLookback) + InpPhaseWmaFlatBars * 2 + 3
                      : 0;
    const PhaseEntryConfig phaseCfg = GetPhaseEntryConfig();
    for(int i = 1; i <= n; i++)
    {
      if(i + 1 >= rates_total || i + needSh >= rates_total
         || (InpTrendFilterEnabled && i + trendN >= need)
         || i + phaseLb >= rates_total)
        continue;

      const bool up = (buf_RSI[i+1] <= buf_WMA45[i+1]) && (buf_RSI[i] > buf_WMA45[i]);
      const bool dn = (buf_RSI[i+1] >= buf_WMA45[i+1]) && (buf_RSI[i] < buf_WMA45[i]);
      if(up) crossUp++;
      if(dn) crossDn++;
      if(up && (!InpTrendFilterEnabled || Trend_IsUpAt(i, MathMax(1, InpTrendConfirmBars), closeArr, buf_EMA200)))
        passTrendUp++;
      if(dn && (!InpTrendFilterEnabled || Trend_IsDownAt(i, MathMax(1, InpTrendConfirmBars), closeArr, buf_EMA200)))
        passTrendDn++;
      if(up && AtrExp_AllowsAt(i))  passAtrUp++;
      if(dn && AtrExp_AllowsAt(i))  passAtrDn++;
      string adxW = "";
      if(up && Adx_AllowsBuyAt(i, adxW))   passAdxUp++;
      if(dn && Adx_AllowsSellAt(i, adxW))  passAdxDn++;
      double swO = 0.0, swN = 0.0;
      if(up && SwingStruct_AllowsBuyAt(i, adxW, swO, swN))   passSwingUp++;
      if(dn && SwingStruct_AllowsSellAt(i, adxW, swO, swN))  passSwingDn++;
      if(up && Signal_Ema9CoreBuyOkAt(i))  passEma9Up++;
      if(dn && Signal_Ema9CoreSellOkAt(i)) passEma9Dn++;
      string pfB = "", pfS = "";
      if(up && Phase_BuyPasses(i, rates_total, buf_RSI, buf_EMA9, buf_WMA45, phaseCfg, pfB))  passPhaseUp++;
      if(dn && Phase_SellPasses(i, rates_total, buf_RSI, buf_EMA9, buf_WMA45, phaseCfg, pfS)) passPhaseDn++;
      const datetime tBar = iTime(_Symbol, _Period, i);
      string w = "";
      if(up && Env_AllowsSessionAt(tBar, w))  passEnvUp++;
      if(dn && Env_AllowsSessionAt(tBar, w))  passEnvDn++;
      if(buf_Signal[i] > 0.5)  validBuy++;
      if(buf_Signal[i] < -0.5) validSell++;
    }
    PrintFormat("[RsiMomEA]   last %d bars: cross UP=%d DN=%d | EMA9 UP=%d DN=%d | 5phase UP=%d DN=%d | EMA200 UP=%d DOWN=%d | ATR↑ UP=%d DN=%d | ADX UP=%d DN=%d | Swing2 UP=%d DN=%d | phiên UP=%d DN=%d | signal BUY=%d SELL=%d",
                n, crossUp, crossDn, passEma9Up, passEma9Dn, passPhaseUp, passPhaseDn,
                passTrendUp, passTrendDn, passAtrUp, passAtrDn, passAdxUp, passAdxDn,
                passSwingUp, passSwingDn, passEnvUp, passEnvDn, validBuy, validSell);
    if(crossUp > 0 && passPhaseUp == 0 && InpPhaseFilterEnabled)
      Print("[RsiMomEA]   Gợi ý: cross UP bị 5phase — xem P1-P5 hoặc hạ InpPhaseMinExpandSpread / InpPhaseMinRsiEma9Cross");
    else if(crossUp > 0 && passEma9Up == 0)
      Print("[RsiMomEA]   Gợi ý: cross UP nhưng EMA9>=WMA45 — không đủ điều kiện lõi BUY");
    if(InpAtrExpFilterEnabled && crossUp > 0 && passAtrUp == 0)
      Print("[RsiMomEA]   Gợi ý: cross bị chặn ATR — hạ InpAtrExpMinRatio / InpAtrExpRiseBars hoặc tắt InpAtrExpFilterEnabled");
    if(InpAdxFilterEnabled && crossUp > 0 && passAdxUp == 0)
      Print("[RsiMomEA]   Gợi ý: cross bị chặn ADX — hạ InpAdxMinLevel hoặc tắt InpAdxRequireDiDirection");
    if(InpSwingStructFilterEnabled && crossUp > 0 && passSwingUp == 0)
      Print("[RsiMomEA]   Gợi ý: cross bị chặn 2 đáy — tăng lookback hoặc tắt InpSwingStructFilterEnabled");
    if(InpSessionFilterEnabled && crossUp > 0 && passEnvUp == 0)
      Print("[RsiMomEA]   Gợi ý: cross bị chặn PHIÊN — chỉnh giờ London/NY (server) hoặc tắt InpSessionFilterEnabled");
  }
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
  const int atrNeed = MathMax(1, InpAtrExpCompareBars) + MathMax(1, InpAtrExpRiseBars) + 5;
  const int adxNeed = InpAdxFilterEnabled
                    ? MathMax(InpAdxPeriod, 5) + MathMax(0, InpAdxRiseBars) + 3
                    : 0;
  const int phaseNeed = InpPhaseFilterEnabled
                      ? MathMax(InpPhaseExpandLookback, InpPhaseCoilLookback) + InpPhaseWmaFlatBars * 2 + 10
                      : 0;
  const int minBars = MathMax(InpWMA45Period + InpRSIPeriod + 5 + phaseNeed,
                              MathMax(MathMax(InpAtrExpPeriod, InpSlAtrPeriod) + atrNeed, adxNeed));
  if (rates_total < minBars) return 0;

  EnsureBuffers(rates_total);

  const int rsiBars    = BarsCalculated(h_RSI);
  const int ema9Bars   = BarsCalculated(h_EMA9);
  const int wmaBars    = BarsCalculated(h_WMA45);
  const int ema200Bars = BarsCalculated(h_EMA200);
  const int atrRegBars = BarsCalculated(h_ATR_Regime);
  const int adxBars    = InpAdxFilterEnabled ? BarsCalculated(h_ADX) : 1;
  if (rsiBars <= 0 || ema9Bars <= 0 || wmaBars <= 0 || ema200Bars <= 0 || atrRegBars <= 0
      || adxBars <= 0)
  {
    static datetime lastWarn = 0;
    if (TimeCurrent() - lastWarn > 30)
    {
      PrintFormat("[RsiMomEA] Source not ready: RSI=%d EMA9=%d WMA45=%d EMA200=%d ATRreg=%d ADX=%d (rates=%d)",
                  rsiBars, ema9Bars, wmaBars, ema200Bars, atrRegBars, adxBars, rates_total);
      lastWarn = TimeCurrent();
    }
    return 0;
  }

  int srcMin = MathMin(MathMin(MathMin(MathMin(rsiBars, ema9Bars), wmaBars), ema200Bars), atrRegBars);
  if(InpAdxFilterEnabled)
    srcMin = MathMin(srcMin, adxBars);
  const int copyN  = MathMin(srcMin, rates_total);
  if (copyN < minBars) return 0;

  if (CopyBuffer(h_RSI,   0, 0, copyN, buf_RSI)    <= 0) return 0;
  if (CopyBuffer(h_EMA9,  0, 0, copyN, buf_EMA9)   <= 0) return 0;
  if (CopyBuffer(h_WMA45, 0, 0, copyN, buf_WMA45)  <= 0) return 0;

  int barsToScan = (prev_calculated == 0)
                   ? rates_total - 2
                   : (rates_total - prev_calculated + 2);
  barsToScan = MathMin(barsToScan, rates_total - 2);

  const int trendN = InpTrendFilterEnabled ? MathMax(1, InpTrendConfirmBars) : 0;
  const int need   = MathMin(barsToScan + 2 + (InpTrendFilterEnabled ? trendN : 0), copyN);

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

  if(ChartRedrawEffective())
    ChartRedraw(ActChart());
  Diagnostics_FirstPass(rates_total, copyN, trendN, need, closeArr);

  return copyN;
}

//+------------------------------------------------------------------+
int OnInit()
{
  g_lastAlertBuyBar  = 0;
  g_lastAlertSellBar = 0;
  g_dbgLogBarTime    = 0;
  g_dbgLogSide       = 0;
  g_firstCalc        = true;
  g_prevCalculated   = 0;
  g_tradeBarAnchor        = iTime(_Symbol, _Period, 0);
  g_pendingPlacedBarTime  = 0;
  Position_ResetPmState();

  g_statExitDeals = 0;
  g_statSL        = 0;
  g_statTP        = 0;
  g_statOther     = 0;
  g_statWins      = 0;
  g_statSumProfit = 0.0;

  if(InpExportTradeJournal)
  {
    RsiMomJournal_ResetMonths();
    if(InpJournalResetOnInit && MQLInfoInteger(MQL_TESTER))
      RsiMomJournal_ResetFiles(_Symbol, _Period);
  }

  g_trade.SetExpertMagicNumber(InpMagic);
  g_trade.SetDeviationInPoints(InpSlippagePoints);
  SetTradeFillingFromSymbol();

  if (!Handles_CreateAll())
    return INIT_FAILED;

  const long chInit = ActChart();
  ObjectsDeleteAll(chInit, OBJ_PREFIX + "RSN_");
  ObjectsDeleteAll(chInit, DBG_PREFIX);
  if(DebugMarksEffective())
    Signal_DebugConfigureChart(chInit);

  if(InpShowPanel)
    Panel_CreateAll();
  if(InpShowStats)
  {
    Stats_CreateObjects();
    Stats_UpdateDisplay();
  }
  const int spr = Env_CurrentSpreadPts();
  string envWhy = "";
  const bool envNow = Env_AllowsTradeAtBar(MathMax(1, InpSignalBarShift), envWhy);
  if(InpExportTradeJournal)
    Print("[RsiMomEA] Journal CSV: ", RsiMomJournal_TradesPath(_Symbol, _Period),
          " | summary: ", RsiMomJournal_SummaryPath(_Symbol, _Period), " (FILE_COMMON)");

  Print("[RsiMomEA] Init OK v", EA_VERSION_STR, " — entry=", EntryModeLabel(),
        " | RSI×WMA45 + ", InpPhaseFilterEnabled ? "5phase" : "core",
        " | EMA200=", InpTrendFilterEnabled ? "on" : "OFF",
        " | session=", InpSessionFilterEnabled ? "on" : "OFF",
        " | debugMarks=", InpDebugMarkSignals ? "on" : "off",
        " | ATR+EMA200+phiên | trade=", InpTradeEnabled ? "on" : "off", " risk%=", InpRiskPercent,
        " ATRexp=", InpAtrExpFilterEnabled
          ? StringFormat("ratio>=%.2f rise%d cmp%d", InpAtrExpMinRatio, InpAtrExpRiseBars, InpAtrExpCompareBars) : "OFF",
        " ADX=", InpAdxFilterEnabled
          ? StringFormat(">=%.0f DI=%s rise%d", InpAdxMinLevel,
                         InpAdxRequireDiDirection ? "on" : "off", InpAdxRiseBars) : "OFF",
        " session=", InpSessionFilterEnabled
          ? StringFormat("L%d-%d NY%d-%d avoid%d%s", InpLondonStartHour, InpLondonEndHour,
                         InpNYStartHour, InpNYEndHour, InpSessionAvoidLastMin,
                         InpEnvUseUtc ? " UTC" : " srv") : "off",
        " spread=", InpSpreadFilterEnabled
          ? (InpSpreadSkipInTester && MQLInfoInteger(MQL_TESTER)
             ? "off-in-tester" : StringFormat("<=%d", InpMaxSpreadPoints)) : "off");
  PrintFormat("[RsiMomEA]   SYMBOL_SPREAD=%d pts | env@signalBar1=%s %s",
              spr, envNow ? "OK" : "BLOCK", envWhy);
  if(InpSpreadFilterEnabled && !InpSpreadSkipInTester && spr > InpMaxSpreadPoints)
    PrintFormat("[RsiMomEA]   CẢNH BÁO: spread tester %d > max %d → không vào lệnh. Tăng InpMaxSpreadPoints hoặc bật InpSpreadSkipInTester.",
                spr, InpMaxSpreadPoints);
  if(InpSessionFilterEnabled && !envNow &&
     (StringFind(envWhy, "ngoài") >= 0 || StringFind(envWhy, "giao") >= 0))
    Print("[RsiMomEA]   Gợi ý phiên: chỉnh London/NY theo giờ SERVER (xem bar time trong tester), hoặc tắt InpSessionFilterEnabled để test.");
  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  if(InpExportTradeJournal)
    RsiMomJournal_OnDeinit(_Symbol, _Period);

  Pending_CancelMine();
  Handles_ReleaseAll();
  ObjectsDeleteAll(ActChart(), OBJ_PREFIX);
  ObjectsDeleteAll(ActChart(), STAT_PREFIX);
  ChartRedraw(ActChart());
}

//+------------------------------------------------------------------+
void OnTick()
{
  if(EntryModeIsLimit())
  {
    Pending_EnvCancelIfBad();
    Pending_ManageExpiry();
  }
  Position_ManageAt1R();

  const datetime t0 = iTime(_Symbol, _Period, 0);
  const bool newBar = (t0 != 0 && t0 != g_tradeBarAnchor);
  const bool runCalc = (g_prevCalculated == 0)
                       || newBar
                       || !IsStrategyTester()
                       || !InpTesterCalcOnNewBarOnly;

  int calcRet = g_prevCalculated;
  if(runCalc)
  {
    const int rates_total = Bars(_Symbol, _Period);
    calcRet = RsiMomentum_OnCalculate(rates_total, g_prevCalculated);
    if(calcRet != 0)
      g_prevCalculated = calcRet;
  }

  if(newBar)
  {
    g_tradeBarAnchor = t0;
    TradeTryOnBarOpen(calcRet);
  }

  if(InpShowPanel)
    Panel_UpdateStatus();
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!DebugMarksEffective() || !InpDebugHoverHint)
      return;

   const long ch = ActChart();

   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      Signal_DebugOnMouseMove(ch, DBG_PREFIX, (int)lparam, (int)dparam);
      return;
   }

   if(id == CHARTEVENT_CHART_CHANGE || id == CHARTEVENT_CLICK)
   {
      Signal_DebugHideHoverHint(ch);
   }
}

//+------------------------------------------------------------------+
void Position_ResetPmState()
{
  g_pmTicket      = 0;
  g_pmInitialRisk = 0.0;
  g_pmAt1RDone    = false;
}

ulong Position_FindMyTicket()
{
  for(int i = PositionsTotal() - 1; i >= 0; i--)
  {
    const ulong ticket = PositionGetTicket(i);
    if(ticket == 0)
      continue;
    if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      continue;
    return ticket;
  }
  return 0;
}

double Position_VolumeStepDown(const double vol)
{
  const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  if(step <= 0.0)
    return vol;

  double v = MathFloor(vol / step) * step;
  if(v < vmin)
    return 0.0;
  return NormalizeDouble(v, 8);
}

void Position_ManageAt1R()
{
  if(!InpManageAt1R)
    return;

  const ulong ticket = Position_FindMyTicket();
  if(ticket == 0)
  {
    if(g_pmTicket != 0)
      Position_ResetPmState();
    return;
  }

  if(g_pmTicket != ticket)
  {
    g_pmTicket      = ticket;
    g_pmAt1RDone    = false;
    const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    const double sl    = PositionGetDouble(POSITION_SL);
    g_pmInitialRisk = MathAbs(entry - sl);
    if(g_pmInitialRisk < _Point * 2.0)
      g_pmInitialRisk = 0.0;
  }

  if(g_pmAt1RDone || g_pmInitialRisk <= 0.0)
    return;

  if(!PositionSelectByTicket(ticket))
    return;

  MqlTick tk;
  if(!SymbolInfoTick(_Symbol, tk))
    return;

  const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const bool isBuy = (ptype == POSITION_TYPE_BUY);
  const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  const double cur   = isBuy ? tk.bid : tk.ask;
  const double profitDist = isBuy ? (cur - entry) : (entry - cur);

  if(profitDist + _Point < g_pmInitialRisk)
    return;

  const double vol = PositionGetDouble(POSITION_VOLUME);
  const double ratio = MathMax(0.01, MathMin(1.0, InpPartialCloseRatio));
  double closeVol = Position_VolumeStepDown(vol * ratio);
  const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double remain = vol - closeVol;

  if(closeVol >= vmin && remain >= vmin)
  {
    if(g_trade.PositionClosePartial(ticket, closeVol))
      Print("[RsiMomEA] Chốt ", DoubleToString(closeVol, 2), " lot (",
            DoubleToString(ratio * 100.0, 0), "%) @ 1R — ticket #", ticket);
    else
      Print("[RsiMomEA] Partial close fail ", g_trade.ResultRetcode(), " ",
            g_trade.ResultComment());
  }

  const double off = MathMax(0, InpBreakevenOffsetPts) * _Point;
  double beSl = isBuy ? (entry - off) : (entry + off);
  beSl = NormalizeDouble(beSl, dig);

  const double tp = PositionGetDouble(POSITION_TP);
  const double curSl = PositionGetDouble(POSITION_SL);
  const bool needBe = isBuy ? (curSl < beSl - _Point) : (curSl > beSl + _Point);

  if(needBe && StopsValid(isBuy, cur, beSl, tp))
  {
    if(g_trade.PositionModify(ticket, beSl, tp))
      Print("[RsiMomEA] SL → entry (BE) @ ", DoubleToString(beSl, dig),
            " sau khi đạt 1R — ticket #", ticket);
    else
      Print("[RsiMomEA] BE modify fail ", g_trade.ResultRetcode(), " ",
            g_trade.ResultComment());
  }

  g_pmAt1RDone = true;
}

//+------------------------------------------------------------------+
bool Signal_BodyMidPrice(const int shift, double &midOut)
{
  const double o = iOpen(_Symbol, _Period, shift);
  const double c = iClose(_Symbol, _Period, shift);
  midOut = (o + c) * 0.5;
  return (midOut > 0.0);
}

bool LimitPriceValid(const bool isBuy, const double limitPx)
{
  MqlTick tk;
  if(!SymbolInfoTick(_Symbol, tk))
    return false;

  const int    stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  const int    freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
  const double md = (stops > freeze ? stops : freeze) * _Point;

  if(isBuy)
    return (limitPx < tk.ask - md);
  return (limitPx > tk.bid + md);
}

//+------------------------------------------------------------------+
bool EntryModeIsLimit()
{
  return (InpEntryMode == RSI_MOM_ENTRY_LIMIT_BODY50);
}

bool EntryModeIsMarket()
{
  return (InpEntryMode == RSI_MOM_ENTRY_MARKET);
}

string EntryModeLabel()
{
  return EntryModeIsMarket() ? "Market" : "Limit 50% body";
}

//+------------------------------------------------------------------+
void TradeExecuteOrder(const bool isBuy)
{
  if(EntryModeIsMarket())
    TradeExecuteMarketOrder(isBuy);
  else
    TradeExecuteLimitOrder(isBuy);
}

//+------------------------------------------------------------------+
void TradeExecuteLimitOrder(const bool isBuy)
{
  if (InpOnePositionFlat && HasMyMagicPositionOrPending())
    return;

  string envWhy = "";
  if(!Env_AllowsTradeNow(envWhy))
  {
    Print("[RsiMomEA] Trade skip ", isBuy ? "BUY" : "SELL", ": ", envWhy,
          "(spread=", Env_CurrentSpreadPts(), " pts)");
    return;
  }

  const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  const int sigSh = MathMax(1, InpSignalBarShift);

  double bodyMid = 0.0;
  if(!Signal_BodyMidPrice(sigSh, bodyMid))
  {
    Print("[RsiMomEA] Trade skip: không lấy được 50% thân nến tín hiệu (shift ", sigSh, ")");
    return;
  }
  const double entryPx = NormalizeDouble(bodyMid, dig);

  if(!LimitPriceValid(isBuy, entryPx))
  {
    Print("[RsiMomEA] Trade skip ", isBuy ? "BUY" : "SELL",
          " Limit @ ", DoubleToString(entryPx, dig),
          " không hợp lệ (BUY Limit < Ask, SELL Limit > Bid)");
    return;
  }

  Pending_CancelMine();

  double sl = 0.0, tp = 0.0;
  if (!NearestSwingSlTp(isBuy, entryPx, dig, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: SL/TP swing không hợp lệ");
    return;
  }
  if (!StopsValid(isBuy, entryPx, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: STOPS_LEVEL / FREEZE");
    return;
  }

  double vol = VolumeForRiskPercent(isBuy, entryPx, sl);
  vol = NormalizeLots(vol);
  if (vol <= 0.0)
  {
    Print("[RsiMomEA] Trade skip: volume=0");
    return;
  }

  const bool ok = isBuy
                ? g_trade.BuyLimit(vol, entryPx, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RsiMom BUY body50")
                : g_trade.SellLimit(vol, entryPx, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RsiMom SELL body50");
  if (!ok)
    Print("[RsiMomEA] Limit fail ", g_trade.ResultRetcode(), " ", g_trade.ResultComment());
  else
  {
    g_pendingPlacedBarTime = iTime(_Symbol, _Period, 0);
    Print("[RsiMomEA] Limit OK #", g_trade.ResultOrder(), " ", isBuy ? "BUY" : "SELL",
          " @ ", DoubleToString(entryPx, dig), " (50% body bar ", sigSh, ")",
          " vol=", vol, " SL=", DoubleToString(sl, dig), " TP=", DoubleToString(tp, dig),
          " expireBars=", InpLimitExpireBars);
  }
}

//+------------------------------------------------------------------+
void TradeExecuteMarketOrder(const bool isBuy)
{
  if(InpOnePositionFlat && CountMyMagicPositions() > 0)
    return;

  string envWhy = "";
  if(!Env_AllowsTradeNow(envWhy))
  {
    Print("[RsiMomEA] Trade skip ", isBuy ? "BUY" : "SELL", ": ", envWhy,
          "(spread=", Env_CurrentSpreadPts(), " pts)");
    return;
  }

  MqlTick tk;
  if(!SymbolInfoTick(_Symbol, tk))
  {
    Print("[RsiMomEA] Trade skip: không lấy được tick");
    return;
  }

  const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  const double entryPx = NormalizeDouble(isBuy ? tk.ask : tk.bid, dig);

  double sl = 0.0, tp = 0.0;
  if(!NearestSwingSlTp(isBuy, entryPx, dig, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: SL/TP swing không hợp lệ");
    return;
  }
  if(!StopsValid(isBuy, entryPx, sl, tp))
  {
    Print("[RsiMomEA] Trade skip: STOPS_LEVEL / FREEZE");
    return;
  }

  double vol = VolumeForRiskPercent(isBuy, entryPx, sl);
  vol = NormalizeLots(vol);
  if(vol <= 0.0)
  {
    Print("[RsiMomEA] Trade skip: volume=0");
    return;
  }

  const bool ok = isBuy
                ? g_trade.Buy(vol, _Symbol, 0.0, sl, tp, "RsiMom BUY mkt")
                : g_trade.Sell(vol, _Symbol, 0.0, sl, tp, "RsiMom SELL mkt");
  if(!ok)
    Print("[RsiMomEA] Market fail ", g_trade.ResultRetcode(), " ", g_trade.ResultComment());
  else
    Print("[RsiMomEA] Market OK #", g_trade.ResultDeal(), " ", isBuy ? "BUY" : "SELL",
          " @~", DoubleToString(entryPx, dig),
          " vol=", vol, " SL=", DoubleToString(sl, dig), " TP=", DoubleToString(tp, dig));
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

  TradeExecuteOrder(s > 0.5);
}

//+------------------------------------------------------------------+
int CountMyMagicPendingOrders()
{
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--)
  {
    const ulong ticket = OrderGetTicket(i);
    if (ticket == 0)
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
      continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT)
      n++;
  }
  return n;
}

bool HasMyMagicPositionOrPending()
{
  return (CountMyMagicPositions() > 0 || CountMyMagicPendingOrders() > 0);
}

void Pending_EnvCancelIfBad()
{
  if(!InpSessionFilterEnabled && !InpSpreadFilterEnabled && !InpTransitionBlockEnabled)
    return;

  if(CountMyMagicPendingOrders() == 0)
    return;

  string why = "";
  if(Env_AllowsTradeNow(why))
    return;

  Print("[RsiMomEA] Hủy Limit — môi trường trade: ", why,
        " spread=", Env_CurrentSpreadPts(), " pts");
  Pending_CancelMine();
}

bool Pending_CancelMine()
{
  bool any = false;
  for (int i = OrdersTotal() - 1; i >= 0; i--)
  {
    const ulong ticket = OrderGetTicket(i);
    if (ticket == 0)
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
      continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_SELL_LIMIT)
      continue;
    if (g_trade.OrderDelete(ticket))
      any = true;
  }
  if (any)
    g_pendingPlacedBarTime = 0;
  return any;
}

void Pending_ManageExpiry()
{
  if (InpLimitExpireBars <= 0)
    return;
  if (g_pendingPlacedBarTime == 0)
    return;

  int pendingCount = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--)
  {
    const ulong ticket = OrderGetTicket(i);
    if (ticket == 0)
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
      continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_SELL_LIMIT)
      continue;
    pendingCount++;
  }

  if (pendingCount == 0)
  {
    g_pendingPlacedBarTime = 0;
    return;
  }

  const int shift = iBarShift(_Symbol, _Period, g_pendingPlacedBarTime, true);
  if (shift < 0)
    return;

  if (shift >= InpLimitExpireBars)
  {
    Print("[RsiMomEA] Hủy Limit sau ", shift, " nến (max ", InpLimitExpireBars, ")");
    Pending_CancelMine();
  }
}

//+------------------------------------------------------------------+
//| Khoảng cách đẩy SL ra xa pivot: spread (+) ATR×mult nếu bật      |
//+------------------------------------------------------------------+
double Sl_GetBufferDistance(const int atrShift = 1)
{
  double dist = 0.0;

  if (InpSlAtrAddSpread)
  {
    const int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    dist += spr * _Point;
  }

  if (InpSlAtrBufferEnabled && h_ATR != INVALID_HANDLE)
  {
    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if (CopyBuffer(h_ATR, 0, atrShift, 1, atrBuf) > 0 && atrBuf[0] > 0.0)
      dist += atrBuf[0] * MathMax(0.0, InpSlAtrMultiplier);
  }

  return dist;
}

//+------------------------------------------------------------------+
bool NearestSwingSlTp(const bool isBuy, const double entry, const int dig, double &sl, double &tp)
{
  const double rr  = MathMax(0.01, InpRewardRiskRatio);
  const int    mx  = MathMax(5, InpSwingMaxBars);
  const double buf = Sl_GetBufferDistance(1);

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
int Stats_LineStepPx()
{
  return MathMax(12, InpStatFontSize + MathMax(8, InpStatLinePad));
}

void Stats_CreateObjects()
{
  const long ch = ActChart();
  const int  fs = MathMax(7, InpStatFontSize);
  const int  step = Stats_LineStepPx();
  const int  y0 = MathMax(10, InpStatBottomMargin);

  for (int k = 0; k < 3; k++)
  {
    const string name = (k == 0) ? STAT_L1 : ((k == 1) ? STAT_L2 : STAT_L3);
    if (ObjectFind(ch, name) >= 0)
      continue;
    ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(ch, name, OBJPROP_CORNER,      CORNER_LEFT_LOWER);
    ObjectSetInteger(ch, name, OBJPROP_XDISTANCE,   8);
    ObjectSetInteger(ch, name, OBJPROP_YDISTANCE,   y0 + k * step);
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
    if(ChartRedrawEffective())
      ChartRedraw(ch);
    return;
  }

  const int fs   = MathMax(7, InpStatFontSize);
  const int step = Stats_LineStepPx();
  const int y0   = MathMax(10, InpStatBottomMargin);
  for (int k = 0; k < 3; k++)
  {
    const string nm = (k == 0) ? STAT_L1 : ((k == 1) ? STAT_L2 : STAT_L3);
    ObjectSetInteger(ch, nm, OBJPROP_FONTSIZE,  fs);
    ObjectSetInteger(ch, nm, OBJPROP_YDISTANCE, y0 + k * step);
  }

  double winrate = 0.0;
  if (g_statExitDeals > 0)
    winrate = 100.0 * (double)g_statWins / (double)g_statExitDeals;

  const string cur = AccountInfoString(ACCOUNT_CURRENCY);
  double avg = 0.0;
  if (g_statExitDeals > 0)
    avg = g_statSumProfit / (double)g_statExitDeals;

  string line1 = StringFormat("Average Profit / trade: %s %s", DoubleToString(avg, 2), cur);
  const string line2 = StringFormat("Winrate: %.1f%%", winrate);
  string line3 = StringFormat("Total: %I64d | SL %I64d | TP %I64d",
                              g_statExitDeals, g_statSL, g_statTP);
  if (g_statOther > 0)
    line3 += StringFormat(" | Other %I64d", g_statOther);

  ObjectSetString (ch, STAT_L3, OBJPROP_TEXT, line3);
  ObjectSetInteger(ch, STAT_L3, OBJPROP_COLOR, InpStatColor);
  ObjectSetString (ch, STAT_L2, OBJPROP_TEXT, line2);
  ObjectSetInteger(ch, STAT_L2, OBJPROP_COLOR, InpStatColor);
  ObjectSetString (ch, STAT_L1, OBJPROP_TEXT, line1);
  ObjectSetInteger(ch, STAT_L1, OBJPROP_COLOR, InpStatColor);
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

  if(InpExportTradeJournal)
  {
    const ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    ulong entryDeal = 0;
    datetime entryTime = 0;
    long posType = 0;
    double entryPrice = 0.0, sl = 0.0, tp = 0.0, vol = 0.0;
    int sessionOk = 0;
    if(RsiMomJournal_FindEntryDeal(posId, entryDeal, entryTime, posType,
                                   entryPrice, sl, tp, vol))
    {
      string envWhy = "";
      sessionOk = Env_AllowsSessionAt(entryTime, envWhy) ? 1 : 0;
    }

    RsiMomJournal_RecordClosedDeal(dealTicket, _Symbol, _Period, InpMagic,
                                   h_RSI, h_WMA45, h_EMA200, h_ATR_Regime,
                                   InpAtrExpCompareBars, InpAtrExpMinRatio,
                                   sessionOk);
  }

  Stats_UpdateDisplay();
}

//+------------------------------------------------------------------+
