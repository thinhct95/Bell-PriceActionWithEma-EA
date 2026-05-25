//+------------------------------------------------------------------+
//| Panel.mqh — Daily Bias + Intraday (mỗi dòng = 1 OBJ_LABEL)         |
//| Bias/Intraday: xanh = Up, đỏ = Down — cùng màu = canh trade       |
//+------------------------------------------------------------------+
#ifndef ICT2026_PANEL_MQH
#define ICT2026_PANEL_MQH

#include <ICT2026/Config.mqh>
#include <ICT2026/DailyBias.mqh>
#include <ICT2026/IntradayStructure.mqh>
#include <ICT2026/LowTfTrend.mqh>
#include <ICT2026/EaState.mqh>
#include <ICT2026/Stats.mqh>

const string ICT26_PANEL_PFX     = "ICT26_PNL_";
const string ICT26_PANEL_LEGACY  = "ICT26_BIAS_PANEL";
const int    ICT26_PANEL_MAXLINE = 20;

const color ICT_PANEL_CLR_UP      = clrLime;
const color ICT_PANEL_CLR_DOWN    = clrOrangeRed;
const color ICT_PANEL_CLR_NEUTRAL = clrSilver;
const color ICT_PANEL_CLR_MUTED   = clrGainsboro;
const color ICT_PANEL_CLR_ALLOW   = clrAqua;

string IctPanel_LineName(const int index)
{
   return ICT26_PANEL_PFX + IntegerToString(index);
}

int IctPanel_LineHeight()
{
   const int minByFont = InpPanelFontSize + 10;
   return MathMax(InpPanelLineSpacing, minByFont);
}

color IctPanelBiasDirectionColor(const ENUM_ICT_BIAS bias)
{
   if(bias == ICT_BIAS_BULL)
      return ICT_PANEL_CLR_UP;
   if(bias == ICT_BIAS_BEAR)
      return ICT_PANEL_CLR_DOWN;
   return ICT_PANEL_CLR_NEUTRAL;
}

color IctPanelIntradayDirectionColor(const ENUM_ICT_TREND trend)
{
   if(trend == ICT_TREND_UP)
      return ICT_PANEL_CLR_UP;
   if(trend == ICT_TREND_DOWN)
      return ICT_PANEL_CLR_DOWN;
   return ICT_PANEL_CLR_NEUTRAL;
}

color IctPanelAllowTradeColor()
{
   if(g_ictIntraday.isAllowTrade)
      return ICT_PANEL_CLR_ALLOW;
   if(g_ictIntraday.trend != ICT_TREND_NONE &&
      (g_ictDailyBias.bias == ICT_BIAS_BULL || g_ictDailyBias.bias == ICT_BIAS_BEAR))
      return ICT_PANEL_CLR_MUTED;
   return ICT_PANEL_CLR_NEUTRAL;
}

color IctPanelEaStateColor()
{
   switch(g_ictEaState.category)
   {
      case ICT_EA_CAT_TRADE: return clrAqua;
      case ICT_EA_CAT_SETUP: return clrGold;
      default:               return ICT_PANEL_CLR_MUTED;
   }
}

void IctPanel_Clear()
{
   const long ch = ChartID();
   ObjectDelete(ch, ICT26_PANEL_LEGACY);
   for(int i = 0; i < ICT26_PANEL_MAXLINE; i++)
      ObjectDelete(ch, IctPanel_LineName(i));
}

