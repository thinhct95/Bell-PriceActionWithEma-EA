//+------------------------------------------------------------------+
//| SimpleFVG EA – Pure Fair Value Gap Strategy                      |
//|                                                                  |
//| Logic:                                                           |
//|   1. Scan 3-candle pattern: gap between High[i+2] and Low[i]    |
//|   2. Bullish FVG: High(candle1) < Low(candle3) + strong candle2 |
//|   3. Place Buy Limit at FVG upper edge (Low of candle3)         |
//|   4. SL = Low(candle1), TP = entry + 2R                         |
//|   5. Invalidation: close below FVG or timeout                   |
//|                                                                  |
//|   Bearish FVG: mirror logic                                      |
//+------------------------------------------------------------------+
#property copyright "SimpleFVG"
#property version   "1.00"

input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H1;
input double InpRiskPercent             = 1.0;
input double InpRiskReward              = 2.0;
input double InpFVGMinBodyPct           = 50.0;   // body% tối thiểu của nến giữa
input int    InpFVGMaxAgeBars           = 20;      // FVG chưa fill sau N bars → hủy
input int    InpSLBufferPts             = 20;      // buffer thêm cho SL (points)
input double InpEntryDepthPct           = 50.0;    // entry tại X% chiều sâu FVG (0=edge, 50=mid, 100=đáy)
input int    InpEMAPeriod               = 50;      // EMA trend filter trên TF chính
input ENUM_TIMEFRAMES InpHTF            = PERIOD_D1;  // Higher TF confirmation
input int    InpHTFEMAPeriod            = 50;      // EMA period trên HTF
input bool   InpTrailBE                 = true;    // dời SL về entry khi đạt 1R profit
input long   InpMagicNumber             = 20260311;
input int    InpSlippage                = 5;
input bool   InpDebugLog                = true;

//--- Constants ---
const string PFX        = "SFVG_";
const string PFX_ORDER  = "SFVG_ORD_";

//--- EMA handles ---
int g_EMAHandle    = INVALID_HANDLE;
int g_HTFEMAHandle = INVALID_HANDLE;
string g_EMAShortName    = "";
string g_HTFEMAShortName = "";

//--- FVG record ---
struct FVGSlot
{
  bool     active;
  int      direction;   // 1=bullish, -1=bearish
  double   high;        // cạnh trên FVG
  double   low;         // cạnh dưới FVG
  double   slPrice;     // SL level (Low candle1 cho bull, High candle1 cho bear)
  double   entryPrice;  // giá entry thực tế (midpoint hoặc edge tùy InpEntryDepthPct)
  datetime createdTime;
  int      ageBars;
  ulong    ticket;      // ticket lệnh limit đã đặt (0 = chưa đặt)
};

#define MAX_FVG 10

FVGSlot  g_Slots[MAX_FVG];
int      g_SlotCount     = 0;
datetime g_LastBarTime    = 0;
int      g_LastDay        = -1;

//+------------------------------------------------------------------+
//|                    HELPER FUNCTIONS                               |
//+------------------------------------------------------------------+

bool IsNewBar()
{
  datetime t = iTime(_Symbol, InpTimeframe, 0);
  if (t == g_LastBarTime) return false;
  g_LastBarTime = t;
  return true;
}

double GetEMA(int shift)
{
  double buf[1];
  if (g_EMAHandle == INVALID_HANDLE) return 0;
  if (CopyBuffer(g_EMAHandle, 0, shift, 1, buf) < 1) return 0;
  return buf[0];
}

double GetHTFEMA(int shift)
{
  double buf[1];
  if (g_HTFEMAHandle == INVALID_HANDLE) return 0;
  if (CopyBuffer(g_HTFEMAHandle, 0, shift, 1, buf) < 1) return 0;
  return buf[0];
}

