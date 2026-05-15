//+------------------------------------------------------------------+
//|                                            TrendScalperPro.mq5   |
//|                Auto trend lines + trend-flip signal indicator    |
//|                                                                  |
//|  Detects market direction in real time by:                       |
//|    1. Finding swing highs / swing lows (pivot / fractal logic).  |
//|    2. Drawing two dynamic trend lines (support and resistance)   |
//|       through the last two confirmed swings on each side.        |
//|    3. Confirming a trend flip when price closes through the      |
//|       opposing trend line AND on the right side of an EMA        |
//|       filter, with an ATR noise filter.                          |
//|                                                                  |
//|  Exposes 5 buffers (the last one is INDICATOR_CALCULATIONS) so   |
//|  an Expert Advisor can consume the signals through iCustom:      |
//|    Buffer 0  UpTrendLine     (price of the up support line)      |
//|    Buffer 1  DownTrendLine   (price of the down resistance line) |
//|    Buffer 2  BuySignal       (price of bar where flip up fires)  |
//|    Buffer 3  SellSignal      (price of bar where flip down fires)|
//|    Buffer 4  TrendDirection  ( 1 up, -1 down, 0 unknown )        |
//|                                                                  |
//|  Alerts (popup / push / email) fire once per confirmed flip on   |
//|  the *closed* bar to avoid intra-bar repainting noise.           |
//+------------------------------------------------------------------+
#property copyright   "TrendScalperPro - Devin / andreslpxz"
#property link        "https://github.com/andreslpxz/MT5"
#property version     "1.00"
#property description "Auto-trend-line detector with EA-ready buffers and flip alerts."
#property strict

#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   4

//--- Plot 1: Up support line projected from the last two swing lows
#property indicator_label1  "UpTrendLine"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLime
#property indicator_width1  1
#property indicator_style1  STYLE_DOT

//--- Plot 2: Down resistance line projected from the last two swing highs
#property indicator_label2  "DownTrendLine"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_width2  1
#property indicator_style2  STYLE_DOT

//--- Plot 3: Buy arrow (trend flipped UP on this bar)
#property indicator_label3  "BuySignal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrAqua
#property indicator_width3  2

//--- Plot 4: Sell arrow (trend flipped DOWN on this bar)
#property indicator_label4  "SellSignal"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrMagenta
#property indicator_width4  2

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group           "=== Swing / trend logic ==="
input int             InpSwingDepth     = 5;       // Swing depth (bars left & right of pivot)
input int             InpEMAFilter      = 50;      // EMA period used as bias filter (0 = off)
input int             InpATRPeriod      = 14;      // ATR period for noise filter
input double          InpATRMinMove     = 0.25;    // Min flip distance in ATR units (lower=more sensitive)
input bool            InpExtendLines    = true;    // Project trend lines to the right
input int             InpMaxHistoryBars = 1500;    // Max history bars to compute (0 = all)

input group           "=== Visuals ==="
input bool            InpDrawObjects    = true;    // Draw OBJ_TREND lines on chart
input color           InpUpColor        = clrLime; // Up support line color
input color           InpDownColor      = clrRed;  // Down resistance line color
input ENUM_LINE_STYLE InpLineStyle      = STYLE_SOLID;
input int             InpLineWidth      = 2;
input bool            InpShowDashboard  = true;    // Show small status dashboard

input group           "=== Alerts ==="
input bool            InpAlertPopup     = true;    // Popup alert on flip
input bool            InpAlertPush      = false;   // Push notification on flip
input bool            InpAlertEmail     = false;   // Email alert on flip
input bool            InpAlertSound     = true;    // Play sound on flip
input string          InpAlertSoundFile = "alert.wav";

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufUpLine[];          // Buffer 0
double BufDownLine[];        // Buffer 1
double BufBuySignal[];       // Buffer 2
double BufSellSignal[];      // Buffer 3
double BufTrendDir[];        // Buffer 4 (INDICATOR_CALCULATIONS)

