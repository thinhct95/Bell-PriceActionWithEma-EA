//+------------------------------------------------------------------+
//| EA ICT-style: Daily Bias -> MidTf FVG -> LowTf pullback entries  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//--- Inputs
input double RiskPerTrade = 1.0;        // % equity risk per trade
input int    MagicNumber   = 33333;
input int    Mid_TF_FVG_lookback = 200; // bars to scan for MidTf FVG
input int    Low_TF_FVG_lookback = 200; // bars to scan for LowTf FVG/MSS
input double MinADX = 10.0;
input int    ADXPeriod = 14;
input double MaxAcceptableSpread = 200; // points
input double RR = 3.0;                 // Risk:Reward multiplier (TP = RR * risk distance)

//--- Timeframe configuration (configurable)
input ENUM_TIMEFRAMES TF_High = PERIOD_D1;   // Higher timeframe used for bias
input ENUM_TIMEFRAMES TF_Mid  = PERIOD_H1;   // Mid timeframe for FVG
input ENUM_TIMEFRAMES TF_Low  = PERIOD_M5;   // Low timeframe for entries

//--- Internal structs
struct Zone { double top; double bottom; int from_index; int to_index; };
enum DailyBias { BIAS_UNKNOWN=0, BIAS_UP=1, BIAS_DOWN=-1 };

//--- Forward
DailyBias DetermineDailyBias();
int    FindMidTfFvg(DailyBias bias, Zone &foundZone);
int    FindLowTfFvg(Zone &midTfZone, DailyBias bias, Zone &lowTfZone);
bool   DetectLowTfMSS(int &mssType, double &mssPrice);
double CalculateLotForRisk(double entryPrice, double stopPrice);
bool   HasActiveOrders();
void   PlaceLimitOrder(int side, double price, double sl, double tp, double lot);

//+------------------------------------------------------------------+
int OnInit()
{
  PrintFormat("EA init: TF_High=%d TF_Mid=%d TF_Low=%d", (int)TF_High, (int)TF_Mid, (int)TF_Low);
  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
  static datetime lastBarTime=0;
  datetime t = iTime(_Symbol, TF_Low, 0);
  if(t==lastBarTime) return;
  lastBarTime = t;

  // basic symbol params check
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if(point <= 0) { Print("Invalid SYMBOL_POINT -> abort tick"); return; }

  // spread check
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double spreadPts = (ask - bid)/point;
  if(spreadPts > MaxAcceptableSpread) { PrintFormat("Spread too high: %.1f pts", spreadPts); return; }

  // 1) bias on TF_High
  DailyBias bias = DetermineDailyBias();
  if(bias==BIAS_UNKNOWN) { Print("Bias unknown -> skip"); return; }
  PrintFormat("Bias = %d", bias);

  // 2) Mid TF FVG
  Zone midZone;
  if(FindMidTfFvg(bias, midZone) == 0) { Print("No MidTf FVG -> skip"); return; }
  PrintFormat("Mid zone: top=%.5f bottom=%.5f", midZone.top, midZone.bottom);

  // 3) Low TF FVG inside mid zone
  Zone lowZone;
  if(FindLowTfFvg(midZone, bias, lowZone) == 0) { Print("No LowTf FVG -> skip"); return; }
  PrintFormat("Low zone: top=%.5f bottom=%.5f", lowZone.top, lowZone.bottom);

  // 4) MSS detect on low TF
  int mssType=0; double mssPrice=0;
  if(!DetectLowTfMSS(mssType, mssPrice)) { Print("No LowTf MSS -> skip"); return; }
  PrintFormat("LowTf MSS type=%d price=%.5f", mssType, mssPrice);

  // 5) Entry at lowZone.bottom (buy) or top (sell)
  double entry = (bias==BIAS_UP) ? lowZone.bottom : lowZone.top;
  double sl=0, tp=0;

  // compute swing extreme on TF_Low with validation
  if(bias==BIAS_UP)
  {
    double swingLow = DBL_MAX;
    for(int i=0;i<Low_TF_FVG_lookback;i++)
    {
      double lv = iLow(_Symbol, TF_Low, i);
      if(lv <= 0) continue; // skip invalid bars
      if(lv < swingLow) swingLow = lv;
    }
    if(swingLow==DBL_MAX) { Print("Not enough low TF bars -> skip"); return; }
    sl = swingLow - 5*point;
    if(sl >= entry) { Print("SL >= entry -> skip"); return; }
    tp = entry + RR * (entry - sl);
  }
  else
  {
    double swingHigh = -DBL_MAX;
    for(int i=0;i<Low_TF_FVG_lookback;i++)
    {
      double hv = iHigh(_Symbol, TF_Low, i);
      if(hv <= 0) continue;
      if(hv > swingHigh) swingHigh = hv;
    }
    if(swingHigh==-DBL_MAX) { Print("Not enough low TF bars -> skip"); return; }
    sl = swingHigh + 5*point;
    if(sl <= entry) { Print("SL <= entry -> skip"); return; }
    tp = entry - RR * (sl - entry);
  }

  // 6) lot calc
  double lot = CalculateLotForRisk(entry, sl);
  if(lot <= 0) { Print("Lot <= 0 -> skip"); return; }

  // 7) only one active for EA on symbol
  int side = (bias==BIAS_UP) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
  if(HasActiveOrders()) { Print("Active order exists -> skip"); return; }

  PlaceLimitOrder(side, entry, sl, tp, lot);
}

