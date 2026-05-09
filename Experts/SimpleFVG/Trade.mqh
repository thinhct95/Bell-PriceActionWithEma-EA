//+------------------------------------------------------------------+
//| Trade.mqh – Step 3: Trade management for FVG strategy            |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_TRADE_MQH__
#define __SIMPLE_FVG_TRADE_MQH__

#include "Config.mqh"
#include "Trend.mqh"
#include "FVG.mqh"

//--- Trading config nằm trong Config.mqh (Step 3)

//+------------------------------------------------------------------+
//| Internal helpers                                                 |
//+------------------------------------------------------------------+
string FVGTypeToString(ENUM_FVG_TYPE type)
{
   return (type == FVG_BULLISH) ? "BULL" : "BEAR";
}

void LogDecisionTrace(const string stage, const string message)
{
   if(!InpDebugLog)
      return;
   PrintFormat("[TRACE][%s] %s", stage, message);
}

bool IsSpreadAcceptable(string symbol)
{
   if(InpMaxSpreadPoints <= 0)
      return true;

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double spreadPoints = -1.0;
   if(ask > 0.0 && bid > 0.0)
      spreadPoints = (ask - bid) / _Point;
   else
   {
      // In Strategy Tester, BID/ASK can be unavailable on some bars.
      // Fallback to broker/tester spread setting (already in points).
      long spreadInt = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
      if(spreadInt > 0)
         spreadPoints = (double)spreadInt;
   }

   if(spreadPoints < 0.0)
      return false;

   return (spreadPoints <= InpMaxSpreadPoints);
}

double GetCurrentSpreadPoints(string symbol)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(ask > 0.0 && bid > 0.0)
      return (ask - bid) / _Point;

   long spreadInt = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spreadInt > 0)
      return (double)spreadInt;

   return -1.0;
}

bool IsTradingSessionOpen()
{
   if(!InpUseSessionFilter)
      return true;

   datetime now = TimeCurrent();
   if(now == 0)
      return false;

   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;

   int startHour = MathMax(0, MathMin(23, InpSessionStartHour));
   int endHour   = MathMax(0, MathMin(23, InpSessionEndHour));

   if(startHour == endHour)
      return true;
   if(startHour < endHour)
      return (hour >= startHour && hour < endHour);
   return (hour >= startHour || hour < endHour); // overnight session
}

int GetCurrentServerHour()
{
   datetime now = TimeCurrent();
   if(now == 0)
      return -1;

   MqlDateTime dt;
   TimeToStruct(now, dt);
   return dt.hour;
}

void GetNormalizedSessionHours(int &outStartHour, int &outEndHour)
{
   outStartHour = MathMax(0, MathMin(23, InpSessionStartHour));
   outEndHour   = MathMax(0, MathMin(23, InpSessionEndHour));
}

double GetATRPoints(string symbol, ENUM_TIMEFRAMES tf, int period)
{
   if(period <= 1)
      return -1.0;

   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return -1.0;

   double buffer[1];
   int copied = CopyBuffer(handle, 0, 1, 1, buffer);
   IndicatorRelease(handle);
   if(copied < 1 || buffer[0] <= 0.0)
      return -1.0;

   return buffer[0] / _Point;
}

bool IsATRRegimeValid(string symbol)
{
   if(!InpUseATRFilter)
      return true;

   double atrPoints = GetATRPoints(symbol, InpTimeframe, InpATRPeriod);
   if(atrPoints <= 0.0)
      return false;
   if(InpMinATRPoints > 0.0 && atrPoints < InpMinATRPoints)
      return false;
   if(InpMaxATRPoints > 0.0 && atrPoints > InpMaxATRPoints)
      return false;
   return true;
}

double GetCurrentATRPoints(string symbol)
{
   return GetATRPoints(symbol, InpTimeframe, InpATRPeriod);
}

int CountOurPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if((long)PositionGetInteger(POSITION_MAGIC) == InpEAMagic &&
         (string)PositionGetString(POSITION_SYMBOL) == GetTradeSymbol())
      {
         count++;
      }
   }
   return count;
}

int CountOurLimitOrders()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      long            magic = (long)OrderGetInteger(ORDER_MAGIC);
      string          symbol = (string)OrderGetString(ORDER_SYMBOL);

      if(magic == InpEAMagic &&
         symbol == GetTradeSymbol() &&
         (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT))
      {
         count++;
      }
   }
   return count;
}

void CancelAllOurLimitOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      long            magic = (long)OrderGetInteger(ORDER_MAGIC);
      string          symbol = (string)OrderGetString(ORDER_SYMBOL);

      if(magic == InpEAMagic &&
         symbol == GetTradeSymbol() &&
         (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT))
      {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;

         if(!OrderSend(req, res) && InpDebugLog)
            PrintFormat("[Trade] Failed to cancel order #%I64u, retcode=%d",
                        ticket, res.retcode);
      }
   }
}

bool HasLimitOrderAtPrice(ENUM_ORDER_TYPE orderType, double entryPrice)
{
   double eps = 2 * _Point;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      if((long)OrderGetInteger(ORDER_MAGIC) != InpEAMagic) continue;
      if((string)OrderGetString(ORDER_SYMBOL) != GetTradeSymbol()) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != orderType) continue;

      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(price - entryPrice) <= eps)
         return true;
   }
   return false;
}

// Hủy các limit order quá "già" (tính theo số bar trên InpTimeframe)
void CancelStaleLimitOrders()
{
   if(InpLimitMaxAgeBars <= 0)
      return;

   datetime now = TimeCurrent();
   if(now == 0)
      return;

   int tfSeconds = PeriodSeconds(InpTimeframe);
   if(tfSeconds <= 0)
      return;

   int maxAgeSeconds = InpLimitMaxAgeBars * tfSeconds;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      long            magic = (long)OrderGetInteger(ORDER_MAGIC);
      string          symbol = (string)OrderGetString(ORDER_SYMBOL);

      if(magic != InpEAMagic) continue;
      if(symbol != GetTradeSymbol()) continue;
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
         continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      int ageSeconds = int(now - setupTime);
      if(ageSeconds < maxAgeSeconds)
         continue;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;

      if(!OrderSend(req, res) && InpDebugLog)
         PrintFormat("[Trade] Failed to cancel stale order #%I64u, ageBars=%d, retcode=%d",
                     ticket, ageSeconds / tfSeconds, res.retcode);
   }
}

void GetTradeStats(int &totalTrades, int &tpTrades, int &slTrades)
{
   totalTrades = 0;
   tpTrades    = 0;
   slTrades    = 0;

   datetime now = TimeCurrent();
   if(now == 0)
      return;

   if(!HistorySelect(0, now))
      return;

   int deals = HistoryDealsTotal();
   string symbol = GetTradeSymbol();

   for(int i = 0; i < deals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      string dealSymbol = (string)HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long   dealMagic  = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(dealSymbol != symbol || dealMagic != InpEAMagic)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      totalTrades++;

      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if(reason == DEAL_REASON_TP)
         tpTrades++;
      else if(reason == DEAL_REASON_SL)
         slTrades++;
   }
}

// Tính khối lượng lot sao cho 1R = InpRiskPercentPerR % balance
double CalculateRiskLotSize(double entryPrice, double slPrice)
{
   string symbol = GetTradeSymbol();

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double volMin    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volMax    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double priceDiff = MathAbs(entryPrice - slPrice);
   if(balance <= 0 || tickSize <= 0 || tickValue <= 0 || priceDiff <= 0)
      return 0.0;

   double riskMoney = balance * InpRiskPercentPerR / 100.0;
   if(riskMoney <= 0.0)
      return 0.0;

   double ticks      = priceDiff / tickSize;
   double costPerLot = ticks * tickValue; // tiền lỗ nếu 1 lot hit SL
   if(costPerLot <= 0.0)
      return 0.0;

   double rawVolume = riskMoney / costPerLot;

   // Làm tròn đến 2 chữ số thập phân
   double rounded2 = MathFloor(rawVolume * 100.0 + 0.5) / 100.0;

   // Canh theo step volume
   if(volStep > 0.0)
      rounded2 = MathFloor(rounded2 / volStep) * volStep;

   // Giới hạn theo min/max
   if(rounded2 < volMin)
      rounded2 = volMin;
   if(rounded2 > volMax)
      rounded2 = volMax;

   return rounded2;
}

