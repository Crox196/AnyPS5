//+------------------------------------------------------------------+
//|                                             Range1615_Buffer.mq5 |
//|  Range Max/Min 16:15-16:30, linee buffer, target 2.5x e size     |
//+------------------------------------------------------------------+
#property copyright   "AnyPS5"
#property version     "1.00"
#property description "RangeBreak - Calcola Max/Min tra 16:15 e 16:30, disegna le linee buffer (+/- 10),"
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
input int              InpDays         = 95;            // Giorni da mostrare (oggi + precedenti)
input bool             InpShowResults  = true;          // Colora esito breakout (verde TP / rosso stop)
input color            InpColWin       = C'0,110,0';    // Colore esito TP
input color            InpColLoss      = C'140,0,0';    // Colore esito stop
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

//--- esito del breakout di un giorno
#define RES_NONE 0   // nessun buffer toccato
#define RES_WIN  1   // target raggiunto prima dello stop
#define RES_LOSS 2   // stop preso, o target non raggiunto entro fine linee
#define RES_OPEN 3   // trade ancora in corso

struct DayData
  {
   datetime          day;
   double            hi;
   double            lo;
   bool              forming;
   int               res;
   int               dir;     // +1 long (buffer +), -1 short (buffer -)
   datetime          tIn;
   datetime          tOut;
   bool              done;    // niente piu' da ricalcolare
  };

DayData g_cache[];            // giorni chiusi gia' calcolati

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
   IndicatorSetString(INDICATOR_SHORTNAME, "RangeBreak");
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
datetime RangeStart(const datetime day) { return day + g_startSec + InpTimeShift * 3600; }
datetime RangeEnd(const datetime day)   { return day + g_endSec + InpTimeShift * 3600; }

datetime LinesEnd(const datetime day)
  {
   datetime t = day + g_linesSec + InpTimeShift * 3600;
   if(t <= RangeEnd(day))
      t += 86400;
   return t;
  }

//+------------------------------------------------------------------+
bool FindCached(const datetime day, DayData &out)
  {
   for(int i = 0; i < ArraySize(g_cache); i++)
      if(g_cache[i].day == day)
        {
         out = g_cache[i];
         return true;
        }
   return false;
  }

//+------------------------------------------------------------------+
//| Simula il breakout: primo buffer toccato = entrata, stop = buffer |
//| opposto, TP = target. Se TP e stop sono nella stessa candela M1   |
//| conta come stop.                                                   |
//+------------------------------------------------------------------+
bool EvalTrade(DayData &dd, const datetime now)
  {
   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(dd.hi, dd.lo, bufUp, bufDn, tgtUp, tgtDn);
   datetime lineEnd = LinesEnd(dd.day);

   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, RangeEnd(dd.day), lineEnd - 1, r);
   if(n < 0)
      return false;

   for(int i = 0; i < n; i++)
     {
      if(dd.dir == 0)
        {
         bool up = (r[i].high >= bufUp);
         bool dn = (r[i].low <= bufDn);
         if(!up && !dn)
            continue;
         if(up && dn)
            dd.dir = (MathAbs(r[i].open - bufUp) <= MathAbs(r[i].open - bufDn)) ? 1 : -1;
         else
            dd.dir = up ? 1 : -1;
         dd.tIn = r[i].time;
        }
      bool sl = (dd.dir > 0) ? (r[i].low <= bufDn) : (r[i].high >= bufUp);
      bool tp = (dd.dir > 0) ? (r[i].high >= tgtUp) : (r[i].low <= tgtDn);
      if(sl || tp)
        {
         dd.res  = sl ? RES_LOSS : RES_WIN;
         dd.tOut = r[i].time + 60;
         return true;
        }
     }

   if(dd.dir == 0)
      dd.res = RES_NONE;
   else if(now >= lineEnd)
     {
      dd.res  = RES_LOSS;
      dd.tOut = lineEnd;
     }
   else
      dd.res = RES_OPEN;
   return true;
  }

//+------------------------------------------------------------------+
bool ComputeDay(const datetime day, const datetime now, DayData &dd)
  {
   datetime start = RangeStart(day);
   datetime end   = RangeEnd(day);
   if(now < start)
      return false;                      // range non ancora iniziato

   MqlRates rates[];
   int n = CopyRates(_Symbol, PERIOD_M1, start, end - 1, rates);
   if(n <= 0)
      return false;                      // nessun dato (festivo o storico M1 non caricato)

   dd.hi = rates[0].high;
   dd.lo = rates[0].low;
   for(int i = 1; i < n; i++)
     {
      dd.hi = MathMax(dd.hi, rates[i].high);
      dd.lo = MathMin(dd.lo, rates[i].low);
     }
   dd.day     = day;
   dd.forming = (now < end);
   dd.res     = RES_NONE;
   dd.dir     = 0;
   dd.tIn     = 0;
   dd.tOut    = 0;
   dd.done   = false;

   if(!dd.forming && EvalTrade(dd, now))
      dd.done = (dd.res == RES_WIN || dd.res == RES_LOSS || now >= LinesEnd(day));
   return true;
  }

