//+------------------------------------------------------------------+
//|                                             Range1615_Buffer.mq5 |
//|  Range Max/Min 16:15-16:30, linee buffer, target 2.5x e size     |
//+------------------------------------------------------------------+
#property copyright   "AnyPS5"
#property version     "1.00"
#property description "Calcola Max/Min tra 16:15 e 16:30, disegna le linee buffer (+/- 10),"
#property description "la linea target a 2.5x il range e un box con la size per rischiare 20 USD"
#property description "(rischio = distanza tra buffer superiore e buffer inferiore)."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- unita' del buffer
enum ENUM_BUFFER_UNIT
  {
   UNIT_PRICE = 0, // Prezzo (10 = 10.0 punti indice)
   UNIT_POINT = 1, // Point MT5 (10 = 10 * _Point)
   UNIT_PIP   = 2  // Pip forex (10 = 10 pip)
  };

//--- base per il calcolo del target
enum ENUM_TARGET_BASE
  {
   BASE_RANGE = 0, // Range (Max - Min)
   BASE_STOP  = 1  // Stop (Buffer sup - Buffer inf)
  };

//--- da dove proiettare il target
enum ENUM_TARGET_ORIGIN
  {
   ORIGIN_BUFFER  = 0, // Dalla linea buffer
   ORIGIN_HIGHLOW = 1  // Dal Max/Min
  };

input group "Orari (ora del SERVER del broker)"
input string           InpStart        = "16:15";       // Inizio range (HH:MM)
input string           InpEnd          = "16:30";       // Fine range (HH:MM, esclusa)
input int              InpTimeShift    = 0;             // Sposta gli orari di N ore (ora server - ora tua)
input string           InpLinesEnd     = "23:59";       // Fine linee (HH:MM)

input group "Buffer"
input double           InpBuffer       = 10.0;          // Buffer
input ENUM_BUFFER_UNIT InpBufferUnit   = UNIT_PRICE;    // Unita' del buffer

input group "Target"
input double           InpTargetMult   = 2.5;           // Moltiplicatore target
input ENUM_TARGET_BASE InpTargetBase   = BASE_RANGE;    // Base del target
input ENUM_TARGET_ORIGIN InpTargetOrigin = ORIGIN_BUFFER; // Origine del target
input bool             InpShowTargetUp = true;          // Mostra target sopra
input bool             InpShowTargetDn = true;          // Mostra target sotto

input group "Rischio"
input double           InpRisk         = 20.0;          // Rischio per trade (valuta del conto)

input group "Grafica"
input int              InpDays         = 1;             // Giorni da mostrare
input color            InpColHighLow   = clrSilver;     // Colore Max/Min
input color            InpColBuffer    = clrDodgerBlue; // Colore buffer
input color            InpColTarget    = clrGold;       // Colore target
input color            InpColBox       = C'40,40,60';   // Colore rettangolo range
input int              InpPanelX       = 10;            // Box: distanza X
input int              InpPanelY       = 25;            // Box: distanza Y
input int              InpFontSize     = 10;            // Box: dimensione font
input color            InpPanelBg      = C'25,25,35';   // Box: sfondo
input color            InpPanelText    = clrWhite;      // Box: testo
input color            InpPanelSize    = clrLime;       // Box: colore size

#define PREFIX "R1615_"

int g_startSec = 0;
int g_endSec   = 0;
int g_linesSec = 0;
string g_daysKey = "";

//+------------------------------------------------------------------+
int ParseHHMM(const string s, const int def)
  {
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return def;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return def;
   return h * 3600 + m * 60;
  }