//+------------------------------------------------------------------+
DailyBias DetermineDailyBias()
{
  int idx1=1, idx2=2, tries=0;
  while(tries<5)
  {
    double close1 = iClose(_Symbol, TF_High, idx1);
    double high2  = iHigh (_Symbol, TF_High, idx2);
    double low2   = iLow  (_Symbol, TF_High, idx2);
    if(close1 > high2) return BIAS_UP;
    if(close1 < low2)  return BIAS_DOWN;
    idx1++; idx2++; tries++;
    if(idx2>500) break;
  }
  return BIAS_UNKNOWN;
}

//+------------------------------------------------------------------+
int FindMidTfFvg(DailyBias bias, Zone &foundZone)
{
  int limit = Mid_TF_FVG_lookback;
  for(int i=1;i<limit-2;i++)
  {
    double high_i  = iHigh(_Symbol, TF_Mid, i);
    double low_i   = iLow (_Symbol, TF_Mid, i);
    double high_i2 = iHigh(_Symbol, TF_Mid, i+2);
    double low_i2  = iLow (_Symbol, TF_Mid, i+2);

    if(high_i<=0 || low_i<=0 || high_i2<=0 || low_i2<=0) continue;

    if(bias==BIAS_UP)
    {
      if(low_i > high_i2)
      {
        foundZone.top = low_i; foundZone.bottom = high_i2;
        foundZone.from_index = i+2; foundZone.to_index = i;
        return 1;
      }
    }
    else if(bias==BIAS_DOWN)
    {
      if(high_i < low_i2)
      {
        double t = MathMax(high_i, low_i2);
        double b = MathMin(high_i, low_i2);
        foundZone.top = t; foundZone.bottom = b;
        foundZone.from_index = i+2; foundZone.to_index = i;
        return 1;
      }
    }
  }
  return 0;
}

//+------------------------------------------------------------------+
int FindLowTfFvg(Zone &midTfZone, DailyBias bias, Zone &lowTfZone)
{
  int limit = Low_TF_FVG_lookback;
  for(int i=1;i<limit-2;i++)
  {
    double high_i  = iHigh(_Symbol, TF_Low, i);
    double low_i   = iLow (_Symbol, TF_Low, i);
    double high_i2 = iHigh(_Symbol, TF_Low, i+2);
    double low_i2  = iLow (_Symbol, TF_Low, i+2);

    if(high_i<=0 || low_i<=0 || high_i2<=0 || low_i2<=0) continue;

    if(bias==BIAS_UP)
    {
      if(low_i > high_i2)
      {
        double top = low_i; double bottom = high_i2;
        if(bottom <= midTfZone.top && top >= midTfZone.bottom)
        {
          lowTfZone.top = top; lowTfZone.bottom = bottom; return 1;
        }
      }
    }
    else
    {
      if(high_i < low_i2)
      {
        double top = low_i2; double bottom = high_i;
        if(bottom <= midTfZone.top && top >= midTfZone.bottom)
        {
          lowTfZone.top = top; lowTfZone.bottom = bottom; return 1;
        }
      }
    }
  }
  return 0;
}