//+------------------------------------------------------------------+
//| Disegna range e linee per gli ultimi InpDays giorni               |
//+------------------------------------------------------------------+
void Update()
  {
   datetime now = TimeTradeServer();
   DayData  list[];
   bool     cached[];
   int      found = 0;

   for(int k = 0; k < InpDays + 15 && found < InpDays; k++)
     {
      datetime d1 = iTime(_Symbol, PERIOD_D1, k);
      if(d1 == 0)
         break;
      datetime day = d1 - (d1 % 86400);
      DayData  dd;
      bool     fromCache = FindCached(day, dd);
      if(!fromCache && !ComputeDay(day, now, dd))
         continue;
      ArrayResize(list, found + 1);
      ArrayResize(cached, found + 1);
      list[found]   = dd;
      cached[found] = fromCache;
      found++;
     }

   //--- tiene in cache solo i giorni chiusi ancora visibili
   ArrayResize(g_cache, 0);
   for(int i = 0; i < found; i++)
      if(list[i].done)
        {
         int c = ArraySize(g_cache);
         ArrayResize(g_cache, c + 1);
         g_cache[c] = list[i];
        }

   //--- se l'insieme dei giorni e' cambiato, elimina e ridisegna tutto
   string key = "";
   for(int i = 0; i < found; i++)
      key += TimeToString(list[i].day, TIME_DATE) + ";";
   bool redrawAll = (key != g_daysKey);
   if(redrawAll)
     {
      ObjectsDeleteAll(0, PREFIX + "D");
      g_daysKey = key;
     }

   for(int i = 0; i < found; i++)
      if(redrawAll || !cached[i])
         DrawDay(list[i]);

   if(found > 0)
      DrawPanel(list[0].hi, list[0].lo, list[0].forming);
   else
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
void DrawDay(const DayData &dd)
  {
   string   tag     = PREFIX + "D" + TimeToString(dd.day, TIME_DATE) + "_";
   datetime start   = RangeStart(dd.day);
   datetime end     = RangeEnd(dd.day);
   datetime lineEnd = LinesEnd(dd.day);
   double   hi      = dd.hi;
   double   lo      = dd.lo;

   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(hi, lo, bufUp, bufDn, tgtUp, tgtDn);

   //--- esito: rettangolo dal buffer di entrata al target
   string resName = tag + "res";
   if(InpShowResults && (dd.res == RES_WIN || dd.res == RES_LOSS))
      SetRect(resName, dd.tIn, (dd.dir > 0) ? bufUp : bufDn,
              dd.tOut, (dd.dir > 0) ? tgtUp : tgtDn,
              (dd.res == RES_WIN) ? InpColWin : InpColLoss);
   else
      ObjectDelete(0, resName);

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
void DrawPanel(const double hi, const double lo, const bool forming)
  {
   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(hi, lo, bufUp, bufDn, tgtUp, tgtDn);

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
      sizeTxt = "Size: n.d. (dati simbolo mancanti)";
      riskTxt = "Rischio effettivo: n.d.";
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
         sizeTxt = "Size: < min (" + DoubleToString(volMin, volDigits) + " lotti)";
         riskTxt = "Rischio effettivo: " + DoubleToString(volMin * lossPerLot, 2) + " " + cur + " (lotto min)";
         sizeClr = clrOrangeRed;
        }
      else
        {
         sizeTxt = "Size: " + DoubleToString(lots, volDigits) + " lotti";
         riskTxt = "Rischio effettivo: " + DoubleToString(lots * lossPerLot, 2) + " " + cur;
        }
     }

   string lines[];
   color  colors[];
   AddRow(lines, colors, "RangeBreak", clrGold);
   AddRow(lines, colors, "Rischio: " + DoubleToString(InpRisk, 2) + " " + cur, InpPanelText);
   AddRow(lines, colors, "Range: " + DoubleToString(hi - lo, _Digits) + (forming ? " (in formazione)" : ""), InpPanelText);
   AddRow(lines, colors, sizeTxt, sizeClr);
   AddRow(lines, colors, riskTxt, InpPanelText);

   RenderPanel(lines, colors);
  }

//+------------------------------------------------------------------+
void DrawPanelEmpty()
  {
   string lines[];
   color  colors[];
   AddRow(lines, colors, "RangeBreak", clrGold);
   AddRow(lines, colors, "Rischio: " + DoubleToString(InpRisk, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY), InpPanelText);
   AddRow(lines, colors, "Range: n.d. (nessun dato M1)", InpPanelText);
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
