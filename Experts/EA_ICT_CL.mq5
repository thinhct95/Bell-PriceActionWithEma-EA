//+------------------------------------------------------------------+
//| ICT EA – FVG Edition                                             |
//| Architecture: 3 TF | 4 State Machine                            |
//+------------------------------------------------------------------+
#property strict

//====================================================
// INPUTS
//====================================================

input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_D1;  // Bias Timeframe
input ENUM_TIMEFRAMES InpMiddleTF        = PERIOD_H1;  // Middle TF – nơi quét FVG
input ENUM_TIMEFRAMES InpTriggerTF       = PERIOD_M5;  // Trigger TF – xác nhận vào lệnh

input double InpRiskPercent              = 1.0;
input double InpRiskReward               = 2.0;
input double InpMaxDailyLossPct          = 3.0;

input int    InpLondonStartHour          = 8;
input int    InpLondonEndHour            = 17;
input int    InpNYStartHour              = 13;
input int    InpNYEndHour                = 22;
input int    InpSessionAvoidLastMin      = 60;

input int    InpFVGMaxAliveMin           = 4320;        // FVG sống tối đa bao nhiêu phút: 3 ngày
input int    InpFVGScanBars              = 50;          // Số bar MiddleTF quét ngược để tìm FVG
input double InpFVGMinBodyPct            = 60.0;        // Nến giữa phải có body >= X% range
input int    InpTriggerMaxBars           = 30;          // Số bar TriggerTF chờ sau khi touched

input bool   InpDebugLog                 = true;
input bool   InpDebugDraw                = true;

//====================================================
// ENUMS
//====================================================

enum EAState
{
  EA_IDLE,          // Chờ điều kiện: bias hợp lệ + tìm FVG candidate
  EA_WAIT_TOUCH,    // Có FVG candidate, chờ price chạm vào vùng FVG
  EA_WAIT_TRIGGER,  // Price đã chạm FVG, chờ Trigger TF xác nhận entry
  EA_IN_TRADE       // Đang có lệnh, chờ kết thúc
};

enum HTFBias
{
  BIAS_NONE    =  0,
  BIAS_UP      =  1,
  BIAS_DOWN    = -1,
  BIAS_SIDEWAY =  2
};

enum MarketDir
{
  DIR_NONE  =  0,
  DIR_UP    =  1,
  DIR_DOWN  = -1
};

enum BlockReason
{
  BLOCK_NONE,
  BLOCK_SESSION,
  BLOCK_DAILY_LOSS,
  BLOCK_BIAS_MISMATCH,
  BLOCK_NO_BIAS
};

//====================================================
// STRUCTS
//====================================================

struct BiasContext
{
  HTFBias  bias;
  double   rangeHigh;    // Dùng khi sideway
  double   rangeLow;
  datetime lastBarTime;  // Guard: chỉ update khi bar mới
};

struct FVGContext
{
  bool      active;      // Đang có FVG candidate
  bool      touched;     // Price đã chạm vào FVG chưa

  MarketDir direction;   // FVG thuận chiều bias
  double    high;        // Cạnh trên FVG
  double    low;         // Cạnh dưới FVG
  double    mid;         // Midpoint – dùng làm entry tham chiếu

  datetime  createdTime; // Thời điểm nến phải đóng = FVG confirmed
  datetime  touchTime;   // Thời điểm price chạm lần đầu

  int       barsAlive;   // Số bar TriggerTF đã qua kể từ touched
  int       touchBarIdx; // Bar index TriggerTF lúc touched
};

struct TriggerContext
{
  bool      valid;
  MarketDir direction;
  double    swingHigh;
  double    swingLow;
  int       idxHigh;
  int       idxLow;
  double    breakLevel;  // Level cần phá để confirm entry
};

struct OrderPlan
{
  bool   valid;
  int    direction;
  double entry;
  double stopLoss;
  double takeProfit;
  double lot;
};

struct DailyRiskContext
{
  double   startBalance;
  double   currentBalance; // Cập nhật mỗi tick – dùng lại trong DrawContextDebug
  datetime dayStartTime;
  bool     limitHit;
};

//====================================================
// GLOBAL STATE
//====================================================

EAState          g_State        = EA_IDLE;
BlockReason      g_BlockReason  = BLOCK_NONE;

BiasContext      g_Bias;
FVGContext       g_FVG;
TriggerContext   g_Trigger;
DailyRiskContext g_DailyRisk;

int              g_TradeBarIndex = -1;

