//+------------------------------------------------------------------+
//|                                            TrendScalperEA.mq5    |
//|                  Native MQL5 scalping EA for TrendScalperPro     |
//|                                                                  |
//|  Workflow                                                        |
//|    1. Loads the TrendScalperPro indicator through iCustom and    |
//|       reads buffer 2 (BuySignal) and buffer 3 (SellSignal) on    |
//|       the *last closed* bar.                                     |
//|    2. On a fresh flip signal it opens a single market trade in   |
//|       the trend direction, sized by fixed lot or risk %.         |
//|    3. ATR-based dynamic SL/TP, optional breakeven + trailing.    |
//|    4. Safety filters: spread, session hours, weekday, news       |
//|       blackout windows, daily-trade cap, post-loss cooldown,     |
//|       equity guard with auto-flatten.                            |
//|                                                                  |
//|  All inputs are commented so future tweaks are obvious.          |
//+------------------------------------------------------------------+
#property copyright   "TrendScalperEA - Devin / andreslpxz"
#property link        "https://github.com/andreslpxz/MT5"
#property version     "1.00"
#property description "Scalping EA driven by TrendScalperPro trend-flip signals."
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group           "=== Indicator (must mirror chart settings) ==="
input string          InpIndicatorName     = "TrendScalperPro"; // Indicator file (no .ex5)
input int             InpSwingDepth        = 5;                  // Swing depth
input int             InpEMAFilter         = 50;                 // EMA filter (0 = off)
input int             InpATRPeriod         = 14;                 // ATR period
input double          InpATRMinMove        = 0.25;               // ATR sensitivity

input group           "=== Position sizing ==="
input bool            InpUseRiskPercent    = false;   // Size by % equity risked on SL (false = fixed lot)
input double          InpFixedLot          = 0.01;    // Fixed lot size when not risk-based
input double          InpRiskPercent       = 0.5;     // Risk % of equity per trade
input double          InpMaxLot            = 5.0;     // Hard cap on lot size
input int             InpMaxOpenPositions  = 1;       // Max simultaneous positions on this symbol/magic

input group           "=== Stops, targets, trailing ==="
input double          InpSL_ATRmult        = 1.5;     // SL = ATR * mult
input double          InpTP_ATRmult        = 2.0;     // TP = ATR * mult
input int             InpMinStopPoints     = 80;      // Hard min SL/TP in points (broker safety)
input bool            InpUseBreakeven      = true;    // Move SL to BE after BE_ATRmult * ATR profit
input double          InpBE_ATRmult        = 1.0;     // Profit threshold for BE move (ATR units)
input int             InpBE_OffsetPoints   = 5;       // BE offset (lock a tiny profit) in points
input bool            InpUseTrailing       = true;    // Enable trailing stop
input double          InpTrail_ATRmult     = 1.0;     // Trailing stop distance in ATR units

input group           "=== Trade execution / spread ==="
input ulong           InpMagic             = 20260515; // Magic number
input ulong           InpDeviationPoints   = 10;       // Max slippage in points
input int             InpMaxSpreadPoints   = 30;       // Skip trade if spread > this (points). 0 = disabled
input string          InpTradeComment      = "TrendScalperEA";

input group           "=== Session filter (server time) ==="
input bool            InpUseSessionFilter  = true;     // Limit to hour window below
input int             InpStartHour         = 7;        // Session start hour [0..23]
input int             InpEndHour           = 20;       // Session end hour [0..23]; if <= start, wraps midnight
input bool            InpTradeMonday       = true;
input bool            InpTradeTuesday      = true;
input bool            InpTradeWednesday    = true;
input bool            InpTradeThursday     = true;
input bool            InpTradeFriday       = true;
input bool            InpTradeSaturday     = false;
input bool            InpTradeSunday       = false;

input group           "=== Safety: news, equity guard, cooldown ==="
input string          InpNewsPauseTimes    = "";       // Comma-sep HH:MM list, e.g. "13:30,15:00"
input int             InpNewsPauseMinutes  = 30;       // Window size around each news time
input bool            InpEquityGuardOn     = true;     // Daily equity guard
input double          InpEquityGuardPct    = 5.0;      // Auto-flatten + freeze after equity drops X%
input int             InpMaxTradesPerDay   = 30;       // 0 = unlimited
input int             InpCooldownMinutes   = 3;        // Cooldown after each closed trade

//+------------------------------------------------------------------+
//| Helpers / state                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  pos;
CSymbolInfo    sym;

int      g_handleIndi = INVALID_HANDLE;
int      g_handleATR  = INVALID_HANDLE;

