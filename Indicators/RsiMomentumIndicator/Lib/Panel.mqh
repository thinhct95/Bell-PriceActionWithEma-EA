//+------------------------------------------------------------------+
//| Panel.mqh                                                        |
//| Panel thông tin góc trên-phải chart: trend, RSI/EMA9/WMA45.       |
//+------------------------------------------------------------------+
#ifndef RSIMOM_PANEL_MQH
#define RSIMOM_PANEL_MQH

//+------------------------------------------------------------------+
//| Tạo một OBJ_LABEL trên chart chính                               |
//+------------------------------------------------------------------+
void CreateLabel(const string name, const string text, const color clr,
                 const int x, const int y, const int fontSize = 9)
{
  if (ObjectFind(0, name) >= 0) return;
  ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
  ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
  ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fontSize);
  ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
  ObjectSetInteger(0, name, OBJPROP_BACK,       false);
  ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
  ObjectSetString (0, name, OBJPROP_TEXT,       text);
}

//+------------------------------------------------------------------+
//| Update text + màu của label đã tồn tại                            |
//+------------------------------------------------------------------+
void UpdateLabel(const string name, const string text, const color clr)
{
  if (ObjectFind(0, name) < 0) return;
  ObjectSetString (0, name, OBJPROP_TEXT,  text);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Tạo toàn bộ label ban đầu (gọi 1 lần từ OnInit)                  |
//+------------------------------------------------------------------+
void Panel_CreateAll()
{
  if (!InpShowPanel) return;
  CreateLabel(LBL_TITLE,    "─ RSI MOMENTUM ─",   clrWhite,         10, 14, 10);
  CreateLabel(LBL_TREND,    "Trend : ---",          clrSilver,        10, 34, 9);
  CreateLabel(LBL_RSI_VAL,  "RSI   : ---",          clrMediumOrchid,  10, 51, 9);
  CreateLabel(LBL_EMA9VAL,  "EMA9  : ---",          clrDarkOrange,    10, 68, 9);
  CreateLabel(LBL_WMA45VAL, "WMA45 : ---",          clrDodgerBlue,    10, 85, 9);
}

//+------------------------------------------------------------------+
//| Cập nhật panel mỗi tick (dùng nến vừa đóng = index 1)            |
//| Sử dụng cùng quy tắc N nến liên tiếp như filter signal.          |
//+------------------------------------------------------------------+
void Panel_Update(const double &closeArr[], const double &ema200Arr[],
                  const int trendN, const int rates_total)
{
  if (!InpShowPanel) return;
  if (rates_total <= trendN + 1) return;
  if (ema200Arr[1] <= 0.0) return;

  // Áp dụng cùng quy tắc N nến liên tiếp cho panel hiển thị
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

  UpdateLabel(LBL_TREND,    trendTxt,                                               trendClr);
  UpdateLabel(LBL_RSI_VAL,  StringFormat("RSI   : %6.2f", buf_RSI[1]),  clrMediumOrchid);
  UpdateLabel(LBL_EMA9VAL,  StringFormat("EMA9  : %6.2f", buf_EMA9[1]), clrDarkOrange);
  UpdateLabel(LBL_WMA45VAL, StringFormat("WMA45 : %6.2f", buf_WMA45[1]),clrDodgerBlue);
}

#endif // RSIMOM_PANEL_MQH
