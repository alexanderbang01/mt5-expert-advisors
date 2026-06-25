//+------------------------------------------------------------------+
//|                                                  EMA_RSI_EA.mq5 |
//|                          EMA Crossover + RSI Filter Expert Advisor|
//|                                                                  |
//|  Strategy:                                                       |
//|    BUY  — Fast EMA crosses above Slow EMA, RSI < Overbought     |
//|    SELL — Fast EMA crosses below Slow EMA, RSI > Oversold       |
//|  One trade per direction; opposite signal closes existing trade. |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>   // CTrade class for order execution

//+------------------------------------------------------------------+
//| Input Parameters — all adjustable from MT5 without recompiling   |
//+------------------------------------------------------------------+
input int    FastEMA_Period  = 9;     // Fast EMA period
input int    SlowEMA_Period  = 21;    // Slow EMA period
input int    RSI_Period      = 14;    // RSI period
input double RSI_Overbought  = 70.0; // RSI level considered overbought (buy filter)
input double RSI_Oversold    = 30.0; // RSI level considered oversold (sell filter)
input double LotSize         = 0.01; // Trade volume in lots
input int    StopLoss_Pips   = 30;   // Stop loss distance in pips
input int    TakeProfit_Pips = 60;   // Take profit distance in pips
input long   MagicNumber     = 12345;// Unique ID to tag this EA's orders

//+------------------------------------------------------------------+
//| Global variables                                                  |
//+------------------------------------------------------------------+
CTrade   trade;          // Trade execution object

int      handleFastEMA;  // Indicator handle: fast EMA
int      handleSlowEMA;  // Indicator handle: slow EMA
int      handleRSI;      // Indicator handle: RSI

datetime lastBarTime = 0;// Tracks the open time of the last processed bar