//+------------------------------------------------------------------+
bool DetectLowTfMSS(int &mssType, double &mssPrice)
{
  double lastSwingHigh = -DBL_MAX; int idxHigh=-1;
  double lastSwingLow  = DBL_MAX;  int idxLow=-1;
  int look = 50;
  for(int i=2;i<look;i++)
  {
    double h = iHigh(_Symbol, TF_Low, i);
    double l = iLow (_Symbol, TF_Low, i);
    if(h>0 && h > lastSwingHigh) { lastSwingHigh=h; idxHigh=i; }
    if(l>0 && l < lastSwingLow)  { lastSwingLow=l;  idxLow=i; }
  }
  double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
  if(ask > lastSwingHigh) { mssType=1; mssPrice = lastSwingHigh; return true; }
  if(bid < lastSwingLow)  { mssType=-1; mssPrice = lastSwingLow; return true; }
  return false;
}

//+------------------------------------------------------------------+
double CalculateLotForRisk(double entryPrice, double stopPrice)
{
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = equity * (RiskPerTrade/100.0);

  double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
  double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
  double tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

  // Fallback: if broker returns 0 for tickValue/tickSize, estimate valuePerPoint using contract size:
  double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
  if(tickValue<=0 || tickSize<=0)
  {
    // rough fallback: assume 1 lot -> contractSize * point movement value (this might be instrument-specific)
    tickValue = contractSize; tickSize = 1.0;
  }

  if(point<=0 || tickValue<=0 || tickSize<=0) { Print("Invalid symbol params for lot calc"); return 0; }

  double stopPoints = MathAbs(entryPrice - stopPrice)/point;
  if(stopPoints <= 0) return 0;

  double valuePerPoint = tickValue * (point / tickSize);
  if(valuePerPoint <= 0) { Print("valuePerPoint invalid"); return 0; }

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

//+------------------------------------------------------------------+
void PlaceLimitOrder(int side, double price, double sl, double tp, double lot)
{
  MqlTradeRequest  request; MqlTradeResult result;
  ZeroMemory(request); ZeroMemory(result);

  request.action    = TRADE_ACTION_PENDING;
  request.symbol    = _Symbol;
  request.volume    = lot;
  request.price     = price;
  request.sl        = sl;
  request.tp        = tp;
  request.deviation = 20;
  request.magic     = MagicNumber;
  request.comment   = (side==POSITION_TYPE_BUY) ? "ICT_BUY_LIMIT" : "ICT_SELL_LIMIT";
  request.type_time = ORDER_TIME_GTC;
  request.type_filling = ORDER_FILLING_RETURN;
  request.type = (side==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;

  if(!OrderSend(request,result))
  {
    PrintFormat("OrderSend() failed: retcode=%d comment=%s", result.retcode, result.comment);
    return;
  }

  if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
  {
    ulong ticket = result.order;
    PrintFormat("Placed pending order ticket=%I64u side=%d price=%.5f lot=%.2f SL=%.5f TP=%.5f",
                ticket, side, price, lot, sl, tp);
    // draw lines
    string n_sl = StringFormat("ICT_SL_%I64u", ticket);
    string n_tp = StringFormat("ICT_TP_%I64u", ticket);
    string n_en = StringFormat("ICT_ENTRY_%I64u", ticket);
    if(ObjectFind(0,n_sl) == -1) ObjectCreate(0,n_sl,OBJ_HLINE,0,0,sl);
    if(ObjectFind(0,n_tp) == -1) ObjectCreate(0,n_tp,OBJ_HLINE,0,0,tp);
    if(ObjectFind(0,n_en) == -1) ObjectCreate(0,n_en,OBJ_HLINE,0,0,price);
    ObjectSetInteger(0,n_sl,OBJPROP_COLOR,clrRed);
    ObjectSetInteger(0,n_tp,OBJPROP_COLOR,clrLime);
    ObjectSetInteger(0,n_en,OBJPROP_COLOR,clrYellow);
    ObjectSetString(0,n_sl,OBJPROP_TEXT,"SL: "+DoubleToString(sl,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)));
  }
  else
  {
    PrintFormat("OrderSend returned retcode=%d comment=%s", result.retcode, result.comment);
  }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
  int total = ObjectsTotal(0);
  for(int i=total-1;i>=0;i--)
  {
    string name = ObjectName(0,i);
    if(StringFind(name,"ICT_ENTRY_")==0 || StringFind(name,"ICT_SL_")==0 || StringFind(name,"ICT_TP_")==0)
      ObjectDelete(0,name);
  }
  Print("EA deinitialized - cleaned objects.");
}
//+------------------------------------------------------------------+