//+------------------------------------------------------------------+
//| Internal state                                                   |
//+------------------------------------------------------------------+
int    g_handleATR = INVALID_HANDLE;
int    g_handleEMA = INVALID_HANDLE;

string g_objPrefix;             // unique chart object prefix
string g_objUpLine;             // up support OBJ_TREND name
string g_objDownLine;           // down resistance OBJ_TREND name
string g_objDashboard;          // dashboard label name

datetime g_lastAlertBarTime = 0;  // last bar time we alerted on
int      g_lastAlertDir     = 0;  // last direction we alerted on

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // Wire buffers
   SetIndexBuffer(0, BufUpLine,     INDICATOR_DATA);
   SetIndexBuffer(1, BufDownLine,   INDICATOR_DATA);
   SetIndexBuffer(2, BufBuySignal,  INDICATOR_DATA);
   SetIndexBuffer(3, BufSellSignal, INDICATOR_DATA);
   SetIndexBuffer(4, BufTrendDir,   INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufUpLine,     false);
   ArraySetAsSeries(BufDownLine,   false);
   ArraySetAsSeries(BufBuySignal,  false);
   ArraySetAsSeries(BufSellSignal, false);
   ArraySetAsSeries(BufTrendDir,   false);

   // Empty values: signal buffers should not draw a continuous line — they are arrows
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetInteger(2, PLOT_ARROW, 233); // up arrow
   PlotIndexSetInteger(3, PLOT_ARROW, 234); // down arrow

   // Hide trend-line buffers when there is no swing yet
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);

   // Indicator handles
   g_handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_handleATR == INVALID_HANDLE)
   {
      Print("TrendScalperPro: failed to create iATR handle, err=", GetLastError());
      return INIT_FAILED;
   }
   if(InpEMAFilter > 0)
   {
      g_handleEMA = iMA(_Symbol, _Period, InpEMAFilter, 0, MODE_EMA, PRICE_CLOSE);
      if(g_handleEMA == INVALID_HANDLE)
      {
         Print("TrendScalperPro: failed to create iMA handle, err=", GetLastError());
         return INIT_FAILED;
      }
   }

   // Unique object name space per chart + period
   g_objPrefix   = StringFormat("TSP_%I64u_%s_%d_", (ulong)ChartID(), _Symbol, (int)_Period);
   g_objUpLine   = g_objPrefix + "UP";
   g_objDownLine = g_objPrefix + "DN";
   g_objDashboard= g_objPrefix + "DASH";

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("TrendScalperPro(depth=%d, ema=%d, atr=%d)",
                   InpSwingDepth, InpEMAFilter, InpATRPeriod));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit — clean every chart object we created                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, g_objPrefix);
   if(g_handleATR != INVALID_HANDLE) IndicatorRelease(g_handleATR);
   if(g_handleEMA != INVALID_HANDLE) IndicatorRelease(g_handleEMA);
}