//+------------------------------------------------------------------+
//| OnInit — runs once when the EA is attached or MT5 starts         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Tag all orders placed by this EA with the magic number so we can
   // identify them later even if the EA is restarted
   trade.SetExpertMagicNumber(MagicNumber);

   // Create indicator handles — MT5 fills these buffers in the background.
   // PERIOD_CURRENT means the EA adapts to whatever timeframe the chart is on.
   handleFastEMA = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   // Validate all handles — INVALID_HANDLE means MT5 could not create the indicator
   if(handleFastEMA == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Fast EMA handle. Code: ", GetLastError());
      return INIT_FAILED;
   }
   if(handleSlowEMA == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Slow EMA handle. Code: ", GetLastError());
      return INIT_FAILED;
   }
   if(handleRSI == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create RSI handle. Code: ", GetLastError());
      return INIT_FAILED;
   }

   Print("EA initialized | Symbol: ", _Symbol,
         " | TF: ",      EnumToString(PERIOD_CURRENT),
         " | FastEMA: ", FastEMA_Period,
         " | SlowEMA: ", SlowEMA_Period,
         " | RSI: ",     RSI_Period);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit — runs once when the EA is removed or MT5 closes        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Always release indicator handles to free memory when EA shuts down
   if(handleFastEMA != INVALID_HANDLE) IndicatorRelease(handleFastEMA);
   if(handleSlowEMA != INVALID_HANDLE) IndicatorRelease(handleSlowEMA);
   if(handleRSI     != INVALID_HANDLE) IndicatorRelease(handleRSI);

   Print("EA removed. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| IsNewBar — returns true only on the first tick of a new bar      |
//|                                                                  |
//| We gate all logic on new bars to avoid acting on intra-bar noise |
//| and to prevent the same signal from firing multiple ticks in a  |
//| row on the same candle.                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| GetPipSize — returns the value of 1 pip for the current symbol   |
//|                                                                  |
//| 5-digit brokers (e.g. 1.23456): 1 pip = _Point * 10 = 0.0001   |
//| 3-digit JPY brokers (e.g. 145.123): 1 pip = _Point * 10 = 0.01  |
//| 4/2-digit brokers: 1 pip = _Point exactly                        |
//+------------------------------------------------------------------+
double GetPipSize()
{
   if(_Digits == 5 || _Digits == 3)
      return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
//| CountPositions — counts open positions of a given type for        |
//| this symbol and magic number                                      |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Filter: must match this EA's symbol, magic number, and direction
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol    &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| ClosePositions — closes all open positions of the given type      |
//| that belong to this EA on this symbol                            |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL)  == _Symbol    &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType)
      {
         if(!trade.PositionClose(ticket))
            Print("ERROR: Could not close position #", ticket,
                  ". Code: ", GetLastError());
         else
            Print("Closed ", EnumToString(posType), " position #", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick — main EA logic, called on every incoming price tick       |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Gate: only act once per bar ---
   // This prevents multiple entries/exits within the same candle.
   if(!IsNewBar()) return;

   // --- Read indicator values ---
   // We need two bars of EMA data to detect a crossover:
   //   index 1 = the bar that just closed (most recent complete candle)
   //   index 2 = the bar before that
   // Index 0 is the currently forming bar — we skip it to avoid repainting.

   double fastEMA_now[1], fastEMA_prev[1];
   double slowEMA_now[1], slowEMA_prev[1];
   double rsi_now[1];

   // CopyBuffer(handle, buffer, start_index, count, destination_array)
   // Return value is the number of elements copied; < 1 means not enough data yet
   if(CopyBuffer(handleFastEMA, 0, 1, 1, fastEMA_now)  < 1) return;
   if(CopyBuffer(handleFastEMA, 0, 2, 1, fastEMA_prev) < 1) return;
   if(CopyBuffer(handleSlowEMA, 0, 1, 1, slowEMA_now)  < 1) return;
   if(CopyBuffer(handleSlowEMA, 0, 2, 1, slowEMA_prev) < 1) return;
   if(CopyBuffer(handleRSI,     0, 1, 1, rsi_now)      < 1) return;

   double fastNow  = fastEMA_now[0];
   double fastPrev = fastEMA_prev[0];
   double slowNow  = slowEMA_now[0];
   double slowPrev = slowEMA_prev[0];
   double rsi      = rsi_now[0];

   // --- Crossover detection ---
   // Bullish: fast was at or below slow on previous bar, now above slow
   bool bullishCross = (fastPrev <= slowPrev) && (fastNow > slowNow);
   // Bearish: fast was at or above slow on previous bar, now below slow
   bool bearishCross = (fastPrev >= slowPrev) && (fastNow < slowNow);

   // --- Pre-calculate SL/TP offsets in price units ---
   double pip     = GetPipSize();
   double slDist  = StopLoss_Pips   * pip;
   double tpDist  = TakeProfit_Pips * pip;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // =================================================================
   // BUY SIGNAL
   // Condition: bullish EMA crossover AND RSI is not overbought
   // An overbought RSI would suggest the move may already be exhausted.
   // =================================================================
   if(bullishCross && rsi < RSI_Overbought)
   {
      // Opposite signal fires — close any open sell positions first
      if(CountPositions(POSITION_TYPE_SELL) > 0)
      {
         Print("BUY signal: closing existing SELL position(s)");
         ClosePositions(POSITION_TYPE_SELL);
      }

      // Enter buy only if not already in a buy trade on this symbol
      if(CountPositions(POSITION_TYPE_BUY) == 0)
      {
         double slPrice = NormalizeDouble(ask - slDist, _Digits);
         double tpPrice = NormalizeDouble(ask + tpDist, _Digits);

         Print("BUY  | FastEMA=", DoubleToString(fastNow, _Digits),
               " SlowEMA=", DoubleToString(slowNow, _Digits),
               " RSI=",     DoubleToString(rsi, 2),
               " Ask=",     DoubleToString(ask, _Digits),
               " SL=",      DoubleToString(slPrice, _Digits),
               " TP=",      DoubleToString(tpPrice, _Digits));

         if(!trade.Buy(LotSize, _Symbol, ask, slPrice, tpPrice, "EMA+RSI Buy"))
            Print("ERROR: Buy order failed. Code: ", GetLastError());
      }
   }

   // =================================================================
   // SELL SIGNAL
   // Condition: bearish EMA crossover AND RSI is not oversold
   // An oversold RSI would suggest the move may already be exhausted.
   // =================================================================
   else if(bearishCross && rsi > RSI_Oversold)
   {
      // Opposite signal fires — close any open buy positions first
      if(CountPositions(POSITION_TYPE_BUY) > 0)
      {
         Print("SELL signal: closing existing BUY position(s)");
         ClosePositions(POSITION_TYPE_BUY);
      }

      // Enter sell only if not already in a sell trade on this symbol
      if(CountPositions(POSITION_TYPE_SELL) == 0)
      {
         double slPrice = NormalizeDouble(bid + slDist, _Digits);
         double tpPrice = NormalizeDouble(bid - tpDist, _Digits);

         Print("SELL | FastEMA=", DoubleToString(fastNow, _Digits),
               " SlowEMA=", DoubleToString(slowNow, _Digits),
               " RSI=",     DoubleToString(rsi, 2),
               " Bid=",     DoubleToString(bid, _Digits),
               " SL=",      DoubleToString(slPrice, _Digits),
               " TP=",      DoubleToString(tpPrice, _Digits));

         if(!trade.Sell(LotSize, _Symbol, bid, slPrice, tpPrice, "EMA+RSI Sell"))
            Print("ERROR: Sell order failed. Code: ", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