// Đặt lệnh limit theo entry/SL từ low TF FVG (sau khi có tín hiệu xác nhận)
bool PlaceLimitFromLowTF(string symbol, ENUM_FVG_TYPE type, double entryPrice, double slPrice)
{
   double tpPrice;
   ENUM_ORDER_TYPE orderType;

   if(type == FVG_BULLISH)
   {
      double risk = entryPrice - slPrice;
      if(risk <= 0.0) return false;
      tpPrice   = entryPrice + risk * InpRRRatio;
      orderType = ORDER_TYPE_BUY_LIMIT;
   }
   else
   {
      double risk = slPrice - entryPrice;
      if(risk <= 0.0) return false;
      tpPrice   = entryPrice - risk * InpRRRatio;
      orderType = ORDER_TYPE_SELL_LIMIT;
   }

   if(HasLimitOrderAtPrice(orderType, entryPrice))
      return false;

   double volume = CalculateRiskLotSize(entryPrice, slPrice);
   if(volume <= 0.0)
      return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_PENDING;
   req.symbol   = symbol;
   req.magic    = InpEAMagic;
   req.type     = orderType;
   req.volume   = volume;
   req.price    = entryPrice;
   req.sl       = slPrice;
   req.tp       = tpPrice;
   req.type_filling = ORDER_FILLING_RETURN;
   req.deviation = 10;
   req.comment  = "SimpleFVG_LTF";

   if(!OrderSend(req, res))
      return false;
   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

bool PlaceLimitForZone(const FVGZone &zone)
{
   string symbol = GetTradeSymbol();

   double entryPrice;
   double slPrice;
   double tpPrice;
   ENUM_ORDER_TYPE orderType;

   double zoneHeight = zone.upperEdge - zone.lowerEdge;
   if(zoneHeight <= 0.0)
      return false;

   double touchRatio = InpFVGTouchedPercent / 100.0;

   if(zone.type == FVG_BULLISH)
   {
      // Entry: 35% từ đỉnh vùng xuống
      entryPrice = zone.upperEdge - zoneHeight * touchRatio;
      slPrice    = zone.slReferencePrice;

      double risk = entryPrice - slPrice;
      if(risk <= 0) return false;
      tpPrice   = entryPrice + risk * InpRRRatio;
      orderType = ORDER_TYPE_BUY_LIMIT;
   }
   else // FVG_BEARISH
   {
      // Entry: 35% từ đáy vùng lên
      entryPrice = zone.lowerEdge + zoneHeight * touchRatio;
      slPrice    = zone.slReferencePrice;

      double risk = slPrice - entryPrice;
      if(risk <= 0) return false;
      tpPrice   = entryPrice - risk * InpRRRatio;
      orderType = ORDER_TYPE_SELL_LIMIT;
   }

   // Không tạo lệnh nếu đã có limit trùng giá/type
   if(HasLimitOrderAtPrice(orderType, entryPrice))
      return false;

   double volume = CalculateRiskLotSize(entryPrice, slPrice);
   if(volume <= 0.0)
      return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_PENDING;
   req.symbol   = symbol;
   req.magic    = InpEAMagic;
   req.type     = orderType;
   req.volume   = volume;
   req.price    = entryPrice;
   req.sl       = slPrice;
   req.tp       = tpPrice;
   req.type_filling = ORDER_FILLING_RETURN;

   req.deviation = 10;
   req.comment   = "SimpleFVG";

   if(!OrderSend(req, res))
      return false;

   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Public: main trade manager                                       |
//+------------------------------------------------------------------+
void ManageFVGTrades()
{
   if(!InpTradeEnabled)
      return;

   // Hủy các lệnh limit đã quá số bar cho phép
   CancelStaleLimitOrders();

   // Nếu đã có vị thế, hủy toàn bộ limit còn lại
   if(CountOurPositions() > 0)
   {
      CancelAllOurLimitOrders();
      return;
   }

   int currentLimits = CountOurLimitOrders();
   if(currentLimits >= InpMaxLimitOrders)
      return;

   string symbol = GetTradeSymbol();
   if(!IsSpreadAcceptable(symbol))
   {
      double spreadPts = GetCurrentSpreadPoints(symbol);
      LogDecisionTrace("FILTER", StringFormat("Skip entries: spread %.1f > max %d points",
                                              spreadPts, InpMaxSpreadPoints));
      return;
   }
   if(!IsTradingSessionOpen())
   {
      int startHour, endHour;
      GetNormalizedSessionHours(startHour, endHour);
      int currentHour = GetCurrentServerHour();
      LogDecisionTrace("FILTER", StringFormat("Skip entries: session closed (hour=%d, window=%02d-%02d, useSession=%s)",
                                              currentHour, startHour, endHour,
                                              InpUseSessionFilter ? "true" : "false"));
      return;
   }
   if(!IsATRRegimeValid(symbol))
   {
      double atrPoints = GetCurrentATRPoints(symbol);
      LogDecisionTrace("FILTER", StringFormat("Skip entries: ATR %.1f outside [%.1f..%.1f] points (period=%d, useATR=%s)",
                                              atrPoints, InpMinATRPoints, InpMaxATRPoints,
                                              InpATRPeriod, InpUseATRFilter ? "true" : "false"));
      return;
   }

   // Chỉ tìm tín hiệu low TF FVG khi high TF FVG đã TOUCHED (giá lấp đủ %), không trigger khi mới chạm cạnh
   ENUM_TREND_DIRECTION trend = g_CurrentTrend;
   ENUM_TIMEFRAMES lowTF = GetConfirmationTimeframe(InpTimeframe);
   const int LOW_TF_FVG_LOOKBACK = 15;

   for(int i = g_FVGCount - 1; i >= 0 && currentLimits < InpMaxLimitOrders; i--)
   {
      FVGZone zone = g_FVGZones[i];
      if(!IsZoneActive(zone) || IsZoneMitigated(zone))
      {
         LogDecisionTrace("ZONE", StringFormat("#%d skip: inactive/mitigated", i));
         continue;
      }

      if(zone.tradeLocked)
      {
         LogDecisionTrace("ZONE", StringFormat("#%d %s skip: locked", i, FVGTypeToString(zone.type)));
         continue;
      }

      if(zone.type == FVG_BULLISH && trend != TREND_BULLISH)
      {
         LogDecisionTrace("ZONE", StringFormat("#%d BULL blocked by EMA trend", i));
         continue;
      }
      if(zone.type == FVG_BEARISH && trend != TREND_BEARISH)
      {
         LogDecisionTrace("ZONE", StringFormat("#%d BEAR blocked by EMA trend", i));
         continue;
      }

      // Điều kiện vào lệnh: FVG high TF phải đã TOUCHED (giá lấp >= InpFVGTouchedPercent), không chỉ chạm cạnh
      if(!IsZoneTouched(zone))
      {
         LogDecisionTrace("ZONE", StringFormat("#%d %s not touched", i, FVGTypeToString(zone.type)));
         continue;
      }

      // Chỉ đặt lệnh khi có low TF để xác nhận (H1->M5, H4->M15, M15->M2)
      if(lowTF == InpTimeframe)
      {
         LogDecisionTrace("ZONE", StringFormat("#%d skip: lowTF mapping unavailable", i));
         continue;
      }

      double ltfUpper, ltfLower, ltfBarALow, ltfBarAHigh;
      if(!GetLatestLowTFFVGInRange(symbol, lowTF, zone.type, LOW_TF_FVG_LOOKBACK,
                                   zone.lowerEdge, zone.upperEdge,
                                   InpLowTFEntryRangeBufferPoints,
                                   ltfUpper, ltfLower, ltfBarALow, ltfBarAHigh))
      {
         LogDecisionTrace("ZONE", StringFormat("#%d %s no LTF FVG aligned to HTF zone [%.5f..%.5f]",
                                               i, FVGTypeToString(zone.type), zone.lowerEdge, zone.upperEdge));
         continue;
      }

      // Entry theo low TF FVG; SL = bar B của high TF FVG
      double entryPrice, slPrice;
      if(zone.type == FVG_BULLISH)
      {
         entryPrice = ltfUpper;            // Buy limit tại cạnh trên low TF FVG
         slPrice    = zone.slReferencePrice; // SL dưới bar B high TF
      }
      else
      {
         entryPrice = ltfLower;            // Sell limit tại cạnh dưới low TF FVG
         slPrice    = zone.slReferencePrice; // SL trên bar B high TF
      }

      if(PlaceLimitFromLowTF(symbol, zone.type, entryPrice, slPrice))
      {
         // v2 state: lock zone after first successful placement; keep visible for diagnostics.
         g_FVGZones[i].tradeLocked       = true;
         g_FVGZones[i].tradeLockedTime   = TimeCurrent();
         g_FVGZones[i].linkedOrderTicket = 0;
         LogDecisionTrace("ORDER", StringFormat("#%d %s placed @%.5f SL=%.5f HTF[%.5f..%.5f] LTF[%.5f..%.5f]",
                                                i, FVGTypeToString(zone.type), entryPrice, slPrice,
                                                zone.lowerEdge, zone.upperEdge, ltfLower, ltfUpper));
         currentLimits++;
      }
      else
      {
         LogDecisionTrace("ORDER", StringFormat("#%d %s failed @%.5f", i, FVGTypeToString(zone.type), entryPrice));
      }
   }
}

#endif

