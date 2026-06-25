//+------------------------------------------------------------------+
//|                                            XAUUSD_Scalper.mq5   |
//|                     XAUUSD Advanced Scalping EA  v5.1            |
//|                                                                  |
//|  Strategy (3-layer confirmation):                                |
//|   1. H4 TREND   — EMA(50) on H4 defines macro direction.        |
//|                   Only BUY when M5 price > H4 EMA(50).          |
//|                   Only SELL when M5 price < H4 EMA(50).         |
//|                   Eliminates counter-trend trades entirely.      |
//|                                                                  |
//|   2. M5 SIGNAL  — EMA(10) crosses EMA(30) in trend direction.   |
//|                   One crossover = one entry attempt.             |
//|                                                                  |
//|   3. RSI GUARD  — RSI(14) filters out extreme conditions only.  |
//|                   Buy:  RSI < 75 (not severely overbought)       |
//|                   Sell: RSI > 25 (not severely oversold)         |
//|                   Journal logs every rejected signal with reason. |
//|                                                                  |
//|  Exits: USD profit target + USD stop loss (monitored per tick).  |
//|  Breakeven: SL moves to entry once trade is in profit by X USD. |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "5.10"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== M5 EMA Signal ==="
input int    EMA_Fast_Period    = 10;          // Fast EMA (M5)
input int    EMA_Slow_Period    = 30;          // Slow EMA (M5)

input group "=== H4 Trend Filter ==="
input ENUM_TIMEFRAMES HTF_Period   = PERIOD_H4; // Higher timeframe for trend
input int    HTF_EMA_Period        = 50;         // EMA period on H4

input group "=== RSI Guard (extremes only) ==="
input int    RSI_Period         = 14;   // RSI period (M5)
input double RSI_BuyMax         = 75.0; // Block buys if RSI is ABOVE this (severely overbought)
input double RSI_SellMin        = 25.0; // Block sells if RSI is BELOW this (severely oversold)

input group "=== Session Filter (GMT hours) ==="
input bool   UseSessionFilter   = false; // Disable to test all hours — enable for live trading
input int    SessionStartHour   = 7;     // Session open hour (GMT)
input int    SessionEndHour     = 22;    // Session close hour (GMT)

input group "=== Trade Settings ==="
input double LotSize            = 0.01; // Trade volume in lots
input double TargetProfitUSD    = 3.00; // Close when floating profit reaches this ($)
input double StopLossUSD        = 1.50; // Close when floating loss reaches this ($)
input double BreakevenUSD       = 1.50; // Move SL to entry when profit reaches this (0=off)
input int    MaxPositions       = 2;    // Max simultaneous open positions per direction

input group "=== Entry Filters ==="
input int    MaxSpreadPoints    = 50;   // Max spread in points (0 = disabled)
input int    ATR_Period         = 14;   // ATR period
input double ATR_MaxThreshold   = 4.0; // Skip entry if ATR exceeds this (0 = disabled)
input int    CooldownSeconds    = 30;   // Seconds to wait after a close (increased from 10)

input group "=== EA Settings ==="
input long   MagicNumber        = 99999; // Unique ID for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int handleFastEMA;  // EMA(10) on M5
int handleSlowEMA;  // EMA(30) on M5
int handleHTF_EMA;  // EMA(50) on H4 — macro trend
int handleRSI;      // RSI(14) on M5
int handleATR;      // ATR(14) on M5

datetime lastCloseTime = 0;
datetime lastBarTime   = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   handleFastEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleHTF_EMA = iMA(_Symbol, HTF_Period,     HTF_EMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(handleFastEMA == INVALID_HANDLE) { Print("ERROR: Fast EMA failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleSlowEMA == INVALID_HANDLE) { Print("ERROR: Slow EMA failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleHTF_EMA == INVALID_HANDLE) { Print("ERROR: H4 EMA failed. Code:",  GetLastError()); return INIT_FAILED; }
   if(handleRSI     == INVALID_HANDLE) { Print("ERROR: RSI failed. Code:",      GetLastError()); return INIT_FAILED; }
   if(handleATR     == INVALID_HANDLE) { Print("ERROR: ATR failed. Code:",      GetLastError()); return INIT_FAILED; }

   Print("=== XAUUSD Scalper v5.1 Started ===");
   Print("M5 EMA: ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | HTF: ", EnumToString(HTF_Period), " EMA(", HTF_EMA_Period, ")",
         " | RSI guard: buy<", RSI_BuyMax, " sell>", RSI_SellMin,
         " | Session: ", UseSessionFilter ? "ON" : "OFF",
         " | TP: $", TargetProfitUSD, " SL: $", StopLossUSD, " BE: $", BreakevenUSD);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleHTF_EMA);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
   Print("XAUUSD Scalper v5 removed. Reason:", reason);
}