datetime g_lastEntryBar     = 0;   // bar time of last successful entry (avoid double-fire same bar)
double   g_dayStartEquity   = 0.0; // equity at start of current day
datetime g_currentDay       = 0;
int      g_tradesToday      = 0;
datetime g_lastClosedTrade  = 0;
bool     g_guardFlat        = false; // equity guard locked

// Parsed news times — minutes since midnight
int      g_newsMinutes[];

//+------------------------------------------------------------------+
//| Utility: midnight of a server datetime                           |
//+------------------------------------------------------------------+
datetime MidnightOf(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = dt.min = dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Utility: minutes since midnight                                  |
//+------------------------------------------------------------------+
int MinutesOfDay(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

//+------------------------------------------------------------------+
//| Parse "HH:MM,HH:MM,..." into g_newsMinutes                       |
//+------------------------------------------------------------------+
void ParseNewsTimes()
{
   ArrayResize(g_newsMinutes, 0);
   if(StringLen(InpNewsPauseTimes) == 0) return;
   string parts[];
   const int n = StringSplit(InpNewsPauseTimes, ',', parts);
   for(int i=0; i<n; ++i)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      string hm[];
      if(StringSplit(s, ':', hm) != 2) continue;
      const int h = (int)StringToInteger(hm[0]);
      const int m = (int)StringToInteger(hm[1]);
      if(h < 0 || h > 23 || m < 0 || m > 59) continue;
      const int idx = ArraySize(g_newsMinutes);
      ArrayResize(g_newsMinutes, idx + 1);
      g_newsMinutes[idx] = h * 60 + m;
   }
}

//+------------------------------------------------------------------+
//| Reset daily counters at midnight                                 |
//+------------------------------------------------------------------+
void ResetDailyIfNeeded()
{
   const datetime now    = TimeCurrent();
   const datetime today  = MidnightOf(now);
   if(today != g_currentDay)
   {
      g_currentDay      = today;
      g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday     = 0;
      g_guardFlat       = false;
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!sym.Name(_Symbol))
   {
      Print("TrendScalperEA: SymbolInfo failed for ", _Symbol);
      return INIT_FAILED;
   }
   sym.RefreshRates();

   // Load indicator.  Param list MUST match TrendScalperPro inputs 1:1.
   g_handleIndi = iCustom(_Symbol, _Period, InpIndicatorName,
                          InpSwingDepth,        // InpSwingDepth
                          InpEMAFilter,         // InpEMAFilter
                          InpATRPeriod,         // InpATRPeriod
                          InpATRMinMove,        // InpATRMinMove
                          true,                 // InpExtendLines
                          1500,                 // InpMaxHistoryBars
                          false,                // InpDrawObjects (EA copy is silent)
                          clrLime,              // InpUpColor
                          clrRed,               // InpDownColor
                          STYLE_SOLID,          // InpLineStyle
                          2,                    // InpLineWidth
                          false,                // InpShowDashboard
                          false,                // InpAlertPopup
                          false,                // InpAlertPush
                          false,                // InpAlertEmail
                          false,                // InpAlertSound
                          "alert.wav"           // InpAlertSoundFile
                         );
   if(g_handleIndi == INVALID_HANDLE)
   {
      Print("TrendScalperEA: iCustom('", InpIndicatorName, "') failed, err=", GetLastError());
      return INIT_FAILED;
   }
   g_handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_handleATR == INVALID_HANDLE)
   {
      Print("TrendScalperEA: iATR handle failed, err=", GetLastError());
      return INIT_FAILED;
   }

   ParseNewsTimes();
   ResetDailyIfNeeded();
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("TrendScalperEA initialised. Equity baseline=", DoubleToString(g_dayStartEquity, 2));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleIndi != INVALID_HANDLE) IndicatorRelease(g_handleIndi);
   if(g_handleATR  != INVALID_HANDLE) IndicatorRelease(g_handleATR);
}

//+------------------------------------------------------------------+
//| OnTrade — track closed trades for cooldown & day count           |
//+------------------------------------------------------------------+
void OnTrade()
{
   // Detect newly closed positions belonging to us by inspecting history.
   // We use TimeCurrent() as a coarse heuristic: a position close updates the
   // history; we refresh the latest deal and record its close time.
   if(!HistorySelect(g_currentDay, TimeCurrent())) return;
   const int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; --i)
   {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC)  != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL)         != _Symbol) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      const datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(t > g_lastClosedTrade)
         g_lastClosedTrade = t;
      break; // only the most recent deal matters here
   }
}

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool InSession()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   const bool dayOK =
      (dt.day_of_week == 0 && InpTradeSunday)    ||
      (dt.day_of_week == 1 && InpTradeMonday)    ||
      (dt.day_of_week == 2 && InpTradeTuesday)   ||
      (dt.day_of_week == 3 && InpTradeWednesday) ||
      (dt.day_of_week == 4 && InpTradeThursday)  ||
      (dt.day_of_week == 5 && InpTradeFriday)    ||
      (dt.day_of_week == 6 && InpTradeSaturday);
   if(!dayOK) return false;

   const int hr = dt.hour;
   if(InpStartHour == InpEndHour) return true;  // 24/7
   if(InpStartHour < InpEndHour)  return (hr >= InpStartHour && hr < InpEndHour);
   // wrap past midnight
   return (hr >= InpStartHour || hr < InpEndHour);
}