// Tên objects vẽ FVG trên chart
const string FVG_RECT_NAME  = "FVG_RECT";
const string FVG_MID_NAME   = "FVG_MID";
const string FVG_LABEL_NAME = "FVG_LABEL";

//====================================================
// CONTEXT UPDATERS
//====================================================

HTFBias ResolveBias(
  double b1High, double b1Low, double b1Close,
  double b2High, double b2Low)
{
  if (b1Close > b2High)                    return BIAS_UP;    // Rule 1: Breakout lên
  if (b1Close < b2Low)                     return BIAS_DOWN;  // Rule 2: Breakout xuống
  if (b1High > b2High && b1Close < b2High) return BIAS_DOWN; // Rule 3: Sweep high → reject
  if (b1Low  < b2Low  && b1Close > b2Low)  return BIAS_UP;   // Rule 4: Sweep low → recover
  return BIAS_SIDEWAY;                                         // Rule 5: Còn lại
}

void UpdateBiasContext()
{
  datetime currentBarTime = iTime(_Symbol, InpBiasTF, 0);
  if (currentBarTime == g_Bias.lastBarTime) return; // Guard: 1 lần/bar

  g_Bias.lastBarTime = currentBarTime;

  if (Bars(_Symbol, InpBiasTF) < 4) { g_Bias.bias = BIAS_NONE; return; }

  double b1High  = iHigh (_Symbol, InpBiasTF, 1);
  double b1Low   = iLow  (_Symbol, InpBiasTF, 1);
  double b1Close = iClose(_Symbol, InpBiasTF, 1);
  double b2High  = iHigh (_Symbol, InpBiasTF, 2);
  double b2Low   = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prevBias = g_Bias.bias;
  g_Bias.bias      = ResolveBias(b1High, b1Low, b1Close, b2High, b2Low);

  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2High : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2Low  : 0;

  if (InpDebugLog && g_Bias.bias != prevBias)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prevBias), EnumToString(g_Bias.bias),
      b1High, b1Low, b1Close, b2High, b2Low);
}

void UpdateDailyRiskContext()
{
  datetime todayBarTime = iTime(_Symbol, PERIOD_D1, 0);  // "ID" của ngày – đổi khi sang ngày mới

  if (todayBarTime != g_DailyRisk.dayStartTime)
  {
    g_DailyRisk.dayStartTime = todayBarTime;
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Chụp balance đầu ngày (không tính floating P&L)
    g_DailyRisk.limitHit     = false;                              // Reset – cho phép trade ngày mới

    if (InpDebugLog)
      PrintFormat("[DAILY RISK] New day | startBalance=%.2f", g_DailyRisk.startBalance);
  }

  if (g_DailyRisk.limitHit) return; // Đã hit → không tính lại mỗi tick

  g_DailyRisk.currentBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Lưu vào struct, DrawDebug dùng lại

  double lostPct = (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
                    / g_DailyRisk.startBalance * 100.0;

  if (lostPct >= InpMaxDailyLossPct)
  {
    g_DailyRisk.limitHit = true;
    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | limit=%.2f%% | balance=%.2f",
      lostPct, InpMaxDailyLossPct, g_DailyRisk.currentBalance);
  }
}

void UpdateAllContexts()
{
  UpdateDailyRiskContext(); // Mỗi tick (early-exit khi limitHit)
  UpdateBiasContext();      // 1 lần/bar (guard lastBarTime)
}

//====================================================
// GUARDS
//====================================================

bool IsSessionAllowed() { return true; /* TODO */ }
bool IsDailyLossOK()    { return !g_DailyRisk.limitHit; }
bool IsBiasValid()      { return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN; }

bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;
  if (!IsSessionAllowed()) { g_BlockReason = BLOCK_SESSION;    return false; }
  if (!IsDailyLossOK())    { g_BlockReason = BLOCK_DAILY_LOSS; return false; }
  if (!IsBiasValid())      { g_BlockReason = BLOCK_NO_BIAS;    return false; }
  return true;
}

//====================================================
// TRANSITIONS
//====================================================

void TransitionTo(EAState next)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s", EnumToString(g_State), EnumToString(next));
  g_State = next;
}

void ResetToIdle(string reason = "")
{
  if (InpDebugLog && reason != "")
    PrintFormat("[RESET] %s", reason);

  ZeroMemory(g_FVG);
  ZeroMemory(g_Trigger);
  g_TradeBarIndex = -1;

  // Xóa FVG objects khi reset
  ObjectDelete(0, FVG_RECT_NAME);
  ObjectDelete(0, FVG_MID_NAME);
  ObjectDelete(0, FVG_LABEL_NAME);

  TransitionTo(EA_IDLE);
}

