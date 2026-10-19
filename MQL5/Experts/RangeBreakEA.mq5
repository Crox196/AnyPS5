//+------------------------------------------------------------------+
//|                                                 RangeBreakEA.mq5 |
//|  EA per il backtest della strategia RangeBreak                   |
//+------------------------------------------------------------------+
#property copyright   "AnyPS5"
#property version     "1.00"
#property description "RangeBreak EA - breakout del range 16:15-16:30."
#property description "Buy Stop sul buffer +, Sell Stop sul buffer -, stop sul buffer opposto,"
#property description "TP a 2.5x il range, size a rischio fisso. Il primo che entra cancella l'altro."

#include <Trade\Trade.mqh>

//--- unita' del buffer
enum ENUM_BUFFER_UNIT
  {
   UNIT_PRICE = 0, // Prezzo (15 = 15.0 punti indice)
   UNIT_POINT = 1, // Point MT5 (15 = 15 * _Point)
   UNIT_PIP   = 2  // Pip forex (15 = 15 pip)
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
input string             InpStart        = "16:15";       // Inizio range (HH:MM)
input string             InpEnd          = "16:30";       // Fine range (HH:MM, esclusa)
input int                InpTimeShift    = 0;             // Sposta gli orari di N ore (ora server - ora tua)
input string             InpCloseTime    = "23:59";       // Chiusura forzata trade e ordini (HH:MM)

input group "Buffer"
input double             InpBuffer       = 15.0;          // Buffer
input ENUM_BUFFER_UNIT   InpBufferUnit   = UNIT_PRICE;    // Unita' del buffer

input group "Target"
input double             InpTargetMult   = 2.5;           // Moltiplicatore target
input ENUM_TARGET_BASE   InpTargetBase   = BASE_RANGE;    // Base del target
input ENUM_TARGET_ORIGIN InpTargetOrigin = ORIGIN_BUFFER; // Origine del target

input group "Rischio"
input double             InpRisk         = 20.0;          // Rischio per trade (valuta del conto)
input bool               InpSkipBelowMin = true;          // Salta il trade se la size e' sotto il lotto minimo

input group "Trading"
input bool               InpTradeLong    = true;          // Abilita long (Buy Stop sul buffer +)
input bool               InpTradeShort   = true;          // Abilita short (Sell Stop sul buffer -)
input ulong              InpMagic        = 161530;        // Magic number
input bool               InpDrawLevels   = true;          // Disegna range e livelli (tester visuale)

#define PREFIX "RBEA_"

CTrade   g_trade;
int      g_startSec = 0;
int      g_endSec   = 0;
int      g_closeSec = 0;
datetime g_day      = 0;       // giorno corrente
bool     g_placed   = false;   // ordini del giorno gia' piazzati
datetime g_closeAt  = 0;       // chiusura forzata del trade in corso

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
double NormPrice(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
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
//| Size per rischiare InpRisk tra i due buffer (0 = non tradare)     |
//+------------------------------------------------------------------+
double CalcLots(const double lossPerLot)
  {
   if(lossPerLot <= 0.0)
      return 0.0;
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0)
      volStep = 0.01;

   double lots = MathFloor(InpRisk / lossPerLot / volStep + 1e-9) * volStep;
   if(volMax > 0.0)
      lots = MathMin(lots, volMax);
   if(lots < volMin)
     {
      if(InpSkipBelowMin)
         return 0.0;
      lots = volMin;
     }
   return NormalizeDouble(lots, VolumeDigits(volStep));
  }

//+------------------------------------------------------------------+
string MonthName(const int mon)
  {
   static const string names[12] = {"Gennaio", "Febbraio", "Marzo", "Aprile", "Maggio", "Giugno",
                                     "Luglio", "Agosto", "Settembre", "Ottobre", "Novembre", "Dicembre"};
   return (mon >= 1 && mon <= 12) ? names[mon - 1] : "Mese";
  }

//+------------------------------------------------------------------+
string FormatPnl(const double v)
  {
   return (v > 0.0 ? "+" : "") + DoubleToString(v, 2);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_startSec = ParseHHMM(InpStart, 16 * 3600 + 15 * 60);
   g_endSec   = ParseHHMM(InpEnd, 16 * 3600 + 30 * 60);
   g_closeSec = ParseHHMM(InpCloseTime, 23 * 3600 + 59 * 60);
   if(g_endSec <= g_startSec)
     {
      Print("Orario di fine range deve essere dopo l'orario di inizio");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(!MQLInfoInteger(MQL_TESTER))
      ObjectsDeleteAll(0, PREFIX);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   //--- chiusura forzata: chiude il trade e cancella gli ordini rimasti
   if(g_closeAt > 0 && now >= g_closeAt)
     {
      CloseAll();
      g_closeAt = 0;
     }

   //--- OCO: appena un ordine entra, cancella l'altro
   if(HasPosition())
      DeletePendings();

   datetime day = now - (now % 86400);
   if(day != g_day)
     {
      g_day    = day;
      g_placed = false;
     }

   datetime start  = day + g_startSec + InpTimeShift * 3600;
   datetime end    = day + g_endSec + InpTimeShift * 3600;
   datetime closeT = day + g_closeSec + InpTimeShift * 3600;
   if(closeT <= end)
      closeT += 86400;

   if(g_placed || now < end || now >= closeT)
      return;
   g_placed = true;
   PlaceOrders(start, end, closeT);
  }

//+------------------------------------------------------------------+
void PlaceOrders(const datetime start, const datetime end, const datetime closeT)
  {
   MqlRates rates[];
   int n = CopyRates(_Symbol, PERIOD_M1, start, end - 1, rates);
   if(n <= 0)
     {
      PrintFormat("RangeBreak %s: nessun dato M1 per il range, giorno saltato",
                  TimeToString(start, TIME_DATE));
      return;
     }

   double hi = rates[0].high;
   double lo = rates[0].low;
   for(int i = 1; i < n; i++)
     {
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
     }

   double bufUp, bufDn, tgtUp, tgtDn;
   CalcLevels(hi, lo, bufUp, bufDn, tgtUp, tgtDn);
   bufUp = NormPrice(bufUp);
   bufDn = NormPrice(bufDn);
   tgtUp = NormPrice(tgtUp);
   tgtDn = NormPrice(tgtDn);

   if(InpDrawLevels)
      DrawLevels(start, end, closeT, hi, lo, bufUp, bufDn, tgtUp, tgtDn);

   double lots = CalcLots(LossPerLot(bufUp, bufDn));
   if(lots <= 0.0)
     {
      PrintFormat("RangeBreak %s: size sotto il lotto minimo (stop %s), giorno saltato",
                  TimeToString(start, TIME_DATE), DoubleToString(bufUp - bufDn, _Digits));
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(InpTradeLong)
     {
      if(ask < bufUp)
        {
         if(!g_trade.BuyStop(lots, bufUp, _Symbol, bufDn, tgtUp, ORDER_TIME_GTC, 0, "RangeBreak long"))
            PrintFormat("RangeBreak: Buy Stop fallito, errore %d", g_trade.ResultRetcode());
        }
      else
         Print("RangeBreak: prezzo gia' sopra il buffer +, long saltato");
     }

   if(InpTradeShort)
     {
      if(bid > bufDn)
        {
         if(!g_trade.SellStop(lots, bufDn, _Symbol, bufUp, tgtDn, ORDER_TIME_GTC, 0, "RangeBreak short"))
            PrintFormat("RangeBreak: Sell Stop fallito, errore %d", g_trade.ResultRetcode());
        }
      else
         Print("RangeBreak: prezzo gia' sotto il buffer -, short saltato");
     }

   g_closeAt = closeT;
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void DeletePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == (long)InpMagic
         && OrderGetString(ORDER_SYMBOL) == _Symbol)
         g_trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
void CloseAll()
  {
   DeletePendings();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic
         && PositionGetString(POSITION_SYMBOL) == _Symbol)
         g_trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
void DrawLevels(const datetime start, const datetime end, const datetime closeT,
                const double hi, const double lo, const double bufUp, const double bufDn,
                const double tgtUp, const double tgtDn)
  {
   string tag = PREFIX + TimeToString(start, TIME_DATE) + "_";

   string box = tag + "box";
   ObjectCreate(0, box, OBJ_RECTANGLE, 0, start, hi, end, lo);
   ObjectSetInteger(0, box, OBJPROP_COLOR, C'40,40,60');
   ObjectSetInteger(0, box, OBJPROP_FILL, true);
   ObjectSetInteger(0, box, OBJPROP_BACK, true);

   DrawLine(tag + "hi", start, closeT, hi, clrSilver, STYLE_SOLID);
   DrawLine(tag + "lo", start, closeT, lo, clrSilver, STYLE_SOLID);
   DrawLine(tag + "bufUp", start, closeT, bufUp, clrDodgerBlue, STYLE_DASH);
   DrawLine(tag + "bufDn", start, closeT, bufDn, clrDodgerBlue, STYLE_DASH);
   DrawLine(tag + "tgtUp", start, closeT, tgtUp, clrGold, STYLE_DOT);
   DrawLine(tag + "tgtDn", start, closeT, tgtDn, clrGold, STYLE_DOT);
  }

//+------------------------------------------------------------------+
void DrawLine(const string name, const datetime t1, const datetime t2, const double price,
              const color clr, const ENUM_LINE_STYLE style)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
  }

//+------------------------------------------------------------------+
//| Fine backtest: riepilogo mensile nel diario del tester            |
//+------------------------------------------------------------------+
double OnTester()
  {
   PrintMonthlyReport();
   return TesterStatistics(STAT_PROFIT);
  }

//+------------------------------------------------------------------+
void PrintMonthlyReport()
  {
   if(!HistorySelect(0, TimeCurrent()))
      return;

   int    keys[];
   int    tp[];
   int    sl[];
   int    other[];
   double pnl[];
   int    months = 0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagic
         || HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      MqlDateTime dt;
      TimeToStruct((datetime)HistoryDealGetInteger(ticket, DEAL_TIME), dt);
      int key = dt.year * 100 + dt.mon;
      if(months == 0 || keys[months - 1] != key)
        {
         months++;
         ArrayResize(keys, months);
         ArrayResize(tp, months);
         ArrayResize(sl, months);
         ArrayResize(other, months);
         ArrayResize(pnl, months);
         keys[months - 1]  = key;
         tp[months - 1]    = 0;
         sl[months - 1]    = 0;
         other[months - 1] = 0;
         pnl[months - 1]   = 0.0;
        }
      int m = months - 1;

      //--- profitto netto (anche la commissione d'entrata)
      pnl[m] += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                + HistoryDealGetDouble(ticket, DEAL_SWAP)
                + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;
      long reason = HistoryDealGetInteger(ticket, DEAL_REASON);
      if(reason == DEAL_REASON_TP)
         tp[m]++;
      else if(reason == DEAL_REASON_SL)
         sl[m]++;
      else
         other[m]++;
     }

   string cur   = AccountInfoString(ACCOUNT_CURRENCY);
   double total = 0.0;
   Print("===== RangeBreak BACKTEST =====");
   for(int m = 0; m < months; m++)
     {
      total += pnl[m];
      PrintFormat("%s %d: %d TP / %d Stop / %d Chiusura forzata = %s %s",
                  MonthName(keys[m] % 100), keys[m] / 100, tp[m], sl[m], other[m],
                  FormatPnl(pnl[m]), cur);
     }
   PrintFormat("Totale: %s %s", FormatPnl(total), cur);
  }
//+------------------------------------------------------------------+
