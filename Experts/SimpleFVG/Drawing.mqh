//+------------------------------------------------------------------+
//| Drawing.mqh – Step 4: Visualize FVG zones, EMA info, trend panel   |
//+------------------------------------------------------------------+
#ifndef __SIMPLE_FVG_DRAWING_MQH__
#define __SIMPLE_FVG_DRAWING_MQH__

#include "Config.mqh"
#include "Trend.mqh"
#include "FVG.mqh"

//+------------------------------------------------------------------+
//| Object-creation helpers                                            |
//+------------------------------------------------------------------+
void DrawRectangle(string name,
                   datetime timeStart, double priceTop,
                   datetime timeEnd,   double priceBot,
                   color    clr,       bool   filled = true)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, timeStart, priceTop, timeEnd, priceBot);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,  filled);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectMove(0, name, 0, timeStart, priceTop);
   ObjectMove(0, name, 1, timeEnd,   priceBot);
}

void DrawTrendLine(string   name,
                   datetime t1, double p1,
                   datetime t2, double p2,
                   color clr, int style, int width)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);

   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectMove(0, name, 0, t1, p1);
   ObjectMove(0, name, 1, t2, p2);
}

void DrawLabel(string name, int xDist, int yDist,
               string text, color clr, int fontSize)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xDist);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yDist);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetString (0, name, OBJPROP_FONT,      "Consolas");
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawTextOnChart(string name, datetime t, double price,
                     string text, color clr, int fontSize, int anchor)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);

   ObjectMove(0, name, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,     text);
   ObjectSetString (0, name, OBJPROP_FONT,     "Arial");
   ObjectSetInteger(0, name, OBJPROP_COLOR,    clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,   anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Draw all active FVG zones as rectangles on the chart               |
//+------------------------------------------------------------------+
void DrawFVGZones()
{
   ObjectsDeleteAll(0, EA_PREFIX + "FVG_");

   string   symbol     = GetTradeSymbol();
   datetime currentBar = iTime(symbol, InpTimeframe, 0);

   for(int i = 0; i < g_FVGCount; i++)
   {
      if(!g_FVGZones[i].isActive)
         continue;

      string zoneId = IntegerToString(i);

      //--- Zone color depends on type and mitigation status ---
      color zoneColor;
      if(g_FVGZones[i].isMitigated)
         zoneColor = InpColorMitigatedFVG;
      else if(g_FVGZones[i].type == FVG_BULLISH)
         zoneColor = InpColorBullFVG;
      else
         zoneColor = InpColorBearFVG;

      //--- Draw filled rectangle for the FVG zone ---
      DrawRectangle(
         EA_PREFIX + "FVG_ZONE_" + zoneId,
         g_FVGZones[i].createdTime, g_FVGZones[i].upperEdge,
         currentBar,                g_FVGZones[i].lowerEdge,
         zoneColor, true
      );

      //--- Draw mid-line (50% of FVG) ---
      double midPrice = (g_FVGZones[i].upperEdge + g_FVGZones[i].lowerEdge) / 2.0;
      color  midColor = g_FVGZones[i].isMitigated ? clrDimGray : clrGold;

      DrawTrendLine(
         EA_PREFIX + "FVG_MID_" + zoneId,
         g_FVGZones[i].createdTime, midPrice,
         currentBar,                midPrice,
         midColor, STYLE_DOT, 1
      );

      //--- Draw text label ---
      if(InpShowFVGLabels)
      {
         string typeStr  = (g_FVGZones[i].type == FVG_BULLISH) ? "BULL" : "BEAR";
         string arrow    = (g_FVGZones[i].type == FVG_BULLISH) ? "▲"   : "▼";
         string mitigStr = g_FVGZones[i].isMitigated ? " [MITIGATED]" : "";

         color labelColor;
         if(g_FVGZones[i].isMitigated)
            labelColor = clrDimGray;
         else if(g_FVGZones[i].type == FVG_BULLISH)
            labelColor = clrDeepSkyBlue;
         else
            labelColor = clrOrangeRed;

         DrawTextOnChart(
            EA_PREFIX + "FVG_LBL_" + zoneId,
            g_FVGZones[i].createdTime,
            g_FVGZones[i].upperEdge,
            StringFormat("%s %s [%.2f–%.2f]%s",
                         arrow, typeStr,
                         g_FVGZones[i].lowerEdge, g_FVGZones[i].upperEdge,
                         mitigStr),
            labelColor, 7, ANCHOR_LEFT_LOWER
         );
      }
   }
}

//+------------------------------------------------------------------+
//| Draw info panel (top-left corner)                                  |
//+------------------------------------------------------------------+
void DrawInfoPanel()
{
   if(!InpShowPanel) return;

   int bullCount     = CountActiveFVGs(FVG_BULLISH);
   int bearCount     = CountActiveFVGs(FVG_BEARISH);
   int mitigCount    = CountMitigatedFVGs();
   string trendText  = TrendToString(g_CurrentTrend);
   color  trendColor = TrendToColor(g_CurrentTrend);

   //--- Row 1: EA header ---
   DrawLabel(EA_PREFIX + "PNL_HDR", 12, 22,
      StringFormat("SimpleFVG | %s %s",
                   GetTradeSymbol(), EnumToString(InpTimeframe)),
      clrSilver, 10);

   //--- Row 2: Trend status ---
   DrawLabel(EA_PREFIX + "PNL_TREND", 12, 44,
      StringFormat("Trend: %s  |  EMA%d = %.2f  |  EMA%d = %.2f",
                   trendText,
                   InpEMAFastPeriod, g_EMAFastValue,
                   InpEMASlowPeriod, g_EMASlowValue),
      trendColor, 9);

   //--- Row 3: FVG counts ---
   DrawLabel(EA_PREFIX + "PNL_FVG", 12, 66,
      StringFormat("FVG Active: %d Bull + %d Bear  |  Mitigated: %d",
                   bullCount, bearCount, mitigCount),
      clrWheat, 9);
}

//+------------------------------------------------------------------+
//| Master draw: call all draw functions                                |
//+------------------------------------------------------------------+
void DrawAll()
{
   DrawFVGZones();
   DrawInfoPanel();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Clean up all drawn objects                                         |
//+------------------------------------------------------------------+
void DrawCleanup()
{
   ObjectsDeleteAll(0, EA_PREFIX);
   ChartRedraw(0);
}

#endif