/** Kiểm tra cả 2 EMA (TF chính + HTF) đều đồng thuận hướng dir. */
int GetTrendDirection()
{
  double ema  = GetEMA(1);
  double htf  = GetHTFEMA(1);
  double cls  = iClose(_Symbol, InpTimeframe, 1);
  double hCls = iClose(_Symbol, InpHTF, 1);

  if (ema == 0 || htf == 0) return 0;

  bool tfBull  = cls  > ema;
  bool htfBull = hCls > htf;
  bool tfBear  = cls  < ema;
  bool htfBear = hCls < htf;

  if (tfBull && htfBull) return  1;
  if (tfBear && htfBear) return -1;
  return 0;
}

bool IsCandleStrong(int shift)
{
  double h = iHigh (_Symbol, InpTimeframe, shift);
  double l = iLow  (_Symbol, InpTimeframe, shift);
  double o = iOpen (_Symbol, InpTimeframe, shift);
  double c = iClose(_Symbol, InpTimeframe, shift);
  double range = h - l;
  if (range < _Point) return false;
  return (MathAbs(c - o) / range * 100.0) >= InpFVGMinBodyPct;
}

double CalcLot(double entry, double sl)
{
  double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskMoney = balance * InpRiskPercent / 100.0;
  double slDist    = MathAbs(entry - sl) / _Point;
  if (slDist < 1) return 0;

  double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if (tickVal <= 0 || tickSize <= 0) return 0;

  double pipVal = tickVal * (_Point / tickSize);
  double lot    = riskMoney / (slDist * pipVal);

  double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (step <= 0) step = 0.01;

  lot = MathFloor(lot / step) * step;
  lot = MathMax(minL, MathMin(maxL, lot));
  return NormalizeDouble(lot, 2);
}

bool HasPendingOrPosition()
{
  for (int i = OrdersTotal() - 1; i >= 0; i--)
  {
    ulong ticket = OrderGetTicket(i);
    if (ticket > 0
        && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber
        && OrderGetString(ORDER_SYMBOL) == _Symbol)
      return true;
  }
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong ticket = PositionGetTicket(i);
    if (ticket > 0
        && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
        && PositionGetString(POSITION_SYMBOL) == _Symbol)
      return true;
  }
  return false;
}

//+------------------------------------------------------------------+
//|                    FVG SCANNING                                   |
//+------------------------------------------------------------------+

void ScanFVGs()
{
  int trendDir = GetTrendDirection();

  int maxBar = MathMin(InpFVGMaxAgeBars + 5, Bars(_Symbol, InpTimeframe) - 3);

  for (int i = 1; i <= maxBar; i++)
  {
    double c1High = iHigh (_Symbol, InpTimeframe, i + 2);
    double c1Low  = iLow  (_Symbol, InpTimeframe, i + 2);
    double c2Open = iOpen (_Symbol, InpTimeframe, i + 1);
    double c2Close= iClose(_Symbol, InpTimeframe, i + 1);
    double c3High = iHigh (_Symbol, InpTimeframe, i);
    double c3Low  = iLow  (_Symbol, InpTimeframe, i);

    datetime fvgTime = iTime(_Symbol, InpTimeframe, i);

    bool alreadyExists = false;
    for (int j = 0; j < g_SlotCount; j++)
      if (g_Slots[j].active && g_Slots[j].createdTime == fvgTime)
        { alreadyExists = true; break; }
    if (alreadyExists) continue;

    // --- Bullish FVG: chỉ khi trend = +1 ---
    if (trendDir >= 1 && c1High < c3Low
        && c2Close > c2Open && IsCandleStrong(i + 1))
    {
      if (g_SlotCount >= MAX_FVG) continue;
      double fvgH = c3Low;
      double fvgL = c1High;
      double depth = (fvgH - fvgL) * InpEntryDepthPct / 100.0;
      double entry = NormalizeDouble(fvgH - depth, _Digits);

      ZeroMemory(g_Slots[g_SlotCount]);
      g_Slots[g_SlotCount].active      = true;
      g_Slots[g_SlotCount].direction   = 1;
      g_Slots[g_SlotCount].high        = fvgH;
      g_Slots[g_SlotCount].low         = fvgL;
      g_Slots[g_SlotCount].slPrice     = c1Low;
      g_Slots[g_SlotCount].entryPrice  = entry;
      g_Slots[g_SlotCount].createdTime = fvgTime;
      g_Slots[g_SlotCount].ageBars     = 0;
      g_Slots[g_SlotCount].ticket      = 0;
      g_SlotCount++;

      if (InpDebugLog)
        PrintFormat("[FVG+] BULL [%.5f–%.5f] entry=%.5f SL=%.5f trend=%d | %s",
          fvgL, fvgH, entry, c1Low, trendDir, TimeToString(fvgTime));
    }

    // --- Bearish FVG: chỉ khi trend = -1 ---
    if (trendDir <= -1 && c1Low > c3High
        && c2Close < c2Open && IsCandleStrong(i + 1))
    {
      if (g_SlotCount >= MAX_FVG) continue;
      double fvgH = c1Low;
      double fvgL = c3High;
      double depth = (fvgH - fvgL) * InpEntryDepthPct / 100.0;
      double entry = NormalizeDouble(fvgL + depth, _Digits);

      ZeroMemory(g_Slots[g_SlotCount]);
      g_Slots[g_SlotCount].active      = true;
      g_Slots[g_SlotCount].direction   = -1;
      g_Slots[g_SlotCount].high        = fvgH;
      g_Slots[g_SlotCount].low         = fvgL;
      g_Slots[g_SlotCount].slPrice     = c1High;
      g_Slots[g_SlotCount].entryPrice  = entry;
      g_Slots[g_SlotCount].createdTime = fvgTime;
      g_Slots[g_SlotCount].ageBars     = 0;
      g_Slots[g_SlotCount].ticket      = 0;
      g_SlotCount++;

      if (InpDebugLog)
        PrintFormat("[FVG+] BEAR [%.5f–%.5f] entry=%.5f SL=%.5f trend=%d | %s",
          fvgL, fvgH, entry, c1High, trendDir, TimeToString(fvgTime));
    }
  }
}