//+------------------------------------------------------------------+
//| Helper: detect swing high / swing low at chronological index i   |
//|   non-series indexed arrays (i grows forward in time)            |
//|   A swing high is strictly higher than `depth` neighbours each   |
//|   side. Equal-high ties are allowed on the right side so flat    |
//|   ranges do not perpetually invalidate pivots.                   |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &high[], const int i, const int depth)
{
   const double v = high[i];
   for(int k=1; k<=depth; ++k)
   {
      if(high[i-k] >= v) return false;
      if(high[i+k] >  v) return false;
   }
   return true;
}
bool IsSwingLow(const double &low[], const int i, const int depth)
{
   const double v = low[i];
   for(int k=1; k<=depth; ++k)
   {
      if(low[i-k] <= v) return false;
      if(low[i+k] <  v) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Project a 2-point line forward and read it at index `at`         |
//|   line equation: y = y1 + (y2-y1)/(x2-x1) * (at - x1)            |
//+------------------------------------------------------------------+
double ProjectLine(const int x1, const double y1,
                   const int x2, const double y2,
                   const int at)
{
   if(x2 == x1) return y2;
   return y1 + (y2 - y1) * (double)(at - x1) / (double)(x2 - x1);
}

//+------------------------------------------------------------------+
//| Create or refresh an OBJ_TREND line on the chart                 |
//+------------------------------------------------------------------+
void DrawTrendObject(const string name, const datetime t1, const double p1,
                     const datetime t2, const double p2, const color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_BACK,   false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, InpExtendLines);
}

//+------------------------------------------------------------------+
//| Tiny on-chart dashboard                                          |
//+------------------------------------------------------------------+
void DrawDashboard(const int dir, const double upVal, const double downVal, const double atr)
{
   if(!InpShowDashboard) return;
   if(ObjectFind(0, g_objDashboard) < 0)
   {
      ObjectCreate(0, g_objDashboard, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_COLOR,     clrSilver);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_FONTSIZE,  9);
      ObjectSetString (0, g_objDashboard, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, g_objDashboard, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, g_objDashboard, OBJPROP_HIDDEN,    true);
   }
   string dirTxt = (dir>0 ? "UP  ^" : (dir<0 ? "DOWN v" : "FLAT -"));
   color  dirClr = (dir>0 ? InpUpColor : (dir<0 ? InpDownColor : clrSilver));
   ObjectSetInteger(0, g_objDashboard, OBJPROP_COLOR, dirClr);
   const string txt = StringFormat("TrendScalperPro  %s  | up=%s  dn=%s  atr=%s",
                                   dirTxt,
                                   DoubleToString(upVal,   _Digits),
                                   DoubleToString(downVal, _Digits),
                                   DoubleToString(atr,     _Digits));
   ObjectSetString(0, g_objDashboard, OBJPROP_TEXT, txt);
}