//====================================================
// FVG HELPERS
//====================================================

bool IsCandleStrong(ENUM_TIMEFRAMES tf, int barIndex)
{
  double high  = iHigh (_Symbol, tf, barIndex);
  double low   = iLow  (_Symbol, tf, barIndex);
  double open  = iOpen (_Symbol, tf, barIndex);
  double close = iClose(_Symbol, tf, barIndex);

  double range = high - low;
  if (range < _Point) return false;

  double body = MathAbs(close - open);
  return (body / range * 100.0) >= InpFVGMinBodyPct;
}

// Fill = bar sau FVG có close đi vào vùng gap
bool IsFVGAlreadyFilled(
  ENUM_TIMEFRAMES tf,
  int             fvgRightIdx, // Index nến phải của FVG pattern
  double          fvgHigh,
  double          fvgLow,
  MarketDir       dir)
{
  for (int j = fvgRightIdx - 1; j >= 1; j--)
  {
    double close = iClose(_Symbol, tf, j);
    if (dir == DIR_UP   && close <= fvgHigh) return true; // Retraced vào gap bullish
    if (dir == DIR_DOWN && close >= fvgLow)  return true; // Retraced vào gap bearish
  }
  return false;
}

bool IsFVGExpired()
{
  if (g_FVG.createdTime <= 0) return false;
  return (int)(TimeCurrent() - g_FVG.createdTime) > InpFVGMaxAliveMin * 60;
}

// Invalidate = MiddleTF close xuyên hoàn toàn qua FVG ngược chiều
bool IsFVGInvalidated()
{
  double lastClose = iClose(_Symbol, InpMiddleTF, 1);
  if (g_FVG.direction == DIR_UP   && lastClose < g_FVG.low)  return true;
  if (g_FVG.direction == DIR_DOWN && lastClose > g_FVG.high) return true;
  return false;
}

//====================================================
// FVG DETECTION
//
// Pattern 3 nến tại index i (i = nến giữa):
//   bar[i+1] = nến trái  (older)
//   bar[i]   = nến giữa  (impulse – phải mạnh)
//   bar[i-1] = nến phải  (newer)
//
// Bullish FVG: bar[i+1].high < bar[i-1].low
//   gapLow  = bar[i+1].high  (đỉnh nến trái = cạnh dưới gap)
//   gapHigh = bar[i-1].low   (đáy nến phải  = cạnh trên gap)
//
// Bearish FVG: bar[i+1].low > bar[i-1].high
//   gapHigh = bar[i+1].low   (đáy nến trái  = cạnh trên gap)
//   gapLow  = bar[i-1].high  (đỉnh nến phải = cạnh dưới gap)
//====================================================

bool FindFVGCandidate(FVGContext &fvg)
{
  MarketDir targetDir = (g_Bias.bias == BIAS_UP) ? DIR_UP : DIR_DOWN;
  int maxBar = MathMin(InpFVGScanBars, Bars(_Symbol, InpMiddleTF) - 2);

  for (int i = 2; i <= maxBar; i++)
  {
    double leftHigh  = iHigh (_Symbol, InpMiddleTF, i + 1);
    double leftLow   = iLow  (_Symbol, InpMiddleTF, i + 1);
    double rightHigh = iHigh (_Symbol, InpMiddleTF, i - 1);
    double rightLow  = iLow  (_Symbol, InpMiddleTF, i - 1);
    double midOpen   = iOpen (_Symbol, InpMiddleTF, i);
    double midClose  = iClose(_Symbol, InpMiddleTF, i);

    double gapHigh, gapLow;

    if (targetDir == DIR_UP)
    {
      if (leftHigh >= rightLow)            continue; // Không có gap
      if (midClose <= midOpen)             continue; // Nến giữa phải bullish
      if (!IsCandleStrong(InpMiddleTF, i)) continue; // Body >= InpFVGMinBodyPct%

      gapLow  = leftHigh;  // Đỉnh nến trái = cạnh dưới gap
      gapHigh = rightLow;  // Đáy nến phải  = cạnh trên gap
    }
    else // DIR_DOWN
    {
      if (leftLow <= rightHigh)            continue; // Không có gap
      if (midClose >= midOpen)             continue; // Nến giữa phải bearish
      if (!IsCandleStrong(InpMiddleTF, i)) continue; // Body >= InpFVGMinBodyPct%

      gapHigh = leftLow;   // Đáy nến trái  = cạnh trên gap
      gapLow  = rightHigh; // Đỉnh nến phải = cạnh dưới gap
    }

    if (IsFVGAlreadyFilled(InpMiddleTF, i - 1, gapHigh, gapLow, targetDir))
      continue;

    // ── FVG hợp lệ → điền struct ────────────────────────────────
    fvg.active      = true;
    fvg.touched     = false;
    fvg.direction   = targetDir;
    fvg.high        = gapHigh;
    fvg.low         = gapLow;
    fvg.mid         = (gapHigh + gapLow) / 2.0;
    fvg.createdTime = iTime(_Symbol, InpMiddleTF, i - 1); // Nến phải đóng = FVG confirmed
    fvg.touchTime   = 0;
    fvg.barsAlive   = 0;
    fvg.touchBarIdx = -1;

    return true;
  }

  return false;
}