//+------------------------------------------------------------------+
//|                    ORDER MANAGEMENT                              |
//+------------------------------------------------------------------+

void PlaceLimitForSlot(int idx)
{
  if (g_Slots[idx].ticket != 0) return;
  if (HasPendingOrPosition()) return;

  double entry, sl, tp;
  ENUM_ORDER_TYPE orderType;

  if (g_Slots[idx].direction > 0)
  {
    entry     = NormalizeDouble(g_Slots[idx].entryPrice, _Digits);
    sl        = NormalizeDouble(g_Slots[idx].slPrice - InpSLBufferPts * _Point, _Digits);
    double rD = entry - sl;
    if (rD <= 0) return;
    tp        = NormalizeDouble(entry + InpRiskReward * rD, _Digits);
    orderType = ORDER_TYPE_BUY_LIMIT;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if (entry >= ask) return;
  }
  else
  {
    entry     = NormalizeDouble(g_Slots[idx].entryPrice, _Digits);
    sl        = NormalizeDouble(g_Slots[idx].slPrice + InpSLBufferPts * _Point, _Digits);
    double rD = sl - entry;
    if (rD <= 0) return;
    tp        = NormalizeDouble(entry - InpRiskReward * rD, _Digits);
    orderType = ORDER_TYPE_SELL_LIMIT;

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if (entry <= bid) return;
  }

  double lot = CalcLot(entry, sl);
  if (lot <= 0) return;

  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);

  req.action       = TRADE_ACTION_PENDING;
  req.symbol       = _Symbol;
  req.volume       = lot;
  req.type         = orderType;
  req.price        = entry;
  req.sl           = sl;
  req.tp           = tp;
  req.deviation    = (ulong)InpSlippage;
  req.magic        = InpMagicNumber;
  req.comment      = StringFormat("FVG_%s", TimeToString(g_Slots[idx].createdTime, TIME_DATE));
  req.type_filling = ORDER_FILLING_RETURN;
  req.type_time    = ORDER_TIME_GTC;

  if (!OrderSend(req, res))
  {
    PrintFormat("[ORDER] ❌ retcode=%u", res.retcode);
    return;
  }
  if (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
  {
    PrintFormat("[ORDER] ❌ rejected %u: %s", res.retcode, res.comment);
    return;
  }

  g_Slots[idx].ticket = res.order;
  PrintFormat("[ORDER] ✅ %s #%llu | %.2f @ %.5f SL=%.5f TP=%.5f",
    (g_Slots[idx].direction > 0) ? "BUY_LIM" : "SELL_LIM",
    res.order, lot, entry, sl, tp);
}

