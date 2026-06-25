//+------------------------------------------------------------------+
//|                                            XAUUSD_Scalper.mq5   |
//|                     XAUUSD EMA Trend Scalping EA                 |
//|                                                                  |
//|  Strategy:                                                       |
//|   Trend is determined by comparing EMA(10) to EMA(30).          |
//|   Fast EMA > Slow EMA → bullish → BUY only.                     |
//|   Fast EMA < Slow EMA → bearish → SELL only.                    |
//|   One trade at a time. Closes on USD profit or USD loss target.  |
//|   Filters: spread limit, ATR volatility cap, cooldown timer.    |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== EMA Trend Settings ==="
input int    EMA_Fast_Period    = 10;    // Fast EMA period
input int    EMA_Slow_Period    = 30;    // Slow EMA period

input group "=== Trade Settings ==="
input double LotSize            = 0.01;  // Trade volume in lots
input double TargetProfitUSD    = 3.00;  // Close trade when floating profit reaches this ($)
input double StopLossUSD        = 1.50;  // Close trade when floating loss reaches this ($)

input group "=== Filters ==="
input int    MaxSpreadPoints    = 50;    // Max allowed spread in points (0 = disabled)
                                         // XAUUSD typical spread is 20-35 points
input int    ATR_Period         = 14;    // ATR period for volatility measurement
input double ATR_MaxThreshold   = 3.0;  // Skip entry if ATR exceeds this (0 = disabled)
                                         // XAUUSD M5 normal ATR is ~1.5-3.0;
                                         // spikes above 3 indicate high-risk news moves
input int    CooldownSeconds    = 10;   // Seconds to wait after a close before new entry

input group "=== EA Settings ==="
input int    MaxPositions       = 2;     // Max simultaneous open positions (same direction)
input long   MagicNumber        = 99999; // Unique ID for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int      handleFastEMA;
int      handleSlowEMA;
int      handleATR;

datetime lastCloseTime = 0; // Time the last trade was closed (for cooldown)
datetime lastBarTime   = 0; // Time of the last processed bar (for new-bar gate)

//+------------------------------------------------------------------+
//| OnInit — runs once when EA starts                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // Create indicator handles — MT5 fills these buffers on every tick
   handleFastEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(handleFastEMA == INVALID_HANDLE)
   {
      Print("ERROR: Fast EMA(", EMA_Fast_Period, ") handle failed. Code:", GetLastError());
      return INIT_FAILED;
   }
   if(handleSlowEMA == INVALID_HANDLE)
   {
      Print("ERROR: Slow EMA(", EMA_Slow_Period, ") handle failed. Code:", GetLastError());
      return INIT_FAILED;
   }
   if(handleATR == INVALID_HANDLE)
   {
      Print("ERROR: ATR(", ATR_Period, ") handle failed. Code:", GetLastError());
      return INIT_FAILED;
   }

   // Log startup configuration
   Print("=== XAUUSD Scalper Started ===");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(PERIOD_CURRENT));
   Print("EMA Fast/Slow: ", EMA_Fast_Period, "/", EMA_Slow_Period);
   Print("LotSize: ", LotSize, " | TP: $", TargetProfitUSD, " | SL: $", StopLossUSD);
   Print("MaxSpread: ", MaxSpreadPoints, " pts | ATR Cap: ", ATR_MaxThreshold,
         " | Cooldown: ", CooldownSeconds, "s");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit — runs once when EA is removed                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleATR);
   Print("XAUUSD Scalper removed. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| CalcUSDtoPrice                                                    |
//|                                                                   |
//| Converts a USD profit/loss amount into a price distance for      |
//| XAUUSD at the configured lot size.                               |
//|                                                                   |
//| Formula: priceMove = usdAmount × tickSize / (tickValue × lots)   |
//|                                                                   |
//| XAUUSD example with 0.01 lots:                                   |
//|   tickSize  = 0.01 (smallest price movement)                     |
//|   tickValue = 1.00 (USD value per tick per standard lot)         |
//|   $1 target → 0.01 / (1.00 × 0.01) = $1.00 price move          |
//|   $2 SL     → 0.02 / (1.00 × 0.01) = $2.00 price move          |
//+------------------------------------------------------------------+
double CalcUSDtoPrice(double usdAmount)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickValue <= 0 || LotSize <= 0 || tickSize <= 0)
   {
      Print("WARNING: Could not calculate price distance — invalid tick info");
      return 0;
   }

   return (usdAmount * tickSize) / (tickValue * LotSize);
}