//+------------------------------------------------------------------+
//| Fire alerts on confirmed (closed-bar) trend flip                 |
//+------------------------------------------------------------------+
void FireFlipAlert(const int newDir, const datetime barTime, const double price)
{
   // De-duplicate alerts: only once per (barTime,direction)
   if(barTime == g_lastAlertBarTime && newDir == g_lastAlertDir) return;
   g_lastAlertBarTime = barTime;
   g_lastAlertDir     = newDir;

   string side = (newDir > 0 ? "BUY" : "SELL");
   string msg  = StringFormat("TrendScalperPro %s flip on %s %s @ %s",
                              side, _Symbol, EnumToString(_Period),
                              DoubleToString(price, _Digits));

   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertEmail) SendMail("TrendScalperPro alert", msg);
   if(InpAlertSound) PlaySound(InpAlertSoundFile);
}

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int        rates_total,
                const int        prev_calculated,
                const datetime   &time[],
                const double     &open[],
                const double     &high[],
                const double     &low[],
                const double     &close[],
                const long       &tick_volume[],
                const long       &volume[],
                const int        &spread[])
{
   const int minBars = MathMax(InpSwingDepth*2 + 5, InpEMAFilter + InpATRPeriod + 5);
   if(rates_total < minBars) return 0;

   // Limit history depth for performance
   int firstAllowed = 0;
   if(InpMaxHistoryBars > 0 && rates_total > InpMaxHistoryBars)
      firstAllowed = rates_total - InpMaxHistoryBars;

   // Refresh ATR / EMA buffers
   double atr[];
   double ema[];
   ArraySetAsSeries(atr, false);
   ArraySetAsSeries(ema, false);
   if(CopyBuffer(g_handleATR, 0, 0, rates_total, atr) <= 0) return prev_calculated;
   if(InpEMAFilter > 0 && CopyBuffer(g_handleEMA, 0, 0, rates_total, ema) <= 0) return prev_calculated;

   // We always recompute from firstAllowed.  For history capped at
   // InpMaxHistoryBars (default 1500) this is microseconds of work and
   // guarantees deterministic pivots/state regardless of when prev_calculated
   // is reset by the terminal.
   const int startScan = MathMax(firstAllowed, InpSwingDepth);
   const int scanLimit = rates_total - InpSwingDepth - 1;   // last index that can be a pivot

   int    pivHiX[2] = {-1,-1};   double pivHiY[2] = {0,0};
   int    pivLoX[2] = {-1,-1};   double pivLoY[2] = {0,0};
   int    trendDir  = 0;

   // Main loop — single pass, builds pivots + buffers + signals
   for(int i = startScan; i < rates_total; ++i)
   {
      // Reset signal buffers at this bar — keep them clean
      BufBuySignal [i] = 0.0;
      BufSellSignal[i] = 0.0;

      // Try to register a new pivot at i (if it qualifies & ATR threshold met)
      if(i <= scanLimit)
      {
         if(IsSwingHigh(high, i, InpSwingDepth))
         {
            // ATR threshold: distance vs previous swing high must exceed ATR*sensitivity
            if(pivHiX[1] < 0 || MathAbs(high[i] - pivHiY[1]) >= atr[i] * InpATRMinMove)
            {
               pivHiX[0]=pivHiX[1]; pivHiY[0]=pivHiY[1];
               pivHiX[1]=i;         pivHiY[1]=high[i];
            }
         }
         if(IsSwingLow(low, i, InpSwingDepth))
         {
            if(pivLoX[1] < 0 || MathAbs(low[i] - pivLoY[1]) >= atr[i] * InpATRMinMove)
            {
               pivLoX[0]=pivLoX[1]; pivLoY[0]=pivLoY[1];
               pivLoX[1]=i;         pivLoY[1]=low[i];
            }
         }
      }

      // Project current trend lines at bar i
      double upVal   = 0.0;
      double downVal = 0.0;
      if(pivLoX[0] >= 0 && pivLoX[1] >= 0)
         upVal = ProjectLine(pivLoX[0], pivLoY[0], pivLoX[1], pivLoY[1], i);
      if(pivHiX[0] >= 0 && pivHiX[1] >= 0)
         downVal = ProjectLine(pivHiX[0], pivHiY[0], pivHiX[1], pivHiY[1], i);

      BufUpLine  [i] = upVal;
      BufDownLine[i] = downVal;

      // Decide trend direction at bar i
      const double c  = close[i];
      const double e  = (InpEMAFilter > 0) ? ema[i] : c;
      int newDir = trendDir;

      // Bullish flip: price closes above the *previous* down resistance and stays above EMA
      if(downVal > 0.0 && c > downVal && c > e)
         newDir = +1;
      // Bearish flip: price closes below the up support and stays below EMA
      else if(upVal > 0.0 && c < upVal && c < e)
         newDir = -1;

      // Confirm flip vs previous direction
      if(newDir != 0 && newDir != trendDir)
      {
         if(newDir > 0)
            BufBuySignal[i]  = low [i] - atr[i] * 0.5;
         else
            BufSellSignal[i] = high[i] + atr[i] * 0.5;

         // Only alert on *closed* bars (i < last bar) OR on the freshly closed
         // bar — never on the still-forming last tick.  We rely on the fact
         // that during real-time updates rates_total grows by 1, so the last
         // index is the still-forming bar; alert on i == rates_total - 2.
         if(i == rates_total - 2)
            FireFlipAlert(newDir, time[i], c);

         trendDir = newDir;
      }

      BufTrendDir[i] = (double)trendDir;
   }

   // Refresh chart objects
   if(InpDrawObjects)
   {
      if(pivLoX[0] >= 0 && pivLoX[1] >= 0)
         DrawTrendObject(g_objUpLine,
                         time[pivLoX[0]], pivLoY[0],
                         time[pivLoX[1]], pivLoY[1],
                         InpUpColor);
      if(pivHiX[0] >= 0 && pivHiX[1] >= 0)
         DrawTrendObject(g_objDownLine,
                         time[pivHiX[0]], pivHiY[0],
                         time[pivHiX[1]], pivHiY[1],
                         InpDownColor);
   }
   else
   {
      ObjectDelete(0, g_objUpLine);
      ObjectDelete(0, g_objDownLine);
   }

   // Dashboard
   const int last = rates_total - 1;
   DrawDashboard((int)BufTrendDir[last], BufUpLine[last], BufDownLine[last], atr[last]);

   return rates_total;
}
//+------------------------------------------------------------------+
