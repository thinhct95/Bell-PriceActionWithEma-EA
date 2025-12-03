//+------------------------------------------------------------------+
//| EA ICT-style: Daily Bias -> H1 FVG -> M5 pullback entries         |
//| - Xác định Daily bias theo yêu cầu của bạn                        |
//| - Tìm FVG trên H1 thuận chiều với daily bias (phương pháp đơn giản)
//| - Khi giá hồi về H1 FVG, chuyển xuống M5: tìm M5 FVG + MSS (đơn giản)
//| - Đặt BuyLimit / SellLimit tại M5 FVG, SL tính theo đáy/đỉnh pullback
//| - Lot được tính sao cho rủi ro entry->SL = 1% equity (tùy biến RiskPerTrade)
//| - TP = entry + 3 * (entry - SL) (R:R = 1:3)
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//--- Inputs
input double RiskPerTrade = 1.0;        // % equity risk per trade (mặc định 1%)
input int    MagicNumber   = 33333;
input int    H1_FVG_lookback = 200;     // bars to scan for H1 FVG
input int    M5_lookback = 200;         // bars to scan for M5 FVG/MSS
input double MinADX = 10.0;             // optional ADX filter (không bắt buộc)
input int    ADXPeriod = 14;
input double MaxAcceptableSpread = 200; // points
input double RR = 3.0;               // Risk:Reward multiplier (TP = RR * risk distance) // points

//--- Internal structs
struct Zone { double top; double bottom; int from_index; int to_index; };

enum DailyBias { BIAS_UNKNOWN=0, BIAS_UP=1, BIAS_DOWN=-1 };

//--- Utility forward declarations
DailyBias DetermineDailyBias();
int    FindH1FVGs(DailyBias bias, Zone &foundZone);
int    FindM5FVGAtZone(Zone &h1zone, DailyBias bias, Zone &m5zone);
bool   DetectM5MSS(int &mssType, double &mssPrice); // returns 1 for bullish MSS (break to upside), -1 for bearish
double CalculateLotForRisk(double entryPrice, double stopPrice);
void   PlaceLimitOrder(int side, double price, double sl, double tp, double lot);

//+------------------------------------------------------------------+
int OnInit()
{
  Print("EA ICT-style initialized");
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
  // chỉ xử lý trên M5 khi có bar mới
  static datetime lastBarTime=0;
  datetime t = iTime(_Symbol, PERIOD_M5, 0);
  if(t==lastBarTime) return;
  lastBarTime = t;

  // spread check
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
  double spreadPts = (ask-bid)/point;
  if(spreadPts > MaxAcceptableSpread) { PrintFormat("Spread too high: %.1f pts", spreadPts); return; }

  // 1) xác định daily bias
  DailyBias bias = DetermineDailyBias();
  if(bias==BIAS_UNKNOWN) { Print("Daily bias unknown -> skip"); return; }
  PrintFormat("Daily bias = %d", bias);

  // 2) tìm H1 FVG thuận chiều với bias
  Zone h1zone; bool foundH1 = (FindH1FVGs(bias, h1zone) > 0);
  if(!foundH1) { Print("No H1 FVG found in bias direction"); return; }
  PrintFormat("Found H1 FVG: top=%.5f bottom=%.5f from=%d to=%d", h1zone.top, h1zone.bottom, h1zone.from_index, h1zone.to_index);

  // 3) khi giá hiện tại đã từng (hoặc đang) thuộc H1 FVG region -> tìm M5 FVG inside that H1 zone
  Zone m5zone; bool foundM5 = (FindM5FVGAtZone(h1zone,bias,m5zone) > 0);
  if(!foundM5) { Print("No M5 FVG inside H1 FVG -> skip"); return; }
  PrintFormat("Found M5 FVG: top=%.5f bottom=%.5f", m5zone.top, m5zone.bottom);

  // 4) xác nhận MSS trên M5 (đơn giản: break of structure recent swing)
  int mssType=0; double mssPrice=0;
  if(!DetectM5MSS(mssType,mssPrice)) { Print("No M5 MSS detected -> skip"); return; }
  PrintFormat("M5 MSS type=%d price=%.5f", mssType, mssPrice);

  // 5) chuẩn bị entry: nếu bias up -> place buy limit at bottom of m5zone; if bias down -> sell limit at top
  double entryPrice = (bias==BIAS_UP) ? m5zone.bottom : m5zone.top;

  // compute SL: if buy -> SL = lowest low of the pullback swing on M5 (we approximate by minimum low in zone window)
  double sl=0,tp=0;
  if(bias==BIAS_UP)
  {
    // find lowest low in recent M5 bars inside/near the m5zone range
    double swingLow = DBL_MAX;
    for(int i=0;i<M5_lookback;i++) { double low = iLow(_Symbol,PERIOD_M5,i); if(low < swingLow) swingLow = low; }
    sl = swingLow - 5*point; // small buffer
    if(sl >= entryPrice) { Print("Computed SL >= entry -> skip"); return; }
    double dist = entryPrice - sl;
    tp = entryPrice + RR * dist; // R:R=1:3
  }
  else
  {
    double swingHigh = -DBL_MAX;
    for(int i=0;i<M5_lookback;i++) { double high = iHigh(_Symbol,PERIOD_M5,i); if(high > swingHigh) swingHigh = high; }
    sl = swingHigh + 5*point;
    if(sl <= entryPrice) { Print("Computed SL <= entry -> skip"); return; }
    double dist = sl - entryPrice;
    tp = entryPrice - RR * dist;
  }

  // 6) tính lot theo risk = RiskPerTrade% equity cho khoảng cách entry->SL
  double lot = CalculateLotForRisk(entryPrice, sl);
  if(lot <= 0) { Print("Calculated lot <=0 -> skip"); return; }

  // 7) đặt pending limit
  int side = (bias==BIAS_UP) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
  // Check if EA already has active position or pending order (only 1 at a time)
  if(HasActiveOrders())
  {
    Print("Already have an active position or pending order for this EA -> skip placing another");
  }
  else
  {
    PlaceLimitOrder(side, entryPrice, sl, tp, lot);
  }
}