bool InNewsBlackout()
{
   if(ArraySize(g_newsMinutes) == 0 || InpNewsPauseMinutes <= 0) return false;
   const int nowMin = MinutesOfDay(TimeCurrent());
   for(int i=0; i<ArraySize(g_newsMinutes); ++i)
   {
      const int diff = MathAbs(nowMin - g_newsMinutes[i]);
      if(diff <= InpNewsPauseMinutes) return true;
      // also handle day-wrap edge case
      if(MathAbs(1440 - diff) <= InpNewsPauseMinutes) return true;
   }
   return false;
}

bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   sym.RefreshRates();
   const int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

bool CooldownOver()
{
   if(InpCooldownMinutes <= 0 || g_lastClosedTrade == 0) return true;
   return (TimeCurrent() - g_lastClosedTrade) >= (InpCooldownMinutes * 60);
}

bool DailyCapOK()
{
   if(InpMaxTradesPerDay <= 0) return true;
   return g_tradesToday < InpMaxTradesPerDay;
}

bool EquityGuardOK()
{
   if(!InpEquityGuardOn) return true;
   if(g_guardFlat) return false;
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) return true;
   const double dropPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
   if(dropPct >= InpEquityGuardPct)
   {
      g_guardFlat = true;
      Print("TrendScalperEA: equity guard tripped, drop=", DoubleToString(dropPct,2), "%, flattening.");
      FlattenAll();
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Count open positions filtered by symbol+magic                    |
//+------------------------------------------------------------------+
int CountOpen()
{
   int c = 0;
   const int total = PositionsTotal();
   for(int i=0; i<total; ++i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic()  != InpMagic) continue;
      ++c;
   }
   return c;
}

void FlattenAll()
{
   const int total = PositionsTotal();
   for(int i=total-1; i>=0; --i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic()  != InpMagic) continue;
      trade.PositionClose(pos.Ticket(), InpDeviationPoints);
   }
}

//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lot = MathFloor(lot / step) * step;
   lot = MathMax(mn, MathMin(mx, lot));
   lot = MathMin(lot, InpMaxLot);
   return NormalizeDouble(lot, 2);
}

double ComputeLot(const double slPoints)
{
   if(!InpUseRiskPercent || slPoints <= 0.0) return NormalizeLot(InpFixedLot);

   const double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   const double riskCash = equity * (InpRiskPercent / 100.0);

   // tick value per 1 lot for a price move of 1 tick
   const double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0) return NormalizeLot(InpFixedLot);

   // money lost per lot if price moves slPoints * _Point against us
   const double moneyPerLot = (slPoints * _Point / tickSize) * tickVal;
   if(moneyPerLot <= 0.0) return NormalizeLot(InpFixedLot);

   const double lot = riskCash / moneyPerLot;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Read indicator signals for the *last closed* bar (shift=1)       |
//+------------------------------------------------------------------+
bool ReadSignals(double &buySig, double &sellSig, double &trendDir, double &upLine, double &dnLine)
{
   double up[1], dn[1], bs[1], ss[1], td[1];
   if(CopyBuffer(g_handleIndi, 0, 1, 1, up) != 1) return false;
   if(CopyBuffer(g_handleIndi, 1, 1, 1, dn) != 1) return false;
   if(CopyBuffer(g_handleIndi, 2, 1, 1, bs) != 1) return false;
   if(CopyBuffer(g_handleIndi, 3, 1, 1, ss) != 1) return false;
   if(CopyBuffer(g_handleIndi, 4, 1, 1, td) != 1) return false;
   upLine   = up[0];
   dnLine   = dn[0];
   buySig   = bs[0];
   sellSig  = ss[0];
   trendDir = td[0];
   return true;
}