//====================================================
// STATE HANDLERS
//====================================================

void OnStateIdle()
{
  FVGContext candidate;
  ZeroMemory(candidate);

  if (!FindFVGCandidate(candidate)) return;

  g_FVG = candidate;

  if (InpDebugLog)
    PrintFormat("[FVG FOUND] dir=%s | high=%.5f | low=%.5f | mid=%.5f | created=%s",
      EnumToString(g_FVG.direction), g_FVG.high, g_FVG.low, g_FVG.mid,
      TimeToString(g_FVG.createdTime));

  TransitionTo(EA_WAIT_TOUCH);
}

void OnStateWaitTouch()
{
  if (IsFVGExpired())     { ResetToIdle("FVG expired");     return; }
  if (IsFVGInvalidated()) { ResetToIdle("FVG invalidated"); return; }

  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  bool touched = false;
  if (g_FVG.direction == DIR_UP   && bid <= g_FVG.high) touched = true; // Retraced xuống chạm cạnh trên gap
  if (g_FVG.direction == DIR_DOWN && bid >= g_FVG.low)  touched = true; // Retraced lên chạm cạnh dưới gap

  if (!touched) return;

  g_FVG.touched     = true;
  g_FVG.touchTime   = TimeCurrent();
  g_FVG.touchBarIdx = iBarShift(_Symbol, InpTriggerTF, TimeCurrent());
  g_FVG.barsAlive   = 0;

  if (InpDebugLog)
    PrintFormat("[FVG TOUCHED] dir=%s | price=%.5f | FVG[%.5f – %.5f]",
      EnumToString(g_FVG.direction), bid, g_FVG.low, g_FVG.high);

  TransitionTo(EA_WAIT_TRIGGER);
}

void OnStateWaitTrigger()
{
  // TODO: Kiểm tra FVG bị phá → ResetToIdle("FVG broken")
  // TODO: barsAlive > InpTriggerMaxBars → ResetToIdle("trigger timeout")
  // TODO: Bar TriggerTF mới → UpdateTriggerContext()
  // TODO: Điều kiện trigger đủ → BuildOrderPlan → ExecuteOrder → EA_IN_TRADE
}

void OnStateInTrade()
{
  if (Bars(_Symbol, InpTriggerTF) <= g_TradeBarIndex) return; // Cùng bar vừa gửi lệnh → bỏ qua

  // TODO: Còn position / pending? Không còn → ResetToIdle("trade closed")
}

//====================================================
// STATE MACHINE
//====================================================

void RunStateMachine()
{
  switch (g_State)
  {
    case EA_IDLE:         OnStateIdle();        break;
    case EA_WAIT_TOUCH:   OnStateWaitTouch();   break;
    case EA_WAIT_TRIGGER: OnStateWaitTrigger(); break;
    case EA_IN_TRADE:     OnStateInTrade();     break;
  }
}

//====================================================
// FVG DRAWING
//
// Rectangle:
//   Cạnh trái  = createdTime (nến phải của pattern = thời điểm FVG confirmed)
//   Cạnh phải  = WAIT_TOUCH  : bar MiddleTF hiện tại (live, cập nhật mỗi tick)
//              = WAIT_TRIGGER: touchTime + 1 bar MiddleTF (cố định sau khi touched)
//   Cạnh trên  = FVG.high
//   Cạnh dưới  = FVG.low
//   Đường giữa = FVG.mid (đứt nét)
//====================================================