//+------------------------------------------------------------------+
//| IsSpreadOK — checks current spread against the configured limit  |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   if(MaxSpreadPoints <= 0) return true; // filter disabled

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      // Only log occasionally to avoid flooding the journal
      static datetime lastSpreadLog = 0;
      if(TimeCurrent() - lastSpreadLog > 60)
      {
         Print("Spread too wide: ", currentSpread, " pts (max ", MaxSpreadPoints, ") — skipping");
         lastSpreadLog = TimeCurrent();
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsVolatilityOK — ATR check                                       |
//|                                                                   |
//| Reads the last completed bar's ATR. If it exceeds the threshold, |
//| the market is moving too fast for a reliable scalp entry.        |
//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   if(ATR_MaxThreshold <= 0) return true; // filter disabled

   double atr[1];
   // Index 1 = last closed bar — gives a stable, completed ATR reading
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return true;

   if(atr[0] > ATR_MaxThreshold)
   {
      static datetime lastATRLog = 0;
      if(TimeCurrent() - lastATRLog > 60)
      {
         Print("ATR too high: ", DoubleToString(atr[0], 4),
               " (max ", ATR_MaxThreshold, ") — skipping");
         lastATRLog = TimeCurrent();
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsCooldownOver — enforces a pause after each closed trade        |
//+------------------------------------------------------------------+
bool IsCooldownOver()
{
   if(lastCloseTime == 0) return true;
   return (int)(TimeCurrent() - lastCloseTime) >= CooldownSeconds;
}

//+------------------------------------------------------------------+
//| ManageOpenPositions                                               |
//|                                                                   |
//| Loops through ALL positions for this EA and closes any that have |
//| hit the USD profit or loss target. Runs on every tick so exits  |
//| are as precise as possible regardless of how many are open.      |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= TargetProfitUSD)
      {
         Print("TP hit $", DoubleToString(profit, 2), " — closing #", ticket);
         if(trade.PositionClose(ticket))
            lastCloseTime = TimeCurrent();
         else
            Print("ERROR: Close failed #", ticket, " Code:", GetLastError());
      }
      else if(profit <= -StopLossUSD)
      {
         Print("SL hit $", DoubleToString(profit, 2), " — closing #", ticket);
         if(trade.PositionClose(ticket))
            lastCloseTime = TimeCurrent();
         else
            Print("ERROR: Close failed #", ticket, " Code:", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| CountPositions                                                    |
//|                                                                   |
//| Returns how many positions of a given type (BUY/SELL) are        |
//| currently open for this EA on this symbol.                       |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol     &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| IsNewBar — true only on the first tick of each new candle        |
//|                                                                   |
//| Entry evaluation is gated to once per bar. This prevents the    |
//| EA from opening hundreds of trades per day — without this gate,  |
//| a tick-based EA on XAUUSD can fire thousands of times per day.  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime) { lastBarTime = t; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| OnTick — main logic, fires on every price update                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // ================================================================
   // PART 1: Manage all open positions every tick
   // Checks every open position and closes any that have hit their
   // USD profit or loss target. Handles multiple positions correctly.
   // ================================================================
   ManageOpenPositions();

   // ================================================================
   // PART 2: Evaluate entry — gated to new bars only
   // TP/SL monitoring above runs every tick; entries run once per bar.
   // ================================================================
   if(!IsNewBar()) return;

   // Cooldown: wait CooldownSeconds after last close
   if(!IsCooldownOver()) return;

   // Spread filter: skip if market spread is too wide
   if(!IsSpreadOK()) return;

   // Volatility filter: skip if ATR shows abnormally fast price moves
   if(!IsVolatilityOK()) return;

   // ================================================================
   // PART 3: Read EMA values from the last TWO closed bars
   //
   // We need bar[1] (just closed) and bar[2] (one before that) to
   // detect a CROSSOVER — the moment direction actually changes.
   // This is the critical fix: previously the EA opened a trade on
   // EVERY bar while Fast > Slow, producing 6000+ trades. Now it
   // only opens when the crossover JUST happened (direction changed).
   // ================================================================
   double fastBuf[2], slowBuf[2];

   if(CopyBuffer(handleFastEMA, 0, 1, 2, fastBuf) < 2)
   {
      Print("WARNING: Could not read Fast EMA buffer");
      return;
   }
   if(CopyBuffer(handleSlowEMA, 0, 1, 2, slowBuf) < 2)
   {
      Print("WARNING: Could not read Slow EMA buffer");
      return;
   }

   // [0] = bar just closed, [1] = bar before that
   double fastNow  = fastBuf[0];
   double slowNow  = slowBuf[0];
   double fastPrev = fastBuf[1];
   double slowPrev = slowBuf[1];

   // ================================================================
   // PART 4: Detect fresh crossover and open trade
   //
   // A crossover is when the relationship FLIPS between bars.
   // Fast crossed ABOVE slow = bullish momentum just started → BUY
   // Fast crossed BELOW slow = bearish momentum just started → SELL
   // No crossover this bar = do nothing, wait for next signal.
   // ================================================================
   bool bullishCross = (fastPrev <= slowPrev) && (fastNow > slowNow);
   bool bearishCross = (fastPrev >= slowPrev) && (fastNow < slowNow);

   if(!bullishCross && !bearishCross) return;

   // Pre-calculate SL and TP price distances from USD amounts
   double slDist = CalcUSDtoPrice(StopLossUSD);
   double tpDist = CalcUSDtoPrice(TargetProfitUSD);

   if(slDist <= 0 || tpDist <= 0)
   {
      Print("ERROR: SL/TP distance calculation returned 0 — check symbol tick info");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- BUY on bullish crossover ---
   if(bullishCross && CountPositions(POSITION_TYPE_BUY) < MaxPositions)
   {
      double slPrice = NormalizeDouble(ask - slDist, _Digits);
      double tpPrice = NormalizeDouble(ask + tpDist, _Digits);

      Print("BUY CROSS | #", CountPositions(POSITION_TYPE_BUY)+1, "/", MaxPositions,
            " FastEMA=", DoubleToString(fastNow, 2),
            " SlowEMA=", DoubleToString(slowNow, 2),
            " Ask=", DoubleToString(ask, _Digits),
            " SL=", DoubleToString(slPrice, _Digits),
            " TP=", DoubleToString(tpPrice, _Digits));

      if(!trade.Buy(LotSize, _Symbol, ask, slPrice, tpPrice, "XAUUSD Scalper"))
         Print("ERROR: Buy order failed. Code:", GetLastError());
   }

   // --- SELL on bearish crossover ---
   else if(bearishCross && CountPositions(POSITION_TYPE_SELL) < MaxPositions)
   {
      double slPrice = NormalizeDouble(bid + slDist, _Digits);
      double tpPrice = NormalizeDouble(bid - tpDist, _Digits);

      Print("SELL CROSS | #", CountPositions(POSITION_TYPE_SELL)+1, "/", MaxPositions,
            " FastEMA=", DoubleToString(fastNow, 2),
            " SlowEMA=", DoubleToString(slowNow, 2),
            " Bid=", DoubleToString(bid, _Digits),
            " SL=", DoubleToString(slPrice, _Digits),
            " TP=", DoubleToString(tpPrice, _Digits));

      if(!trade.Sell(LotSize, _Symbol, bid, slPrice, tpPrice, "XAUUSD Scalper"))
         Print("ERROR: Sell order failed. Code:", GetLastError());
   }
}
//+------------------------------------------------------------------+