//+------------------------------------------------------------------+
DailyBias DetermineDailyBias()
{
  // theo yêu cầu: xét 2 cây D1 đã đóng gần nhất (không tính nến hiện tại -> shift 1 và 2)
  // nếu D[1].close > D[2].high -> up. nếu D[1].close < D[2].low -> down. nếu D[1] nằm trong D[2] thì bỏ qua D[1] và dùng D2 & D3

  int idx1 = 1; // D[1]
  int idx2 = 2; // D[2]
  int tries = 0;
  while(tries < 5)
  {
    double close1 = iClose(_Symbol,PERIOD_D1,idx1);
    double high2  = iHigh(_Symbol,PERIOD_D1,idx2);
    double low2   = iLow(_Symbol,PERIOD_D1,idx2);

    if(close1 > high2) return BIAS_UP;
    if(close1 < low2)  return BIAS_DOWN;

    // close1 inside candle2 -> shift window down (use D2 & D3)
    idx1++; idx2++; tries++;
    // ensure there are bars
    if(idx2 > 200) break;
  }
  return BIAS_UNKNOWN;
}

//+------------------------------------------------------------------+
int FindH1FVGs(DailyBias bias, Zone &foundZone)
{
  // Phương pháp đơn giản:
  // Tìm gap "Fair Value Gap" kiểu: giữa 2 candle (i and i+2) có khoảng trống
  // Bullish FVG (hỗ trợ): low[i] > high[i+2] -> vùng FVG là (high[i+2], low[i])
  // Bearish FVG (kháng cự): high[i] < low[i+2] -> vùng FVG là (high[i], low[i+2])

  int limit = H1_FVG_lookback;
  for(int i=1;i<limit-2;i++)
  {
    double high_i   = iHigh(_Symbol,PERIOD_H1,i);
    double low_i    = iLow(_Symbol,PERIOD_H1,i);
    double high_i2  = iHigh(_Symbol,PERIOD_H1,i+2);
    double low_i2   = iLow(_Symbol,PERIOD_H1,i+2);

    if(bias==BIAS_UP)
    {
      // bullish FVG
      if(low_i > high_i2 + SymbolInfoDouble(_Symbol,SYMBOL_POINT)*0.0) // allow equality
      {
        foundZone.top = low_i;
        foundZone.bottom = high_i2;
        foundZone.from_index = i+2;
        foundZone.to_index = i;
        return(1);
      }
    }
    else if(bias==BIAS_DOWN)
    {
      if(high_i < low_i2 - SymbolInfoDouble(_Symbol,SYMBOL_POINT)*0.0)
      {
        foundZone.top = high_i2; // caution: for clarity we set top>bottom
        foundZone.bottom = low_i;
        // normalize so top>bottom
        double t = MathMax(high_i, low_i2);
        double b = MathMin(high_i, low_i2);
        foundZone.top = t; foundZone.bottom = b;
        foundZone.from_index = i+2;
        foundZone.to_index = i;
        return(1);
      }
    }
  }
  return(0);
}