void DrawFVGRectangle()
{
  if (!InpDebugDraw) return;

  if (!g_FVG.active)
  {
    ObjectDelete(0, FVG_RECT_NAME);
    ObjectDelete(0, FVG_MID_NAME);
    ObjectDelete(0, FVG_LABEL_NAME);
    return;
  }

  // ── Xác định cạnh phải của rectangle ────────────────────────────────
  datetime rectEnd;

  if (!g_FVG.touched)
  {
    rectEnd = iTime(_Symbol, InpMiddleTF, 0);                              // Live: kéo tới bar hiện tại
  }
  else
  {
    int touchShift = iBarShift(_Symbol, InpMiddleTF, g_FVG.touchTime);
    int nextShift  = MathMax(touchShift - 1, 0);                           // Bar MiddleTF liền sau touch
    rectEnd = iTime(_Symbol, InpMiddleTF, nextShift);                      // Cố định tại n+1
  }

  // ── Màu theo state và chiều ──────────────────────────────────────────
  color rectColor = !g_FVG.touched
    ? (g_FVG.direction == DIR_UP ? C'0,80,160'  : C'140,40,0')            // Đậm khi candidate
    : (g_FVG.direction == DIR_UP ? C'0,160,255' : C'255,100,0');           // Sáng khi touched

  // ── Rectangle ────────────────────────────────────────────────────────
  if (ObjectFind(0, FVG_RECT_NAME) < 0)
    ObjectCreate(0, FVG_RECT_NAME, OBJ_RECTANGLE, 0,
      g_FVG.createdTime, g_FVG.high,
      rectEnd,           g_FVG.low);

  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_COLOR, rectColor);
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_FILL,  true);
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_BACK,  true);
  ObjectSetInteger(0, FVG_RECT_NAME, OBJPROP_WIDTH, 1);
  ObjectMove(0, FVG_RECT_NAME, 0, g_FVG.createdTime, g_FVG.high); // Cạnh trái cố định
  ObjectMove(0, FVG_RECT_NAME, 1, rectEnd,            g_FVG.low);  // Cạnh phải cập nhật

  // ── Đường midpoint (đứt nét) ─────────────────────────────────────────
  if (ObjectFind(0, FVG_MID_NAME) < 0)
    ObjectCreate(0, FVG_MID_NAME, OBJ_TREND, 0,
      g_FVG.createdTime, g_FVG.mid,
      rectEnd,           g_FVG.mid);

  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_COLOR,      clrSilver);
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_STYLE,      STYLE_DOT);
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_WIDTH,      1);
  ObjectSetInteger(0, FVG_MID_NAME, OBJPROP_RAY_RIGHT,  false);
  ObjectMove(0, FVG_MID_NAME, 0, g_FVG.createdTime, g_FVG.mid);
  ObjectMove(0, FVG_MID_NAME, 1, rectEnd,            g_FVG.mid);

  // ── Label ─────────────────────────────────────────────────────────────
  string labelText = StringFormat("FVG %s%s",
    (g_FVG.direction == DIR_UP ? "▲" : "▼"),
    (g_FVG.touched ? " [TOUCHED]" : ""));

  if (ObjectFind(0, FVG_LABEL_NAME) < 0)
    ObjectCreate(0, FVG_LABEL_NAME, OBJ_TEXT, 0,
      g_FVG.createdTime, g_FVG.high);

  ObjectMove(0, FVG_LABEL_NAME, 0, g_FVG.createdTime, g_FVG.high);
  ObjectSetString (0, FVG_LABEL_NAME, OBJPROP_TEXT,    labelText);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_COLOR,   rectColor);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_FONTSIZE, 8);
  ObjectSetInteger(0, FVG_LABEL_NAME, OBJPROP_ANCHOR,  ANCHOR_LEFT_LOWER);
}

//====================================================
// DEBUG DRAW
//====================================================