//+------------------------------------------------------------------+
//| Place entry                                                      |
//+------------------------------------------------------------------+
void TryOpen(const int dir, const double atr)
{
   if(dir == 0) return;
   if(CountOpen() >= InpMaxOpenPositions) return;

   sym.RefreshRates();
   const double bid = sym.Bid();
   const double ask = sym.Ask();
   if(bid <= 0 || ask <= 0) return;

   const int    stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double point      = _Point;

   double slDistPts = atr * InpSL_ATRmult / point;
   double tpDistPts = atr * InpTP_ATRmult / point;
   slDistPts = MathMax(slDistPts, (double)MathMax(InpMinStopPoints, stopsLevel + 2));
   tpDistPts = MathMax(tpDistPts, (double)MathMax(InpMinStopPoints, stopsLevel + 2));

   const double lot = ComputeLot(slDistPts);
   if(lot <= 0.0) return;

   double price, sl, tp;
   bool ok = false;
   if(dir > 0)
   {
      price = ask;
      sl    = NormalizeDouble(price - slDistPts * point, _Digits);
      tp    = NormalizeDouble(price + tpDistPts * point, _Digits);
      ok    = trade.Buy(lot, _Symbol, price, sl, tp, InpTradeComment);
   }
   else
   {
      price = bid;
      sl    = NormalizeDouble(price + slDistPts * point, _Digits);
      tp    = NormalizeDouble(price - tpDistPts * point, _Digits);
      ok    = trade.Sell(lot, _Symbol, price, sl, tp, InpTradeComment);
   }

   if(ok)
   {
      ++g_tradesToday;
      g_lastEntryBar = iTime(_Symbol, _Period, 0);
      PrintFormat("TrendScalperEA: %s opened lot=%.2f sl=%.*f tp=%.*f atr=%.*f",
                  (dir>0?"BUY":"SELL"), lot, _Digits, sl, _Digits, tp, _Digits, atr);
   }
   else
   {
      PrintFormat("TrendScalperEA: order failed dir=%s ret=%d err=%d",
                  (dir>0?"BUY":"SELL"), (int)trade.ResultRetcode(), GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Manage open positions: breakeven + ATR trailing stop             |
//+------------------------------------------------------------------+
void ManageOpenPositions(const double atr)
{
   if(!InpUseBreakeven && !InpUseTrailing) return;
   const int total = PositionsTotal();
   for(int i=0; i<total; ++i)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic()  != InpMagic) continue;

      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)pos.PositionType();
      const double open  = pos.PriceOpen();
      const double curSL = pos.StopLoss();
      const double curTP = pos.TakeProfit();
      sym.RefreshRates();
      const double bid   = sym.Bid();
      const double ask   = sym.Ask();
      double newSL = curSL;

      if(ptype == POSITION_TYPE_BUY)
      {
         // Breakeven
         if(InpUseBreakeven && (bid - open) >= atr * InpBE_ATRmult)
         {
            const double beSL = NormalizeDouble(open + InpBE_OffsetPoints * _Point, _Digits);
            if(beSL > newSL) newSL = beSL;
         }
         // Trailing
         if(InpUseTrailing)
         {
            const double trailSL = NormalizeDouble(bid - atr * InpTrail_ATRmult, _Digits);
            if(trailSL > newSL) newSL = trailSL;
         }
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(pos.Ticket(), newSL, curTP);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         if(InpUseBreakeven && (open - ask) >= atr * InpBE_ATRmult)
         {
            const double beSL = NormalizeDouble(open - InpBE_OffsetPoints * _Point, _Digits);
            if(curSL == 0.0 || beSL < newSL || newSL == 0.0) newSL = beSL;
         }
         if(InpUseTrailing)
         {
            const double trailSL = NormalizeDouble(ask + atr * InpTrail_ATRmult, _Digits);
            if(curSL == 0.0 || trailSL < newSL || newSL == 0.0) newSL = trailSL;
         }
         if(newSL != curSL && newSL > ask && (curSL == 0.0 || newSL < curSL))
            trade.PositionModify(pos.Ticket(), newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyIfNeeded();

   // Always manage open trades (independent of new-bar detection)
   double atrArr[1];
   if(CopyBuffer(g_handleATR, 0, 1, 1, atrArr) == 1 && atrArr[0] > 0.0)
      ManageOpenPositions(atrArr[0]);

   // Equity guard runs every tick
   if(!EquityGuardOK()) return;

   // Only consider opening one trade per bar (per direction).  We retry the
   // filters on every tick of a new bar so that transient spread / cooldown
   // misses at bar-open don't permanently skip an otherwise valid signal.
   const datetime curBar = iTime(_Symbol, _Period, 0);
   if(curBar == g_lastEntryBar) return;

   if(!InSession())     return;
   if(InNewsBlackout()) return;
   if(!SpreadOK())      return;
   if(!CooldownOver())  return;
   if(!DailyCapOK())    return;

   double buySig, sellSig, trendDir, upLine, dnLine;
   if(!ReadSignals(buySig, sellSig, trendDir, upLine, dnLine)) return;
   if(atrArr[0] <= 0.0) return;

   if(buySig > 0.0)       TryOpen(+1, atrArr[0]);
   else if(sellSig > 0.0) TryOpen(-1, atrArr[0]);
}
//+------------------------------------------------------------------+