//+------------------------------------------------------------------+
double BufferInPrice()
  {
   switch(InpBufferUnit)
     {
      case UNIT_POINT:
         return InpBuffer * _Point;
      case UNIT_PIP:
         return InpBuffer * _Point * ((_Digits == 3 || _Digits == 5) ? 10.0 : 1.0);
     }
   return InpBuffer;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_startSec = ParseHHMM(InpStart, 16 * 3600 + 15 * 60);
   g_endSec   = ParseHHMM(InpEnd, 16 * 3600 + 30 * 60);
   g_linesSec = ParseHHMM(InpLinesEnd, 23 * 3600 + 59 * 60);
   if(g_endSec <= g_startSec)
     {
      Print("Orario di fine range deve essere dopo l'orario di inizio");
      return INIT_PARAMETERS_INCORRECT;
     }
   EventSetTimer(1);
   Update();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   Update();
   return rates_total;
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   Update();
  }

//+------------------------------------------------------------------+
//| Disegna range e linee per gli ultimi InpDays giorni               |
//+------------------------------------------------------------------+
void Update()
  {
   datetime now   = TimeTradeServer();
   datetime today = now - (now % 86400);
   int      found = 0;
   bool     panelDone = false;
   datetime days[];
   double   his[], los[];
   bool     forms[];

   for(int d = 0; d < InpDays * 3 + 7 && found < InpDays; d++)
     {
      datetime day   = today - d * 86400;
      datetime start = day + g_startSec + InpTimeShift * 3600;
      datetime end   = day + g_endSec + InpTimeShift * 3600;
      if(now < start)
         continue;                       // range di oggi non ancora iniziato

      MqlRates rates[];
      int n = CopyRates(_Symbol, PERIOD_M1, start, end - 1, rates);
      if(n <= 0)
         continue;                       // nessun dato (weekend/festivo o storico M1 non caricato)

      double hi = rates[0].high;
      double lo = rates[0].low;
      for(int i = 1; i < n; i++)
        {
         hi = MathMax(hi, rates[i].high);
         lo = MathMin(lo, rates[i].low);
        }

      ArrayResize(days, found + 1);
      ArrayResize(his, found + 1);
      ArrayResize(los, found + 1);
      ArrayResize(forms, found + 1);
      days[found]  = day;
      his[found]   = hi;
      los[found]   = lo;
      forms[found] = (now < end);
      found++;
     }

   //--- se l'insieme dei giorni e' cambiato, elimina le linee dei giorni vecchi
   string key = "";
   for(int i = 0; i < found; i++)
      key += TimeToString(days[i], TIME_DATE) + ";";
   if(key != g_daysKey)
     {
      ObjectsDeleteAll(0, PREFIX + "D");
      g_daysKey = key;
     }

   for(int i = 0; i < found; i++)
     {
      datetime start = days[i] + g_startSec + InpTimeShift * 3600;
      datetime end   = days[i] + g_endSec + InpTimeShift * 3600;
      DrawDay(days[i], start, end, his[i], los[i], forms[i]);
      if(!panelDone)
        {
         DrawPanel(days[i], his[i], los[i], forms[i]);
         panelDone = true;
        }
     }

   if(!panelDone)
      DrawPanelEmpty();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void CalcLevels(const double hi, const double lo,
                double &bufUp, double &bufDn, double &tgtUp, double &tgtDn)
  {
   double buf = BufferInPrice();
   bufUp = hi + buf;
   bufDn = lo - buf;

   double base = (InpTargetBase == BASE_RANGE) ? (hi - lo) : (bufUp - bufDn);
   double ext  = base * InpTargetMult;
   if(InpTargetOrigin == ORIGIN_BUFFER)
     {
      tgtUp = bufUp + ext;
      tgtDn = bufDn - ext;
     }
   else
     {
      tgtUp = hi + ext;
      tgtDn = lo - ext;
     }
  }

//+------------------------------------------------------------------+
void DrawDay(const datetime day, const datetime start, const datetime end,
             const double hi, const double lo, const bool forming)
  {
   string   tag     = PREFIX + "D" + TimeToString(day, TIME_DATE) + "_";
   datetime lineEnd = day + g_linesSec + InpTimeShift * 3600;
   if(lineEnd <= end)
      lineEnd += 86400;

   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(hi, lo, bufUp, bufDn, tgtUp, tgtDn);

   SetRect(tag + "box", start, hi, end, lo, InpColBox);

   SetLine(tag + "hi", start, lineEnd, hi, InpColHighLow, STYLE_SOLID, 1, "Max");
   SetLine(tag + "lo", start, lineEnd, lo, InpColHighLow, STYLE_SOLID, 1, "Min");
   SetLine(tag + "bufUp", start, lineEnd, bufUp, InpColBuffer, STYLE_DASH, 2, "Buffer +");
   SetLine(tag + "bufDn", start, lineEnd, bufDn, InpColBuffer, STYLE_DASH, 2, "Buffer -");

   string tgtName = "Target " + DoubleToString(InpTargetMult, 1) + "x";
   if(InpShowTargetUp)
      SetLine(tag + "tgtUp", start, lineEnd, tgtUp, InpColTarget, STYLE_DOT, 1, tgtName + " +");
   else
      DeleteLine(tag + "tgtUp");
   if(InpShowTargetDn)
      SetLine(tag + "tgtDn", start, lineEnd, tgtDn, InpColTarget, STYLE_DOT, 1, tgtName + " -");
   else
      DeleteLine(tag + "tgtDn");
  }

//+------------------------------------------------------------------+
void SetRect(const string name, const datetime t1, const double p1,
             const datetime t2, const double p2, const color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectMove(0, name, 0, t1, p1);
   ObjectMove(0, name, 1, t2, p2);
  }

//+------------------------------------------------------------------+
void SetLine(const string name, const datetime t1, const datetime t2, const double price,
             const color clr, const ENUM_LINE_STYLE style, const int width, const string text)
  {
   string txt = text + "  " + DoubleToString(price, _Digits);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, txt);
   ObjectMove(0, name, 0, t1, price);
   ObjectMove(0, name, 1, t2, price);

   string lbl = name + "_txt";
   if(ObjectFind(0, lbl) < 0)
     {
      ObjectCreate(0, lbl, OBJ_TEXT, 0, t2, price);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
     }
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
   ObjectSetString(0, lbl, OBJPROP_TEXT, txt);
   ObjectMove(0, lbl, 0, t2, price);
  }