void DrawContextDebug()
{
  if (!InpDebugDraw) return;

  #define SET_LABEL(name, text, ypos, clr)                            \
    if (ObjectFind(0, name) < 0)                                      \
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);                     \
    ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER); \
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);                 \
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, ypos);               \
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);                  \
    ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);                \
    ObjectSetString (0, name, OBJPROP_TEXT,      text);

  SET_LABEL("DBG_HEADER", "── Context Debug ──", 10, clrSilver)

  // ── BIAS ──────────────────────────────────────────────────────────────
  color biasColor = (g_Bias.bias == BIAS_UP)     ? clrLime   :
                    (g_Bias.bias == BIAS_DOWN)    ? clrTomato :
                    (g_Bias.bias == BIAS_SIDEWAY) ? clrOrange : clrGray;
  SET_LABEL("DBG_BIAS", StringFormat("Bias  : %s", EnumToString(g_Bias.bias)), 30, biasColor)

  if (g_Bias.bias == BIAS_SIDEWAY)
  {
    SET_LABEL("DBG_BIAS_RANGE",
      StringFormat("  Range : %.5f – %.5f", g_Bias.rangeLow, g_Bias.rangeHigh),
      48, clrOrange)
  }
  else
    ObjectDelete(0, "DBG_BIAS_RANGE");

  // ── DAILY RISK ────────────────────────────────────────────────────────
  double lostPct = g_DailyRisk.startBalance > 0
    ? (g_DailyRisk.startBalance - g_DailyRisk.currentBalance)
       / g_DailyRisk.startBalance * 100.0
    : 0.0;

  color riskColor = g_DailyRisk.limitHit              ? clrRed    :
                    lostPct > InpMaxDailyLossPct * 0.7 ? clrOrange : clrLime;

  SET_LABEL("DBG_RISK",  StringFormat("Risk  : %.2f%% / %.2f%%", lostPct, InpMaxDailyLossPct), 66, riskColor)
  SET_LABEL("DBG_BAL",   StringFormat("Bal   : %.2f  (start %.2f)", g_DailyRisk.currentBalance, g_DailyRisk.startBalance), 84, clrSilver)
  SET_LABEL("DBG_LIMIT", g_DailyRisk.limitHit ? "⛔ DAILY LOSS HIT" : "✅ Loss OK", 102, g_DailyRisk.limitHit ? clrRed : clrLime)

  // ── EA STATE ──────────────────────────────────────────────────────────
  color stateColor = (g_State == EA_IDLE)         ? clrSilver :
                     (g_State == EA_WAIT_TOUCH)   ? clrOrange :
                     (g_State == EA_WAIT_TRIGGER) ? clrYellow :
                     (g_State == EA_IN_TRADE)     ? clrLime   : clrGray;
  SET_LABEL("DBG_STATE", StringFormat("State : %s", EnumToString(g_State)), 120, stateColor)

  // ── FVG INFO ──────────────────────────────────────────────────────────
  if (g_FVG.active)
  {
    color fvgColor = g_FVG.touched ? clrDeepSkyBlue : clrDodgerBlue;
    SET_LABEL("DBG_FVG",
      StringFormat("FVG   : %s [%.5f – %.5f]",
        EnumToString(g_FVG.direction), g_FVG.low, g_FVG.high),
      138, fvgColor)
  }
  else
    ObjectDelete(0, "DBG_FVG");

  // ── BLOCK REASON ──────────────────────────────────────────────────────
  if (g_BlockReason != BLOCK_NONE)
  {
    SET_LABEL("DBG_BLOCK",
      StringFormat("Block : %s", EnumToString(g_BlockReason)),
      156, clrTomato)
  }
  else
    ObjectDelete(0, "DBG_BLOCK");

  #undef SET_LABEL

  ChartRedraw(0);
}

void DrawVisuals()
{
  DrawFVGRectangle();
  DrawContextDebug();
}

//====================================================
// EA LIFECYCLE
//====================================================

int OnInit()
{
  ZeroMemory(g_Bias);
  ZeroMemory(g_FVG);
  ZeroMemory(g_Trigger);
  ZeroMemory(g_DailyRisk);

  g_State         = EA_IDLE;
  g_BlockReason   = BLOCK_NONE;
  g_TradeBarIndex = -1;

  UpdateAllContexts();

  PrintFormat("✅ EA initialized | BiasTF=%s | MiddleTF=%s | TriggerTF=%s",
    EnumToString(InpBiasTF), EnumToString(InpMiddleTF), EnumToString(InpTriggerTF));

  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts();

  if (EvaluateGuards())
    RunStateMachine();
  else if (g_State != EA_IDLE)     // Chỉ reset 1 lần khi vừa bị block
    ResetToIdle(EnumToString(g_BlockReason));

  if (InpDebugDraw)
    DrawVisuals();
}

void OnDeinit(const int reason)
{
  ObjectDelete(0, FVG_RECT_NAME);
  ObjectDelete(0, FVG_MID_NAME);
  ObjectDelete(0, FVG_LABEL_NAME);
  ObjectsDeleteAll(0, "DBG_");
  ChartRedraw(0);
  PrintFormat("EA deinitialized | reason=%d", reason);
}