bool IsTicketStillPending(ulong ticket)
{
  for (int i = OrdersTotal() - 1; i >= 0; i--)
    if (OrderGetTicket(i) == ticket) return true;
  return false;
}

void CancelOrder(ulong ticket)
{
  MqlTradeRequest req;
  MqlTradeResult  res;
  ZeroMemory(req);
  ZeroMemory(res);
  req.action = TRADE_ACTION_REMOVE;
  req.order  = ticket;
  if (OrderSend(req, res))
  {
    if (InpDebugLog)
      PrintFormat("[CANCEL] #%llu removed", ticket);
  }
}

//+------------------------------------------------------------------+
//|                    TRAILING SL (BREAKEVEN)                       |
//+------------------------------------------------------------------+

/** Dời SL về entry khi profit đạt 1R. Gọi mỗi tick. */
void TrailBreakeven()
{
  if (!InpTrailBE) return;

  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0) continue;
    if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double curSL     = PositionGetDouble(POSITION_SL);
    double curTP     = PositionGetDouble(POSITION_TP);
    bool   isBuy     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

    double slDist = MathAbs(openPrice - curSL);
    if (slDist < _Point) continue;

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    bool alreadyBE = isBuy ? (curSL >= openPrice) : (curSL <= openPrice);
    if (alreadyBE) continue;

    double profit1R = isBuy ? (openPrice + slDist) : (openPrice - slDist);
    bool   reached  = isBuy ? (bid >= profit1R) : (ask <= profit1R);
    if (!reached) continue;

    double newSL = NormalizeDouble(openPrice + (isBuy ? 1 : -1) * _Point, _Digits);

    MqlTradeRequest req;
    MqlTradeResult  res;
    ZeroMemory(req);
    ZeroMemory(res);
    req.action   = TRADE_ACTION_SLTP;
    req.position = ticket;
    req.symbol   = _Symbol;
    req.sl       = newSL;
    req.tp       = curTP;

    if (OrderSend(req, res))
    {
      if (InpDebugLog)
        PrintFormat("[TRAIL] #%llu SL moved to breakeven %.5f", ticket, newSL);
    }
  }
}

//+------------------------------------------------------------------+
//|                    DAILY RESET                                   |
//+------------------------------------------------------------------+

/** Hủy tất cả pending limits + slots khi sang ngày mới. */
void DailyReset()
{
  MqlDateTime now;
  TimeCurrent(now);
  if (now.day == g_LastDay) return;
  g_LastDay = now.day;

  int cancelled = 0;
  for (int i = g_SlotCount - 1; i >= 0; i--)
  {
    if (!g_Slots[i].active) continue;
    if (g_Slots[i].ticket != 0 && IsTicketStillPending(g_Slots[i].ticket))
    {
      CancelOrder(g_Slots[i].ticket);
      cancelled++;
    }
    g_Slots[i].active = false;
  }

  int writeIdx = 0;
  for (int i = 0; i < g_SlotCount; i++)
  {
    if (g_Slots[i].active)
    {
      if (writeIdx != i) g_Slots[writeIdx] = g_Slots[i];
      writeIdx++;
    }
  }
  g_SlotCount = writeIdx;

  if (InpDebugLog && cancelled > 0)
    PrintFormat("[DAILY] New day %04d.%02d.%02d → cancelled %d pending orders, cleared slots",
      now.year, now.mon, now.day, cancelled);
}

//+------------------------------------------------------------------+
//|                    SLOT UPDATE & INVALIDATION                    |
//+------------------------------------------------------------------+