//+------------------------------------------------------------------+
void DeleteLine(const string name)
  {
   ObjectDelete(0, name);
   ObjectDelete(0, name + "_txt");
  }

//+------------------------------------------------------------------+
//| Perdita per 1 lotto tra due prezzi, nella valuta del conto        |
//+------------------------------------------------------------------+
double LossPerLot(const double p1, const double p2)
  {
   double profit = 0.0;
   if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, MathMax(p1, p2), MathMin(p1, p2), profit)
      && profit != 0.0)
      return MathAbs(profit);

   //--- fallback: tick value / tick size
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return MathAbs(p1 - p2) / tickSize * tickValue;
  }

//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
     {
      s *= 10.0;
      digits++;
     }
   return digits;
  }

//+------------------------------------------------------------------+
void DrawPanel(const datetime day, const double hi, const double lo, const bool forming)
  {
   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(hi, lo, bufUp, bufDn, tgtUp, tgtDn);

   double stopDist   = bufUp - bufDn;
   double lossPerLot = LossPerLot(bufUp, bufDn);
   double volMin     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0)
      volStep = 0.01;
   int    volDigits  = VolumeDigits(volStep);
   string cur        = AccountInfoString(ACCOUNT_CURRENCY);

   string sizeTxt, riskTxt;
   color  sizeClr = InpPanelSize;
   if(lossPerLot <= 0.0)
     {
      sizeTxt = "SIZE: n.d. (dati simbolo mancanti)";
      riskTxt = "";
      sizeClr = clrOrangeRed;
     }
   else
     {
      double raw  = InpRisk / lossPerLot;
      double lots = MathFloor(raw / volStep + 1e-9) * volStep;
      if(volMax > 0.0)
         lots = MathMin(lots, volMax);
      if(lots < volMin)
        {
         sizeTxt = "SIZE: < min (" + DoubleToString(volMin, volDigits) + " lotti)";
         riskTxt = "Rischio a lotto min: " + DoubleToString(volMin * lossPerLot, 2) + " " + cur;
         sizeClr = clrOrangeRed;
        }
      else
        {
         sizeTxt = "SIZE: " + DoubleToString(lots, volDigits) + " lotti";
         riskTxt = "Rischio effettivo: " + DoubleToString(lots * lossPerLot, 2) + " " + cur;
        }
     }

   string lines[];
   color  colors[];
   string tgt = DoubleToString(InpTargetMult, 1) + "x";
   AddRow(lines, colors, "RANGE " + InpStart + "-" + InpEnd + "  " + TimeToString(day, TIME_DATE)
          + (forming ? "  (in formazione)" : ""), clrGold);
   AddRow(lines, colors, "Max: " + DoubleToString(hi, _Digits) + "   Min: " + DoubleToString(lo, _Digits), InpPanelText);
   AddRow(lines, colors, "Range: " + DoubleToString(hi - lo, _Digits), InpPanelText);
   AddRow(lines, colors, "Buffer +: " + DoubleToString(bufUp, _Digits), InpColBuffer);
   AddRow(lines, colors, "Buffer -: " + DoubleToString(bufDn, _Digits), InpColBuffer);
   AddRow(lines, colors, "Target " + tgt + " +: " + DoubleToString(tgtUp, _Digits), InpColTarget);
   AddRow(lines, colors, "Target " + tgt + " -: " + DoubleToString(tgtDn, _Digits), InpColTarget);
   AddRow(lines, colors, "Stop (buffer-buffer): " + DoubleToString(stopDist, _Digits), InpPanelText);
   AddRow(lines, colors, "Rischio: " + DoubleToString(InpRisk, 2) + " " + cur, InpPanelText);
   AddRow(lines, colors, sizeTxt, sizeClr);
   if(riskTxt != "")
      AddRow(lines, colors, riskTxt, InpPanelText);
   if(cur != "USD")
      AddRow(lines, colors, "Attenzione: conto in " + cur + ", non USD", clrOrangeRed);

   RenderPanel(lines, colors);
  }

