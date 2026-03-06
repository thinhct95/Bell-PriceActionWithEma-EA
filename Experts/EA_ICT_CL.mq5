//+------------------------------------------------------------------+
//| ICT EA – FVG Edition                                             |
//| Architecture: 3 TF | 4 State Machine                            |
//+------------------------------------------------------------------+
#property strict

//====================================================
// INPUTS
//====================================================

input ENUM_TIMEFRAMES InpBiasTF     = PERIOD_D1;   // Bias Timeframe
input ENUM_TIMEFRAMES InpMiddleTF   = PERIOD_H1;   // Middle TF – nơi quét FVG
input ENUM_TIMEFRAMES InpTriggerTF  = PERIOD_M5;   // Trigger TF – xác nhận vào lệnh

input double InpRiskPercent         = 1.0;
input double InpRiskReward          = 2.0;
input double InpMaxDailyLossPct     = 3.0;

input int    InpLondonStartHour     = 8;
input int    InpLondonEndHour       = 17;
input int    InpNYStartHour         = 13;
input int    InpNYEndHour           = 22;
input int    InpSessionAvoidLastMin = 60;

input int    InpFVGMaxAliveMin      = 180;  // FVG sống tối đa bao nhiêu phút
input int    InpTriggerMaxBars      = 30;   // Số bar TriggerTF chờ sau khi touched

input bool   InpDebugLog            = true;
input bool   InpDebugDraw           = true;

//====================================================
// ENUMS
//====================================================

enum EAState
{
  EA_IDLE,          // Chờ điều kiện: bias + structure + FVG candidate
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

// --- Bias từ Bias TF (D1)
struct BiasContext
{
  HTFBias  bias;
  double   rangeHigh;    // Dùng khi sideway
  double   rangeLow;
  datetime lastBarTime;  // Guard: chỉ update khi bar mới
};

// --- FVG đang theo dõi (quét từ Middle TF)
struct FVGContext
{
  bool      active;      // Đang có FVG candidate
  bool      touched;     // Price đã chạm vào FVG chưa

  MarketDir direction;   // FVG thuận chiều bias
  double    high;        // Cạnh trên FVG
  double    low;         // Cạnh dưới FVG
  double    mid;         // Midpoint – dùng làm entry tham chiếu

  datetime  createdTime; // Thời điểm FVG hình thành
  datetime  touchTime;   // Thời điểm price chạm lần đầu