void UpdateSlots()
{
  double lastClose = iClose(_Symbol, InpTimeframe, 1);

  for (int i = g_SlotCount - 1; i >= 0; i--)
  {
    if (!g_Slots[i].active) continue;

    g_Slots[i].ageBars++;

    // Invalidation 1: close hoàn toàn bên ngoài FVG → hủy
    bool invalidated = false;
    if (g_Slots[i].direction > 0 && lastClose < g_Slots[i].low)
      invalidated = true;
    if (g_Slots[i].direction < 0 && lastClose > g_Slots[i].high)
      invalidated = true;

    // Invalidation 2: timeout
    if (g_Slots[i].ageBars > InpFVGMaxAgeBars)
      invalidated = true;

    // Invalidation 3: limit đã fill → position mở → slot hoàn thành
    if (g_Slots[i].ticket != 0 && !IsTicketStillPending(g_Slots[i].ticket))
    {
      g_Slots[i].active = false;
      if (InpDebugLog)
        PrintFormat("[SLOT] #%llu filled or gone → deactivate", g_Slots[i].ticket);
      continue;
    }

    if (invalidated)
    {
      if (g_Slots[i].ticket != 0 && IsTicketStillPending(g_Slots[i].ticket))
        CancelOrder(g_Slots[i].ticket);
      g_Slots[i].active = false;
      if (InpDebugLog)
        PrintFormat("[SLOT] %s FVG [%.5f–%.5f] invalidated | age=%d",
          (g_Slots[i].direction > 0) ? "BULL" : "BEAR",
          g_Slots[i].low, g_Slots[i].high, g_Slots[i].ageBars);
      continue;
    }

    // Chưa đặt lệnh → đặt limit
    if (g_Slots[i].ticket == 0)
      PlaceLimitForSlot(i);
  }

  // Dọn slots không active
  int writeIdx = 0;
  for (int i = 0; i < g_SlotCount; i++)
  {
    if (g_Slots[i].active)
    {
      if (writeIdx != i) g_Slots[writeIdx] = g_Slots[i];
      writeIdx++;
    }
  }
  g_SlotCount = writeIdx;
}

//+------------------------------------------------------------------+
//|                    DRAWING                                        |
//+------------------------------------------------------------------+

void SetRect(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  ObjectSetInteger(0, name, OBJPROP_FILL,  true);
  ObjectSetInteger(0, name, OBJPROP_BACK,  true);
  ObjectMove(0, name, 0, t1, p1);
  ObjectMove(0, name, 1, t2, p2);
}

void SetHLine(string name, datetime t1, double p, datetime t2, color clr, int style, int width)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_TREND, 0, t1, p, t2, p);
  ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
  ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
  ObjectSetInteger(0, name, OBJPROP_WIDTH,     width);
  ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
  ObjectMove(0, name, 0, t1, p);
  ObjectMove(0, name, 1, t2, p);
}

void SetLabel(string name, int x, int y, string txt, color clr, int fontSize)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
  ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
  ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
  ObjectSetString (0, name, OBJPROP_TEXT,      txt);
}

void SetText(string name, datetime t, double p, string txt, color clr, int fontSize, int anchor)
{
  if (ObjectFind(0, name) < 0)
    ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
  ObjectMove(0, name, 0, t, p);
  ObjectSetString (0, name, OBJPROP_TEXT,     txt);
  ObjectSetInteger(0, name, OBJPROP_COLOR,    clr);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
  ObjectSetInteger(0, name, OBJPROP_ANCHOR,   anchor);
}

void DrawFVGZones()
{
  ObjectsDeleteAll(0, PFX + "FVG_");

  datetime now = iTime(_Symbol, InpTimeframe, 0);

  for (int i = 0; i < g_SlotCount; i++)
  {
    if (!g_Slots[i].active) continue;

    string sid  = IntegerToString(i);
    bool isBull = (g_Slots[i].direction > 0);
    color zClr  = isBull ? C'0,60,120' : C'100,25,0';
    color bClr  = isBull ? C'0,120,200' : C'200,60,0';

    SetRect(PFX + "FVG_Z_" + sid,
      g_Slots[i].createdTime, g_Slots[i].high,
      now, g_Slots[i].low, zClr);

    SetHLine(PFX + "FVG_E_" + sid,
      g_Slots[i].createdTime, g_Slots[i].entryPrice, now,
      C'200,200,0', STYLE_DOT, 1);

    SetText(PFX + "FVG_L_" + sid,
      g_Slots[i].createdTime, g_Slots[i].high,
      StringFormat("FVG %s [%.3f–%.3f] ent=%.3f",
        isBull ? "▲" : "▼", g_Slots[i].low, g_Slots[i].high, g_Slots[i].entryPrice),
      bClr, 7, ANCHOR_LEFT_LOWER);
  }
}