//+------------------------------------------------------------------+
int FindM5FVGAtZone(Zone &h1zone, DailyBias bias, Zone &m5zone)
{
  // Scan M5 recent bars. We look for small FVGs within the price range of H1 FVG
  int limit = M5_lookback;
  for(int i=1;i<limit-2;i++)
  {
    double high_i  = iHigh(_Symbol,PERIOD_M5,i);
    double low_i   = iLow(_Symbol,PERIOD_M5,i);
    double high_i2 = iHigh(_Symbol,PERIOD_M5,i+2);
    double low_i2  = iLow(_Symbol,PERIOD_M5,i+2);

    if(bias==BIAS_UP)
    {
      // bullish M5 FVG
      if(low_i > high_i2)
      {
        double top = low_i;
        double bottom = high_i2;
        // check overlap with H1 zone
        if(bottom <= h1zone.top && top >= h1zone.bottom)
        {
          m5zone.top = top; m5zone.bottom = bottom; return 1;
        }
      }
    }
    else if(bias==BIAS_DOWN)
    {
      if(high_i < low_i2)
      {
        double top = low_i2; double bottom = high_i;
        if(bottom <= h1zone.top && top >= h1zone.bottom)
        {
          m5zone.top = top; m5zone.bottom = bottom; return 1;
        }
      }
    }
  }
  return 0;
}

//+------------------------------------------------------------------+
bool DetectM5MSS(int &mssType, double &mssPrice)
{
  // Rất đơn giản: nếu price vừa break swing high -> bullish MSS (return 1)
  // nếu price just break swing low -> bearish MSS (return -1)
  // Implementation: compute last 3 swing highs and lows and check current candle

  // get last swing high (local maxima) and swing low (local minima) in M5
  double lastSwingHigh = -DBL_MAX; int idxHigh=-1;
  double lastSwingLow = DBL_MAX; int idxLow=-1;
  int look = 50;
  for(int i=2;i<look;i++)
  {
    double h = iHigh(_Symbol,PERIOD_M5,i);
    double l = iLow(_Symbol,PERIOD_M5,i);
    if(h > lastSwingHigh) { lastSwingHigh=h; idxHigh=i; }
    if(l < lastSwingLow)  { lastSwingLow=l; idxLow=i; }
  }

  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);

  // bullish MSS detection: current price (ask) > lastSwingHigh
  if(ask > lastSwingHigh)
  {
    mssType = 1; mssPrice = lastSwingHigh; return true;
  }
  if(bid < lastSwingLow)
  {
    mssType = -1; mssPrice = lastSwingLow; return true;
  }
  return false;
}