void IctPanel_SetLine(const long ch, const int index, const int yOffset,
                      const string text, const color clr)
{
   const string name = IctPanel_LineName(index);
   if(ObjectFind(ch, name) < 0)
   {
      ObjectCreate(ch, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(ch, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(ch, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(ch, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(ch, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ch, name, OBJPROP_HIDDEN, false);
      ObjectSetInteger(ch, name, OBJPROP_BACK, false);
   }

   ObjectSetInteger(ch, name, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(ch, name, OBJPROP_YDISTANCE, InpPanelY + yOffset);
   ObjectSetInteger(ch, name, OBJPROP_FONTSIZE, InpPanelFontSize);
   ObjectSetInteger(ch, name, OBJPROP_COLOR, clr);
   ObjectSetString(ch, name, OBJPROP_TEXT, text);
}

void IctPanel_Render(const string sym)
{
   if(!InpDrawPanel)
   {
      IctPanel_Clear();
      return;
   }

   IctIntraday_UpdateAllowTrade();
   IctEaState_Refresh(sym);

   const long ch = ChartID();
   ObjectDelete(ch, ICT26_PANEL_LEGACY);
   const string dTag = IctTfBarPrefix(InpBiasTf);
   const string iTag = IctTfBarPrefix(InpIntradayTf);
   const int lh = IctPanel_LineHeight();

   const color clrBias    = IctPanelBiasDirectionColor(g_ictDailyBias.bias);
   const color clrIntra   = IctPanelIntradayDirectionColor(g_ictIntraday.trend);
   const color clrAllow   = IctPanelAllowTradeColor();
   const color clrEa      = IctPanelEaStateColor();

   string lines[];
   color  colors[];
   ArrayResize(lines, 0);
   ArrayResize(colors, 0);

   int n = 0;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("[%s] %s", IctEaState_CategoryText(g_ictEaState.category),
                           IctEaState_Code(g_ictEaState.state));
   colors[n++] = clrEa;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = IctEaState_TitleVi(g_ictEaState.state);
   colors[n++] = clrEa;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("Chi tiet: %s", g_ictEaState.detail);
   colors[n++] = clrEa;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = "-------------------------";
   colors[n++] = ICT_PANEL_CLR_NEUTRAL;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("ICT2026 %s | %s[0] chua dong", EnumToString(InpBiasTf), dTag);
   colors[n++] = ICT_PANEL_CLR_NEUTRAL;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("Bias: %s", IctBiasDisplayShort(g_ictDailyBias.bias));
   colors[n++] = clrBias;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("Ly do: %s", g_ictDailyBias.displayReason);
   colors[n++] = clrBias;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = "-------------------------";
   colors[n++] = ICT_PANEL_CLR_NEUTRAL;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("%s | %s[0] dang chay", EnumToString(InpIntradayTf), iTag);
   colors[n++] = ICT_PANEL_CLR_NEUTRAL;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("Intraday: %s", IctTrendDisplayShort(g_ictIntraday.trend));
   colors[n++] = clrIntra;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("Ly do: %s", g_ictIntraday.displayReason);
   colors[n++] = clrIntra;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("AllowTrade: %s | MSS phase: %s",
                           g_ictIntraday.isAllowTrade ? "YES" : "NO",
                           IctMssPhaseText(g_ictLowTf.mss.phase));
   colors[n++] = clrAllow;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = StringFormat("H1 FVG: %s", g_ictLowTf.displayReason);
   colors[n++] = (g_ictLowTf.availableCount > 0) ? ICT_PANEL_CLR_ALLOW : ICT_PANEL_CLR_MUTED;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = "-------------------------";
   colors[n++] = ICT_PANEL_CLR_NEUTRAL;

   const color clrStatsCounts = (g_ictMssStats.total > 0) ? ICT_PANEL_CLR_ALLOW : ICT_PANEL_CLR_MUTED;
   const color clrStatsPerf   = (g_ictMssStats.netProfit > 0.0) ? ICT_PANEL_CLR_UP :
                                (g_ictMssStats.netProfit < 0.0) ? ICT_PANEL_CLR_DOWN : ICT_PANEL_CLR_MUTED;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = IctMssStats_LineCounts();
   colors[n++] = clrStatsCounts;

   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n] = IctMssStats_LinePerf();
   colors[n++] = clrStatsPerf;

   for(int i = 0; i < n; i++)
      IctPanel_SetLine(ch, i, i * lh, lines[i], colors[i]);

   for(int i = n; i < ICT26_PANEL_MAXLINE; i++)
      ObjectDelete(ch, IctPanel_LineName(i));

   ChartRedraw(ch);
}

#endif