void DrawOrderVisual()
{
  string entN = PFX_ORDER + "ENT";
  string slN  = PFX_ORDER + "SLL";
  string tpN  = PFX_ORDER + "TPL";
  string tpZ  = PFX_ORDER + "TPZ";
  string slZ  = PFX_ORDER + "SLZ";
  string eL   = PFX_ORDER + "ELBL";
  string sL   = PFX_ORDER + "SLBL";
  string tL   = PFX_ORDER + "TPLBL";

  // Tìm slot có lệnh pending
  int activeIdx = -1;
  for (int i = 0; i < g_SlotCount; i++)
  {
    if (g_Slots[i].active && g_Slots[i].ticket != 0)
      { activeIdx = i; break; }
  }

  if (activeIdx < 0)
  {
    ObjectDelete(0, entN); ObjectDelete(0, slN); ObjectDelete(0, tpN);
    ObjectDelete(0, tpZ);  ObjectDelete(0, slZ);
    ObjectDelete(0, eL);   ObjectDelete(0, sL);  ObjectDelete(0, tL);
    return;
  }

  bool isBull = (g_Slots[activeIdx].direction > 0);
  double entry, sl, tp;

  if (isBull)
  {
    entry = g_Slots[activeIdx].entryPrice;
    sl    = NormalizeDouble(g_Slots[activeIdx].slPrice - InpSLBufferPts * _Point, _Digits);
    double rD = entry - sl;
    if (rD <= 0) return;
    tp    = NormalizeDouble(entry + InpRiskReward * rD, _Digits);
  }
  else
  {
    entry = g_Slots[activeIdx].entryPrice;
    sl    = NormalizeDouble(g_Slots[activeIdx].slPrice + InpSLBufferPts * _Point, _Digits);
    double rD = sl - entry;
    if (rD <= 0) return;
    tp    = NormalizeDouble(entry - InpRiskReward * rD, _Digits);
  }

  datetime tStart = g_Slots[activeIdx].createdTime;
  datetime tEnd   = iTime(_Symbol, InpTimeframe, 0) + PeriodSeconds(InpTimeframe) * 8;

  color entClr = isBull ? C'33,150,243' : C'255,152,0';
  color tpClr  = C'38,166,91';
  color slClr  = C'229,57,53';

  double tpTop = isBull ? tp    : entry;
  double tpBot = isBull ? entry : tp;
  SetRect(tpZ, tStart, tpTop, tEnd, tpBot, C'15,60,30');

  double slTop = isBull ? entry : sl;
  double slBot = isBull ? sl    : entry;
  SetRect(slZ, tStart, slTop, tEnd, slBot, C'75,12,12');

  SetHLine(entN, tStart, entry, tEnd, entClr, STYLE_SOLID, 2);
  SetHLine(tpN,  tStart, tp,   tEnd, tpClr,  STYLE_DASH,  1);
  SetHLine(slN,  tStart, sl,   tEnd, slClr,  STYLE_DASH,  1);

  datetime lblT = tEnd + PeriodSeconds(InpTimeframe);
  double slPips = MathAbs(entry - sl) / _Point;
  double tpPips = MathAbs(tp - entry) / _Point;
  double rr     = (slPips > 0) ? tpPips / slPips : 0;
  double lot    = CalcLot(entry, sl);

  SetText(eL, lblT, entry,
    StringFormat("%s %.3f | %.2f lot", isBull ? "BUY LIM" : "SELL LIM", entry, lot),
    entClr, 8, ANCHOR_LEFT);
  SetText(tL, lblT, tp,
    StringFormat("TP %.3f | +%.0fp (%.1fR)", tp, tpPips, rr),
    tpClr, 7, isBull ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
  SetText(sL, lblT, sl,
    StringFormat("SL %.3f | -%.0fp", sl, slPips),
    slClr, 7, isBull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
}

void DrawDebugPanel()
{
  int pending = 0, total = 0;
  for (int i = 0; i < g_SlotCount; i++)
    if (g_Slots[i].active) { total++; if (g_Slots[i].ticket != 0) pending++; }

  bool inPos = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
  {
    ulong t = PositionGetTicket(i);
    if (t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber
        && PositionGetString(POSITION_SYMBOL) == _Symbol)
      { inPos = true; break; }
  }

  int trendDir = GetTrendDirection();
  string trendTxt = (trendDir > 0) ? "BULL" : (trendDir < 0) ? "BEAR" : "NEUTRAL";
  color  trendClr = (trendDir > 0) ? clrLime : (trendDir < 0) ? clrTomato : clrGray;

  double ema    = GetEMA(1);
  double htfEma = GetHTFEMA(1);

  SetLabel(PFX + "HDR", 10, 20,
    StringFormat("SimpleFVG v2 | %s | Slots=%d Pend=%d | Trail=%s",
      EnumToString(InpTimeframe), total, pending, InpTrailBE ? "ON" : "OFF"),
    clrSilver, 9);

  SetLabel(PFX + "TRD", 10, 44,
    StringFormat("Trend: %s | EMA%.0f=%.3f | HTF EMA%.0f=%.3f",
      trendTxt, (double)InpEMAPeriod, ema, (double)InpHTFEMAPeriod, htfEma),
    trendClr, 9);

  color sClr = inPos ? clrLime : (pending > 0) ? clrOrange : clrGray;
  string sTxt = inPos ? "IN TRADE" : (pending > 0) ? "LIMIT PLACED" : "SCANNING";
  SetLabel(PFX + "ST", 10, 68, StringFormat("State: %s", sTxt), sClr, 9);
}

void DrawAll()
{
  DrawFVGZones();
  DrawOrderVisual();
  DrawDebugPanel();
  ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|                    EVENT HANDLERS                                 |
//+------------------------------------------------------------------+

int OnInit()
{
  g_EMAHandle = iMA(_Symbol, InpTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
  if (g_EMAHandle == INVALID_HANDLE)
  {
    Print("[INIT] Failed to create EMA handle");
    return INIT_FAILED;
  }
  ChartIndicatorAdd(0, 0, g_EMAHandle);
  int n1 = ChartIndicatorsTotal(0, 0);
  if (n1 > 0) g_EMAShortName = ChartIndicatorName(0, 0, n1 - 1);

  g_HTFEMAHandle = iMA(_Symbol, InpHTF, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
  if (g_HTFEMAHandle == INVALID_HANDLE)
  {
    Print("[INIT] Failed to create HTF EMA handle");
    return INIT_FAILED;
  }

  for (int i = 0; i < MAX_FVG; i++) ZeroMemory(g_Slots[i]);
  g_SlotCount   = 0;
  g_LastBarTime = 0;

  ScanFVGs();
  DrawAll();

  if (InpDebugLog)
    PrintFormat("[INIT] SimpleFVG v2 | TF=%s HTF=%s | EMA=%d/%d | R=%.1f%% RR=%.1f | DepthPct=%.0f%% Trail=%s",
      EnumToString(InpTimeframe), EnumToString(InpHTF),
      InpEMAPeriod, InpHTFEMAPeriod,
      InpRiskPercent, InpRiskReward,
      InpEntryDepthPct, InpTrailBE ? "ON" : "OFF");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  if (g_EMAShortName != "")
    ChartIndicatorDelete(0, 0, g_EMAShortName);
  if (g_EMAHandle != INVALID_HANDLE)
    IndicatorRelease(g_EMAHandle);
  if (g_HTFEMAHandle != INVALID_HANDLE)
    IndicatorRelease(g_HTFEMAHandle);

  ObjectsDeleteAll(0, PFX);
  ObjectsDeleteAll(0, PFX_ORDER);
  ChartRedraw(0);
}

void OnTick()
{
  DailyReset();
  TrailBreakeven();

  if (IsNewBar())
  {
    ScanFVGs();
    UpdateSlots();
  }
  DrawAll();
}
