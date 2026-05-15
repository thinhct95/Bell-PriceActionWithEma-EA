//+------------------------------------------------------------------+
//| MotherBarBreakout.mq5                                            |
//| M15: thân nến >= K × TB thân N nến liền trước                   |
//+------------------------------------------------------------------+
#property copyright "MotherBarBreakout"
#property version   "2.01"

#property description "M15 large body: body >= K × average of N prior bodies. Marks on chart."

input ENUM_TIMEFRAMES InpTf               = PERIOD_M15;
input int             InpAvgPriorBodies   = 10;     // TB của 10 thân nến liền trước
input double          InpBodyVsAvgMult    = 3.0;    // thân hiện tại >= hệ số này × TB (vd 3 = gấp 3)
input int             InpScanBarsOnInit   = 300;
input bool            InpClearMarksOnInit = true;

input color           InpClrBullBar       = clrDodgerBlue;  // nến tăng (chỉ phân biệt hướng nến, không lọc trend)
input color           InpClrBearBar       = clrDarkOrange;
input int             InpArrowSize        = 2;
input int             InpArrowOffsetPts   = 20;

const string OBJ_PFX = "MBB_";

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
double BodyAbs(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   return MathAbs(iClose(sym, tf, sh) - iOpen(sym, tf, sh));
}

//+------------------------------------------------------------------+
//| Thân nến sh >= InpBodyVsAvgMult × TB thân sh+1 .. sh+n         //
//+------------------------------------------------------------------+
bool IsBodyLargerThanPriorAverage(const string sym, const ENUM_TIMEFRAMES tf,
                                 const int sh, const int nAvg)
{
   if(nAvg < 1)
      return false;

   if(InpBodyVsAvgMult <= 0.0)
      return false;

   const int need = sh + nAvg + 1;
   if(Bars(sym, tf) < need)
      return false;

   double sum = 0.0;
   for(int k = 1; k <= nAvg; k++)
      sum += BodyAbs(sym, tf, sh + k);

   const double avg = sum / (double)nAvg;
   const double body = BodyAbs(sym, tf, sh);
   const double threshold = InpBodyVsAvgMult * avg;

   return (body >= threshold);
}

//+------------------------------------------------------------------+
void DeleteMarkersByPrefix()
{
   const long chart_id = ChartID();
   const int n = ObjectsTotal(chart_id, 0, -1);
   for(int i = n - 1; i >= 0; i--)
   {
      const string name = ObjectName(chart_id, i, 0, -1);
      if(StringFind(name, OBJ_PFX) == 0)
         ObjectDelete(chart_id, name);
   }
}

//+------------------------------------------------------------------+
void PlaceMarker(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   const datetime t = iTime(sym, tf, sh);
   const string name = OBJ_PFX + IntegerToString((long)t);
   const long chart_id = ChartID();

   if(ObjectFind(chart_id, name) >= 0)
      return;

   const bool bull = (iClose(sym, tf, sh) >= iOpen(sym, tf, sh));
   const int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);

   double price = 0.0;
   if(bull)
      price = iLow(sym, tf, sh) - InpArrowOffsetPts * pt;
   else
      price = iHigh(sym, tf, sh) + InpArrowOffsetPts * pt;
   price = NormalizeDouble(price, dig);

   if(!ObjectCreate(chart_id, name, OBJ_ARROW, 0, t, price))
      return;

   ObjectSetInteger(chart_id, name, OBJPROP_ARROWCODE, bull ? 233 : 234);
   ObjectSetInteger(chart_id, name, OBJPROP_COLOR, bull ? InpClrBullBar : InpClrBearBar);
   ObjectSetInteger(chart_id, name, OBJPROP_WIDTH, InpArrowSize);
   ObjectSetInteger(chart_id, name, OBJPROP_ANCHOR, bull ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(chart_id, name, OBJPROP_BACK, false);
   ObjectSetInteger(chart_id, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chart_id, name, OBJPROP_HIDDEN, false);
}

//+------------------------------------------------------------------+
void TryMarkAtShift(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   if(IsBodyLargerThanPriorAverage(sym, tf, sh, InpAvgPriorBodies))
      PlaceMarker(sym, tf, sh);
}

//+------------------------------------------------------------------+
void ScanHistory(const string sym, const ENUM_TIMEFRAMES tf, const int maxBars)
{
   if(maxBars <= 0)
      return;

   const int n = MathMin(maxBars, Bars(sym, tf) - InpAvgPriorBodies - 2);
   for(int sh = 1; sh <= n; sh++)
      TryMarkAtShift(sym, tf, sh);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAvgPriorBodies < 1)
   {
      Print("[MBB] InpAvgPriorBodies phải >= 1");
      return INIT_FAILED;
   }
   if(InpBodyVsAvgMult <= 0.0)
   {
      Print("[MBB] InpBodyVsAvgMult phải > 0");
      return INIT_FAILED;
   }

   if(InpClearMarksOnInit)
      DeleteMarkersByPrefix();

   ScanHistory(_Symbol, InpTf, InpScanBarsOnInit);

   g_lastBarTime = iTime(_Symbol, InpTf, 0);
   ChartRedraw();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteMarkersByPrefix();
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   const datetime t0 = iTime(_Symbol, InpTf, 0);
   if(t0 == 0 || t0 == g_lastBarTime)
      return;
   g_lastBarTime = t0;

   TryMarkAtShift(_Symbol, InpTf, 1);
   ChartRedraw();
}

//+------------------------------------------------------------------+
