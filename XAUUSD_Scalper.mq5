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
#property version   "1.00"
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
input double TargetProfitUSD    = 1.00;  // Close trade when floating profit reaches this ($)
input double StopLossUSD        = 2.00;  // Close trade when floating loss reaches this ($)

input group "=== Filters ==="
input int    MaxSpreadPoints    = 50;    // Max allowed spread in points (0 = disabled)
                                         // XAUUSD typical spread is 20-35 points
input int    ATR_Period         = 14;    // ATR period for volatility measurement
input double ATR_MaxThreshold   = 3.0;  // Skip entry if ATR exceeds this (0 = disabled)
                                         // XAUUSD M5 normal ATR is ~1.5-3.0;
                                         // spikes above 3 indicate high-risk news moves
input int    CooldownSeconds    = 10;   // Seconds to wait after a close before new entry

input group "=== EA Settings ==="
input long   MagicNumber        = 99999; // Unique ID for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int      handleFastEMA;
int      handleSlowEMA;
int      handleATR;

datetime lastCloseTime = 0; // Time the last trade was closed (for cooldown)

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
//| FindPosition                                                      |
//|                                                                   |
//| Searches for an open position belonging to this EA on this       |
//| symbol. Returns true if found, and fills the out parameters.     |
//+------------------------------------------------------------------+
bool FindPosition(ulong &ticket, double &profit, ENUM_POSITION_TYPE &posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol    &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber)
      {
         ticket  = t;
         profit  = PositionGetDouble(POSITION_PROFIT);
         posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| OnTick — main logic, fires on every price update                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // ================================================================
   // PART 1: Manage any open position
   // Check USD profit and loss on every tick and close if limits hit.
   // The hard SL/TP on the order acts as a backup if the EA is offline.
   // ================================================================
   ulong              ticket  = 0;
   double             profit  = 0;
   ENUM_POSITION_TYPE posType;

   if(FindPosition(ticket, profit, posType))
   {
      // Close if profit target reached
      if(profit >= TargetProfitUSD)
      {
         Print("TP hit — Profit: $", DoubleToString(profit, 2),
               " >= $", TargetProfitUSD, " | Closing #", ticket);
         if(trade.PositionClose(ticket))
            lastCloseTime = TimeCurrent();
         else
            Print("ERROR: Failed to close position #", ticket, " Code:", GetLastError());
         return;
      }

      // Close if stop loss reached
      if(profit <= -StopLossUSD)
      {
         Print("SL hit — Loss: $", DoubleToString(profit, 2),
               " <= -$", StopLossUSD, " | Closing #", ticket);
         if(trade.PositionClose(ticket))
            lastCloseTime = TimeCurrent();
         else
            Print("ERROR: Failed to close position #", ticket, " Code:", GetLastError());
         return;
      }

      // Position is within acceptable range — hold it
      return;
   }

   // ================================================================
   // PART 2: No position open — evaluate entry conditions
   // ================================================================

   // Cooldown: wait CooldownSeconds after last close
   if(!IsCooldownOver()) return;

   // Spread filter: skip if market spread is too wide
   if(!IsSpreadOK()) return;

   // Volatility filter: skip if ATR shows abnormally fast price moves
   if(!IsVolatilityOK()) return;

   // ================================================================
   // PART 3: Read current EMA values
   //
   // We use index 0 (the current live bar) so the EMA reflects the
   // latest price on every tick — appropriate for tick-based scalping.
   // ================================================================
   double fastBuf[1], slowBuf[1];

   if(CopyBuffer(handleFastEMA, 0, 0, 1, fastBuf) < 1)
   {
      Print("WARNING: Could not read Fast EMA buffer");
      return;
   }
   if(CopyBuffer(handleSlowEMA, 0, 0, 1, slowBuf) < 1)
   {
      Print("WARNING: Could not read Slow EMA buffer");
      return;
   }

   double fastEMA = fastBuf[0];
   double slowEMA = slowBuf[0];

   // ================================================================
   // PART 4: Determine trend and open trade
   // ================================================================
   bool isBullish = (fastEMA > slowEMA); // uptrend → buy only
   bool isBearish = (fastEMA < slowEMA); // downtrend → sell only

   if(!isBullish && !isBearish) return; // EMAs exactly equal — no clear trend

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

   // --- BUY ---
   if(isBullish)
   {
      double slPrice = NormalizeDouble(ask - slDist, _Digits);
      double tpPrice = NormalizeDouble(ask + tpDist, _Digits);

      Print("BUY  | FastEMA=", DoubleToString(fastEMA, 2),
            " SlowEMA=", DoubleToString(slowEMA, 2),
            " | Lots=", LotSize,
            " Ask=", DoubleToString(ask, _Digits),
            " SL=", DoubleToString(slPrice, _Digits), " ($", StopLossUSD, ")",
            " TP=", DoubleToString(tpPrice, _Digits), " ($", TargetProfitUSD, ")");

      if(!trade.Buy(LotSize, _Symbol, ask, slPrice, tpPrice, "XAUUSD Scalper"))
         Print("ERROR: Buy order failed. Code:", GetLastError());
   }

   // --- SELL ---
   else if(isBearish)
   {
      double slPrice = NormalizeDouble(bid + slDist, _Digits);
      double tpPrice = NormalizeDouble(bid - tpDist, _Digits);

      Print("SELL | FastEMA=", DoubleToString(fastEMA, 2),
            " SlowEMA=", DoubleToString(slowEMA, 2),
            " | Lots=", LotSize,
            " Bid=", DoubleToString(bid, _Digits),
            " SL=", DoubleToString(slPrice, _Digits), " ($", StopLossUSD, ")",
            " TP=", DoubleToString(tpPrice, _Digits), " ($", TargetProfitUSD, ")");

      if(!trade.Sell(LotSize, _Symbol, bid, slPrice, tpPrice, "XAUUSD Scalper"))
         Print("ERROR: Sell order failed. Code:", GetLastError());
   }
}
//+------------------------------------------------------------------+