//+------------------------------------------------------------------+
//| CalcUSDtoPrice                                                    |
//+------------------------------------------------------------------+
double CalcUSDtoPrice(double usdAmount)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0 || LotSize <= 0 || tickSize <= 0) return 0;
   return (usdAmount * tickSize) / (tickValue * LotSize);
}

//+------------------------------------------------------------------+
//| IsNewBar                                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime) { lastBarTime = t; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| IsSpreadOK                                                        |
//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   if(MaxSpreadPoints <= 0) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      static datetime last = 0;
      if(TimeCurrent() - last > 60) { Print("Spread too wide: ", spread, " pts"); last = TimeCurrent(); }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsVolatilityOK                                                    |
//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   if(ATR_MaxThreshold <= 0) return true;
   double atr[1];
   if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1) return true;
   if(atr[0] > ATR_MaxThreshold)
   {
      static datetime last = 0;
      if(TimeCurrent() - last > 60) { Print("ATR too high: ", DoubleToString(atr[0],2)); last = TimeCurrent(); }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsSessionOK                                                       |
//|                                                                   |
//| XAUUSD is most liquid and predictable during London (07-17 GMT)  |
//| and New York (13-22 GMT) sessions. Asian session (22-07 GMT) has |
//| lower volume and wider spreads — less reliable signals.          |
//+------------------------------------------------------------------+
bool IsSessionOK()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hour = dt.hour;
   if(SessionStartHour <= SessionEndHour)
      return (hour >= SessionStartHour && hour < SessionEndHour);
   else
      return (hour >= SessionStartHour || hour < SessionEndHour);
}

//+------------------------------------------------------------------+
//| IsCooldownOver                                                    |
//+------------------------------------------------------------------+
bool IsCooldownOver()
{
   if(lastCloseTime == 0) return true;
   return (int)(TimeCurrent() - lastCloseTime) >= CooldownSeconds;
}