  int       barsAlive;   // Số bar TriggerTF đã qua kể từ touched
  int       touchBarIdx; // Bar index TriggerTF lúc touched
};

// --- Structure của Trigger TF (sau khi FVG touched)
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

// --- Kế hoạch lệnh
struct OrderPlan
{
  bool   valid;
  int    direction;
  double entry;
  double stopLoss;
  double takeProfit;
  double lot;
};

// --- Risk quản lý theo ngày
struct DailyRiskContext
{
  double   startBalance;
  datetime dayStartTime;
  bool     limitHit;
};

//====================================================
// GLOBAL STATE
//====================================================

EAState         g_State       = EA_IDLE;
BlockReason     g_BlockReason = BLOCK_NONE;

BiasContext     g_Bias;
FVGContext      g_FVG;
TriggerContext  g_Trigger;
DailyRiskContext g_DailyRisk;

int             g_TradeBarIndex = -1;

//====================================================
// CONTEXT UPDATERS
// Mỗi hàm có guard – chỉ chạy khi bar mới
//====================================================

HTFBias ResolveBias(
  double b1High,  double b1Low,  double b1Close,
  double b2High,  double b2Low)
{
  // ── Rule 1: Breakout lên trên ──────────────────
  if (b1Close > b2High)
    return BIAS_UP;

  // ── Rule 2: Breakout xuống dưới ───────────────
  if (b1Close < b2Low)
    return BIAS_DOWN;

  // ── Rule 3: Sweep high → reject xuống ─────────
  //    Wick lên trên bar2 nhưng close quay lại bên trong
  if (b1High > b2High && b1Close < b2High)
    return BIAS_DOWN;

  // ── Rule 4: Sweep low → recover lên ───────────
  //    Wick xuống dưới bar2 nhưng close quay lại bên trong
  if (b1Low < b2Low && b1Close > b2Low)
    return BIAS_UP;

  // ── Rule 5: Còn lại → sideway ─────────────────
  return BIAS_SIDEWAY;
}

void UpdateBiasContext()
{
  // Guard: chỉ update khi bar BiasTF mới hình thành
  datetime currentBarTime = iTime(_Symbol, InpBiasTF, 0);
  if (currentBarTime == g_Bias.lastBarTime)
    return;

  g_Bias.lastBarTime = currentBarTime;

  // Đảm bảo đủ data
  if (Bars(_Symbol, InpBiasTF) < 4)
  {
    g_Bias.bias = BIAS_NONE;
    return;
  }

  double b1High  = iHigh (_Symbol, InpBiasTF, 1);
  double b1Low   = iLow  (_Symbol, InpBiasTF, 1);
  double b1Close = iClose(_Symbol, InpBiasTF, 1);
  double b2High  = iHigh (_Symbol, InpBiasTF, 2);
  double b2Low   = iLow  (_Symbol, InpBiasTF, 2);

  HTFBias prevBias = g_Bias.bias;
  g_Bias.bias      = ResolveBias(b1High, b1Low, b1Close, b2High, b2Low);

  // Reset range (chỉ dùng khi sideway)
  g_Bias.rangeHigh = (g_Bias.bias == BIAS_SIDEWAY) ? b2High : 0;
  g_Bias.rangeLow  = (g_Bias.bias == BIAS_SIDEWAY) ? b2Low  : 0;

  if (InpDebugLog && g_Bias.bias != prevBias)
    PrintFormat("[BIAS] %s → %s | b1[H=%.5f L=%.5f C=%.5f] b2[H=%.5f L=%.5f]",
      EnumToString(prevBias),
      EnumToString(g_Bias.bias),
      b1High, b1Low, b1Close,
      b2High, b2Low);
}

void UpdateDailyRiskContext()
{
  datetime todayBarTime = iTime(_Symbol, PERIOD_D1, 0);  // "ID" của ngày hôm nay – thay đổi khi sang ngày mới

  if (todayBarTime != g_DailyRisk.dayStartTime)          // Bar D1 mới = sang ngày giao dịch mới
  {
    g_DailyRisk.dayStartTime = todayBarTime;             // Cập nhật mốc ngày
    g_DailyRisk.startBalance = AccountInfoDouble(ACCOUNT_BALANCE); // Chụp balance đầu ngày (dùng BALANCE, không phải EQUITY – loại trừ floating P&L)
    g_DailyRisk.limitHit     = false;                    // Reset cờ – cho phép trade ngày mới

    if (InpDebugLog)
      PrintFormat("[DAILY RISK] New day | startBalance=%.2f", g_DailyRisk.startBalance);
  }

  if (g_DailyRisk.limitHit)                             // Đã hit rồi → không tính lại, tránh gọi AccountInfoDouble() vô ích mỗi tick
    return;

  double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double lostPct = (g_DailyRisk.startBalance - currentBalance)
                    / g_DailyRisk.startBalance * 100.0; // VD: start=10000, now=9700 → lostPct=3.0%

  if (lostPct >= InpMaxDailyLossPct)                    // Vượt ngưỡng → khóa EA cả ngày hôm nay
  {
    g_DailyRisk.limitHit = true;                        // IsDailyLossOK() = false → EvaluateGuards() fail → ResetToIdle()

    PrintFormat("[DAILY RISK] ⛔ Limit hit | lost=%.2f%% | limit=%.2f%% | balance=%.2f",
      lostPct,
      InpMaxDailyLossPct,
      currentBalance);
  }
}

void UpdateAllContexts()
{
  UpdateDailyRiskContext();
  UpdateBiasContext();
  // Không có StructureContext riêng nữa
  // Structure check sẽ nằm trong từng state handler khi cần
}

//====================================================
// GUARDS
//====================================================

bool IsSessionAllowed()
{
  return true; // TODO
}

bool IsDailyLossOK()
{
  return !g_DailyRisk.limitHit;
}

bool IsBiasValid()
{
  return g_Bias.bias == BIAS_UP || g_Bias.bias == BIAS_DOWN;
}

bool EvaluateGuards()
{
  g_BlockReason = BLOCK_NONE;

  if (!IsSessionAllowed())  { g_BlockReason = BLOCK_SESSION;       return false; }
  if (!IsDailyLossOK())     { g_BlockReason = BLOCK_DAILY_LOSS;    return false; }
  if (!IsBiasValid())       { g_BlockReason = BLOCK_NO_BIAS;       return false; }

  return true;
}

//====================================================
// TRANSITIONS
//====================================================

void TransitionTo(EAState next)
{
  if (InpDebugLog)
    PrintFormat("[STATE] %s → %s",
      EnumToString(g_State),
      EnumToString(next));

  g_State = next;
}

void ResetToIdle(string reason = "")
{
  if (InpDebugLog && reason != "")
    PrintFormat("[RESET] %s", reason);

  ZeroMemory(g_FVG);
  ZeroMemory(g_Trigger);
  g_TradeBarIndex = -1;

  TransitionTo(EA_IDLE);
}

//====================================================
// STATE HANDLERS
//====================================================

void OnStateIdle()
{
  // Điều kiện: bias phải rõ (UP hoặc DOWN)
  // TODO: Quét Middle TF tìm FVG candidate khớp với bias
  //       Nếu tìm được FVG hợp lệ:
  //         → g_FVG = <FVG vừa tìm>
  //         → g_FVG.active = true
  //         → TransitionTo(EA_WAIT_TOUCH)
}

void OnStateWaitTouch()
{
  // TODO: Kiểm tra FVG còn hợp lệ không
  //       - Expired (quá InpFVGMaxAliveMin)?
  //       - Bị invalidate (price close xuyên qua FVG ngược chiều)?
  //       → ResetToIdle()

  // TODO: Kiểm tra price có nằm trong vùng FVG không
  //       Nếu có:
  //         → g_FVG.touched = true
  //         → g_FVG.touchTime = now
  //         → g_FVG.touchBarIdx = <bar hiện tại trên TriggerTF>
  //         → TransitionTo(EA_WAIT_TRIGGER)
}

void OnStateWaitTrigger()
{
  // TODO: Kiểm tra FVG có bị phá không → ResetToIdle()

  // TODO: Đếm barsAlive, nếu > InpTriggerMaxBars → ResetToIdle()

  // TODO: Mỗi bar mới của TriggerTF:
  //       → UpdateTriggerContext()

  // TODO: Kiểm tra điều kiện trigger (vd: structure break trên TriggerTF)
  //       Nếu đủ:
  //         → plan = BuildOrderPlan()
  //         → ExecuteOrder(plan)
  //         → g_TradeBarIndex = Bars(_Symbol, InpTriggerTF)
  //         → TransitionTo(EA_IN_TRADE)
}

void OnStateInTrade()
{
  // Không xử lý trong cùng bar vừa gửi lệnh
  if (Bars(_Symbol, InpTriggerTF) <= g_TradeBarIndex)
    return;

  // TODO: Kiểm tra position còn sống không
  //       (PositionSelect hoặc OrdersTotal)
  //       Nếu lệnh đã đóng → ResetToIdle()
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
// DRAW (stub)
//====================================================

void DrawVisuals() { /* TODO */ }

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

  // Chạy update ngay lần đầu để có data sẵn
  UpdateAllContexts();

  PrintFormat("✅ EA initialized | BiasTF=%s | MiddleTF=%s | TriggerTF=%s",
    EnumToString(InpBiasTF),
    EnumToString(InpMiddleTF),
    EnumToString(InpTriggerTF));

  return INIT_SUCCEEDED;
}

void OnTick()
{
  UpdateAllContexts();

  if (EvaluateGuards())
    RunStateMachine();
  else
    ResetToIdle(EnumToString(g_BlockReason));

  if (InpDebugDraw)
    DrawVisuals();
}

void OnDeinit(const int reason)
{
  // TODO: ObjectsDeleteAll hoặc xóa từng object đã vẽ
  PrintFormat("EA deinitialized | reason=%d", reason);
}