//+------------------------------------------------------------------+
void DrawPanelEmpty()
  {
   string lines[];
   color  colors[];
   AddRow(lines, colors, "RANGE " + InpStart + "-" + InpEnd, clrGold);
   AddRow(lines, colors, "Nessun dato M1 per il range", InpPanelText);
   AddRow(lines, colors, "(attendi o controlla orari/fuso server)", InpPanelText);
   RenderPanel(lines, colors);
  }

//+------------------------------------------------------------------+
void AddRow(string &lines[], color &colors[], const string text, const color clr)
  {
   int n = ArraySize(lines);
   ArrayResize(lines, n + 1);
   ArrayResize(colors, n + 1);
   lines[n]  = text;
   colors[n] = clr;
  }

//+------------------------------------------------------------------+
void RenderPanel(const string &lines[], const color &colors[])
  {
   int rows   = ArraySize(lines);
   int lineH  = (int)MathRound(InpFontSize * 1.9);
   int pad    = 8;
   int maxLen = 0;
   for(int i = 0; i < rows; i++)
      maxLen = MathMax(maxLen, StringLen(lines[i]));
   int width  = (int)MathRound(maxLen * InpFontSize * 0.8) + pad * 2;
   int height = rows * lineH + pad * 2;

   string bg = PREFIX + "panel_bg";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpPanelBg);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);

   for(int i = 0; i < rows; i++)
     {
      string name = PREFIX + "panel_row" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
        }
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + pad);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + pad + i * lineH);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_COLOR, colors[i]);
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);
     }

   //--- rimuove righe avanzate da un disegno precedente
   for(int i = rows; i < 30; i++)
      ObjectDelete(0, PREFIX + "panel_row" + IntegerToString(i));
  }
//+------------------------------------------------------------------+