//+------------------------------------------------------------------+
//| CountPositions                                                    |
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
//| ManageOpenPositions                                               |
//|                                                                   |
//| Runs every tick. For each open position:                         |
//|  - Closes it if TP or SL (in USD) is reached                    |
//|  - Moves SL to breakeven once profit >= BreakevenUSD            |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      double profit    = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      // --- TP check ---
      if(profit >= TargetProfitUSD)
      {
         Print("TP $", DoubleToString(profit, 2), " — closing #", ticket);
         if(trade.PositionClose(ticket)) lastCloseTime = TimeCurrent();
         else Print("ERROR: Close failed #", ticket, " Code:", GetLastError());
         continue;
      }

      // --- SL check ---
      if(profit <= -StopLossUSD)
      {
         Print("SL -$", DoubleToString(MathAbs(profit), 2), " — closing #", ticket);
         if(trade.PositionClose(ticket)) lastCloseTime = TimeCurrent();
         else Print("ERROR: Close failed #", ticket, " Code:", GetLastError());
         continue;
      }

      // --- Breakeven: move SL to entry once profit >= BreakevenUSD ---
      // Only triggers once per trade (checks if SL is still below entry for buys)
      if(BreakevenUSD > 0 && profit >= BreakevenUSD)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            double beSL = NormalizeDouble(openPrice + _Point, _Digits);
            if(beSL > currentSL + _Point) // Not already at breakeven
            {
               if(trade.PositionModify(ticket, beSL, currentTP))
                  Print("Breakeven set on BUY #", ticket, " at ", DoubleToString(beSL, _Digits));
            }
         }
         else if(posType == POSITION_TYPE_SELL)
         {
            double beSL = NormalizeDouble(openPrice - _Point, _Digits);
            if(currentSL == 0 || beSL < currentSL - _Point) // Not already at breakeven
            {
               if(trade.PositionModify(ticket, beSL, currentTP))
                  Print("Breakeven set on SELL #", ticket, " at ", DoubleToString(beSL, _Digits));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // TP/SL and breakeven management runs on every tick
   ManageOpenPositions();

   // Entry evaluation: once per new M5 bar only
   if(!IsNewBar())       return;
   if(!IsCooldownOver()) return;
   if(!IsSpreadOK())     return;
   if(!IsVolatilityOK()) return;
   if(!IsSessionOK())    return;

   // ================================================================
   // Read M5 EMA crossover (signal)
   // ================================================================
   double fastBuf[2], slowBuf[2];
   if(CopyBuffer(handleFastEMA, 0, 1, 2, fastBuf) < 2) return;
   if(CopyBuffer(handleSlowEMA, 0, 1, 2, slowBuf) < 2) return;

   double fastNow  = fastBuf[0];  double fastPrev = fastBuf[1];
   double slowNow  = slowBuf[0];  double slowPrev = slowBuf[1];

   bool bullishCross = (fastPrev <= slowPrev) && (fastNow > slowNow);
   bool bearishCross = (fastPrev >= slowPrev) && (fastNow < slowNow);

   if(!bullishCross && !bearishCross) return; // No crossover — nothing to do

   // ================================================================
   // Read H4 EMA (macro trend filter)
   // Only take trades in the direction of the higher timeframe trend.
   // This eliminates the biggest source of false signals.
   // ================================================================
   double htfBuf[1];
   if(CopyBuffer(handleHTF_EMA, 0, 1, 1, htfBuf) < 1) return;
   double htfEMA    = htfBuf[0];
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   htfBullish = (currentBid > htfEMA); // Price above H4 EMA → macro uptrend
   bool   htfBearish = (currentBid < htfEMA); // Price below H4 EMA → macro downtrend

   // ================================================================
   // Read RSI — only used to block extreme overbought/oversold entries
   // ================================================================
   double rsiBuf[1];
   if(CopyBuffer(handleRSI, 0, 1, 1, rsiBuf) < 1) return;
   double rsi = rsiBuf[0];

   bool rsiOkBuy  = (rsi <= RSI_BuyMax);  // RSI < 75: not severely overbought
   bool rsiOkSell = (rsi >= RSI_SellMin); // RSI > 25: not severely oversold

   // ================================================================
   // Diagnostic log — fires on EVERY crossover so Journal shows exactly
   // which filter is rejecting signals. Check the Journal tab if 0 trades.
   // ================================================================
   string direction = bullishCross ? "BULLISH" : "BEARISH";
   string h4Status  = bullishCross
                      ? (htfBullish ? "OK(price>H4)" : "BLOCKED(price<H4)")
                      : (htfBearish ? "OK(price<H4)" : "BLOCKED(price>H4)");
   string rsiStatus = bullishCross
                      ? (rsiOkBuy  ? "OK" : StringFormat("BLOCKED(RSI=%.1f>%.0f)", rsi, RSI_BuyMax))
                      : (rsiOkSell ? "OK" : StringFormat("BLOCKED(RSI=%.1f<%.0f)", rsi, RSI_SellMin));

   Print(direction, " CROSS | H4=", h4Status, " RSI=", rsiStatus,
         " | FastEMA=", DoubleToString(fastNow, 2),
         " SlowEMA=",   DoubleToString(slowNow, 2),
         " | H4EMA=",   DoubleToString(htfEMA, 2));

   // ================================================================
   // Calculate SL/TP price levels from USD amounts
   // ================================================================
   double slDist = CalcUSDtoPrice(StopLossUSD);
   double tpDist = CalcUSDtoPrice(TargetProfitUSD);
   if(slDist <= 0 || tpDist <= 0) { Print("ERROR: SL/TP calculation failed"); return; }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ================================================================
   // BUY: bullish crossover + H4 uptrend + RSI not overbought
   // ================================================================
   if(bullishCross && htfBullish && rsiOkBuy &&
      CountPositions(POSITION_TYPE_BUY) < MaxPositions)
   {
      double slPrice = NormalizeDouble(ask - slDist, _Digits);
      double tpPrice = NormalizeDouble(ask + tpDist, _Digits);

      Print(">>> OPENING BUY | SL=$", StopLossUSD, " TP=$", TargetProfitUSD,
            " | Count:", CountPositions(POSITION_TYPE_BUY)+1, "/", MaxPositions);

      if(!trade.Buy(LotSize, _Symbol, ask, slPrice, tpPrice, "XAUUSD v5 Buy"))
         Print("ERROR: Buy failed. Code:", GetLastError());
   }

   // ================================================================
   // SELL: bearish crossover + H4 downtrend + RSI not oversold
   // ================================================================
   else if(bearishCross && htfBearish && rsiOkSell &&
           CountPositions(POSITION_TYPE_SELL) < MaxPositions)
   {
      double slPrice = NormalizeDouble(bid + slDist, _Digits);
      double tpPrice = NormalizeDouble(bid - tpDist, _Digits);

      Print(">>> OPENING SELL | SL=$", StopLossUSD, " TP=$", TargetProfitUSD,
            " | Count:", CountPositions(POSITION_TYPE_SELL)+1, "/", MaxPositions);

      if(!trade.Sell(LotSize, _Symbol, bid, slPrice, tpPrice, "XAUUSD v5 Sell"))
         Print("ERROR: Sell failed. Code:", GetLastError());
   }
}
//+------------------------------------------------------------------+