//+------------------------------------------------------------------+
double CalculateLotForRisk(double entryPrice, double stopPrice)
{
  // Tính lot sao cho khoảng cách entry->SL tương ứng RiskPerTrade% equity
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = equity * (RiskPerTrade/100.0);

  double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
  double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
  double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
  if(point<=0 || tickValue<=0 || tickSize<=0) { Print("Invalid symbol params for lot calc"); return 0; }

  double stopPoints = MathAbs(entryPrice - stopPrice)/point;
  if(stopPoints <= 0) return 0;

  double valuePerPoint = tickValue * (point / tickSize);
  double rawLot = riskMoney / (stopPoints * valuePerPoint);

  double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
  double lotStep= SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
  double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
  if(lotStep<=0) lotStep=0.01;

  double n = MathFloor(rawLot / lotStep);
  double lot = n * lotStep;
  if(lot < minLot) lot = minLot;
  if(lot > maxLot) lot = maxLot;

  lot = NormalizeDouble(lot,2);
  PrintFormat("CalcLot: entry=%.5f stop=%.5f stopPts=%.1f rawLot=%.4f finalLot=%.2f", entryPrice, stopPrice, stopPoints, rawLot, lot);
  return lot;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| HasActiveOrders: kiểm tra xem EA đã có position hoặc pending order |
//| - Trả về true nếu tồn tại position mở hoặc pending order cùng MagicNumber trên symbol
//+------------------------------------------------------------------+
bool HasActiveOrders()
{
  // check open positions
  for(int i=0;i<PositionsTotal();i++)
  {
    ulong ticket = PositionGetTicket(i);
    if(PositionSelectByTicket(ticket))
    {
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      string sym = PositionGetString(POSITION_SYMBOL);
      if(magic==MagicNumber && sym==_Symbol) return true;
    }
  }
  // check pending orders
  for(int i=0;i<OrdersTotal();i++)
  {
    ulong ticket = OrderGetTicket(i);
    if(OrderSelect(ticket))
    {
      long magic = (long)OrderGetInteger(ORDER_MAGIC);
      string sym = OrderGetString(ORDER_SYMBOL);
      if(magic==MagicNumber && sym==_Symbol) return true;
    }
  }
  return false;
}

void PlaceLimitOrder(int side, double price, double sl, double tp, double lot)
{
  // Create and send a pending limit order via MqlTradeRequest/OrderSend
  MqlTradeRequest  request;
  MqlTradeResult   result;
  ZeroMemory(request);
  ZeroMemory(result);

  request.action    = TRADE_ACTION_PENDING;      // we're placing a pending order
  request.symbol    = _Symbol;
  request.volume    = lot;
  request.price     = price;
  request.sl        = sl;
  request.tp        = tp;
  request.deviation = 20;
  request.magic     = MagicNumber;
  request.comment   = (side==POSITION_TYPE_BUY) ? "ICT_BUY_LIMIT" : "ICT_SELL_LIMIT";
  request.type_time = ORDER_TIME_GTC;            // good-till-cancelled
  request.type_filling = ORDER_FILLING_RETURN;   // safe default filling

  // set exact pending type
  if(side == POSITION_TYPE_BUY)
    request.type = ORDER_TYPE_BUY_LIMIT;
  else
    request.type = ORDER_TYPE_SELL_LIMIT;

  // Send the order request to the server
  if(!OrderSend(request,result))
  {
    // OrderSend can fail immediately (client-side) — print result for debugging
    PrintFormat("OrderSend() failed: retcode=%d comment=%s", result.retcode, result.comment);
    return;
  }

  // Check the server response (retcode)
  if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
  {
    ulong ticket = result.order;
    PrintFormat("Placed pending order: ticket=%I64u side=%d price=%.5f lot=%.2f SL=%.5f TP=%.5f",
                ticket, side, price, lot, sl, tp);

    // Draw SL/TP and entry lines on chart for visual confirmation
    string name_sl = StringFormat("ICT_SL_%I64u", ticket);
    string name_tp = StringFormat("ICT_TP_%I64u", ticket);
    string name_entry = StringFormat("ICT_ENTRY_%I64u", ticket);

    // Create horizontal lines at SL, TP and entry price
    if(ObjectFind(0, name_sl) == -1)
    {
      ObjectCreate(0, name_sl, OBJ_HLINE, 0, 0, sl);
      ObjectSetDouble(0, name_sl, OBJPROP_PRICE, sl);
      ObjectSetInteger(0, name_sl, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name_sl, OBJPROP_WIDTH, 1);
      ObjectSetString(0, name_sl, OBJPROP_TEXT, "SL: " + DoubleToString(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
    }
    if(ObjectFind(0, name_tp) == -1)
    {
      ObjectCreate(0, name_tp, OBJ_HLINE, 0, 0, tp);
      ObjectSetDouble(0, name_tp, OBJPROP_PRICE, tp);
      ObjectSetInteger(0, name_tp, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, name_tp, OBJPROP_WIDTH, 1);
      ObjectSetString(0, name_tp, OBJPROP_TEXT, "TP: " + DoubleToString(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
    }
    if(ObjectFind(0, name_entry) == -1)
    {
      ObjectCreate(0, name_entry, OBJ_HLINE, 0, 0, price);
      ObjectSetDouble(0, name_entry, OBJPROP_PRICE, price);
      ObjectSetInteger(0, name_entry, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, name_entry, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetString(0, name_entry, OBJPROP_TEXT, "Entry: " + DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
    }
  }
  else
  {
    // Broker may reject or modify pending order; log retcode & comment
    PrintFormat("OrderSend returned retcode=%d comment=%s", result.retcode, result.comment);
  }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  // Xoá các đối tượng SL/TP/ENTRY còn lại trên chart khi EA đóng
  int total = ObjectsTotal(0);
  for(int i = total - 1; i >= 0; i--)
  {
    string name = ObjectName(0, i);
    if(StringFind(name, "ICT_ENTRY_") == 0 ||
       StringFind(name, "ICT_SL_") == 0 ||
       StringFind(name, "ICT_TP_") == 0)
    {
      ObjectDelete(0, name);
    }
  }

  Print("EA deinitialized — cleaned objects.");
}
//+------------------------------------------------------------------+

// NOTES / CAVEATS:
// - Đây là bản mẫu triển khai logic theo mô tả của bạn, nhưng có nhiều điểm được đơn giản hóa
//   (phát hiện FVG và MSS là dạng heuristic đơn giản). Nên backtest kỹ và điều chỉnh
// - Bạn có thể muốn vẽ các zone (OBJ_RECTANGLE) để debug và quan sát H1/M5 FVG
// - Tinh chỉnh: lookback, cách xác định FVG, buffer SL, ADX filter, điều kiện trước khi đặt lệnh
// - EA hiện đặt 1 pending limit khi điều kiện thỏa. Nó không kiểm tra overlap với các pending/positions hiện tại
// - Hãy chạy trên demo/backtest trước khi dùng real

