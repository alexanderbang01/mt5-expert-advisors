//+------------------------------------------------------------------+
//|                                           MACD_Trend_EA.mq5     |
//|            MACD Crossover + 200 EMA Trend Following EA          |
//|                                                                  |
//|  Why MACD instead of EMA crossover:                             |
//|   MACD is the momentum behind the price move, not just price    |
//|   itself. A MACD signal-line crossover near the zero line means |
//|   momentum is shifting direction — a far more reliable entry    |
//|   than two price-EMAs crossing.                                 |
//|                                                                  |
//|  Strategy:                                                       |
//|   TREND  — Price above/below 200 EMA defines allowed direction. |
//|   ENTRY  — MACD main line crosses signal line in trend direction.|
//|            Optional: only take crossovers below zero (buys)     |
//|            or above zero (sells) = buying/selling the dip.      |
//|   FILTER — RSI not at overbought/oversold extreme.              |
//|   EXIT   — Fixed 3:1 TP. Breakeven stop when up half the SL.   |
//|            No trailing stop — it was cutting winners too early. |
//|                                                                  |
//|  Recommended: H1, EURUSD / GBPUSD / USDJPY                     |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== MACD Settings ==="
input int    MACD_Fast         = 12;   // MACD fast EMA period
input int    MACD_Slow         = 26;   // MACD slow EMA period
input int    MACD_Signal       = 9;    // MACD signal line period
input bool   UseZeroFilter     = true; // Only buy if MACD<0, sell if MACD>0 at crossover
                                       // (ensures we are buying a dip, not chasing a top)

input group "=== Trend Filter ==="
input int    EMA_Trend         = 200;  // Trend EMA period (200 = long-term baseline)

input group "=== RSI Filter ==="
input int    RSI_Period        = 14;   // RSI period
input double RSI_Upper         = 65.0; // Block buys above this RSI level
input double RSI_Lower         = 35.0; // Block sells below this RSI level

input group "=== Risk & Money Management ==="
input double RiskPercent       = 5.0;  // % of balance to risk per trade
                                       // Validate at 5% before raising to 50%.
input double MaxLots           = 20.0; // Hard ceiling on lot size
input int    StopLoss_Pips     = 30;   // Stop loss in pips
input int    TakeProfit_Pips   = 90;   // Take profit in pips (3:1 R:R)
input int    Breakeven_Pips    = 15;   // Move SL to entry when this many pips in profit
                                       // (0 = disabled). Protects capital without cutting
                                       // winners early the way a trailing stop does.
input int    MaxSpread_Pips    = 3;    // Skip entry if spread exceeds this (0 = off)

input group "=== EA Settings ==="
input long   MagicNumber       = 88888; // Unique tag for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int handleMACD;   // MACD indicator (buffer 0 = main line, buffer 1 = signal)
int handleEMA;    // 200 EMA trend filter
int handleRSI;    // RSI filter

// Per-position breakeven state — track which tickets we've already moved to BE
// so we don't spam PositionModify on every tick
ulong beApplied[]; // dynamic array of tickets that already had BE applied

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   handleMACD = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   handleEMA  = iMA(_Symbol, PERIOD_CURRENT, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI  = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(handleMACD == INVALID_HANDLE) { Print("ERROR: MACD handle failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleEMA  == INVALID_HANDLE) { Print("ERROR: EMA handle failed. Code:",  GetLastError()); return INIT_FAILED; }
   if(handleRSI  == INVALID_HANDLE) { Print("ERROR: RSI handle failed. Code:",  GetLastError()); return INIT_FAILED; }

   ArrayResize(beApplied, 0);

   if(RiskPercent > 20.0)
   {
      double rem = MathPow(1.0 - RiskPercent / 100.0, 3) * 100.0;
      Print("*** RISK WARNING: ", RiskPercent, "% risk. Three losses leave ",
            DoubleToString(rem, 1), "% of balance. Validate at 5% first. ***");
   }

   Print("MACD Trend EA ready | ", _Symbol, " ", EnumToString(PERIOD_CURRENT),
         " | MACD ", MACD_Fast, "/", MACD_Slow, "/", MACD_Signal,
         " | EMA ", EMA_Trend,
         " | SL ", StopLoss_Pips, " TP ", TakeProfit_Pips, " BE ", Breakeven_Pips,
         " | Risk ", RiskPercent, "%");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleMACD);
   IndicatorRelease(handleEMA);
   IndicatorRelease(handleRSI);
   ArrayFree(beApplied);
   Print("MACD Trend EA removed. Reason:", reason);
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
//| GetPipSize                                                        |
//+------------------------------------------------------------------+
double GetPipSize()
{
   return (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;
}

//+------------------------------------------------------------------+
//| CalculateLots                                                     |
//+------------------------------------------------------------------+
double CalculateLots(int slPips, ENUM_ORDER_TYPE orderType)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * RiskPercent / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pipSize   = GetPipSize();
   double pipValue  = (tickSize > 0) ? (pipSize / tickSize) * tickValue : 0;

   if(pipValue <= 0 || slPips <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots    = riskAmt / (slPips * pipValue);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / volStep) * volStep;
   lots = MathMax(lots, volMin);
   lots = MathMin(lots, MathMin(volMax, MaxLots));

   // Scale down if free margin is insufficient for the calculated lot size
   double price = SymbolInfoDouble(_Symbol, orderType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   double marginNeeded = 0;
   if(OrderCalcMargin(orderType, _Symbol, lots, price, marginNeeded) && marginNeeded > 0)
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
      if(marginNeeded > freeMargin * 0.90)
      {
         double scaleFactor = (freeMargin * 0.85) / marginNeeded;
         lots = MathFloor((lots * scaleFactor) / volStep) * volStep;
         lots = MathMax(lots, volMin);
         Print("Lots scaled to ", DoubleToString(lots, 2),
               " — margin limit (needed $", DoubleToString(marginNeeded, 2),
               " free $", DoubleToString(freeMargin, 2), ")");
      }
   }

   return lots;
}

//+------------------------------------------------------------------+
//| IsSpreadAcceptable                                                |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   if(MaxSpread_Pips <= 0) return true;
   long   pts  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double pips = (double)pts * _Point / GetPipSize();
   return pips <= (double)MaxSpread_Pips;
}

//+------------------------------------------------------------------+
//| IsBEApplied — check if breakeven has already been set            |
//+------------------------------------------------------------------+
bool IsBEApplied(ulong ticket)
{
   for(int i = 0; i < ArraySize(beApplied); i++)
      if(beApplied[i] == ticket) return true;
   return false;
}

void MarkBEApplied(ulong ticket)
{
   int sz = ArraySize(beApplied);
   ArrayResize(beApplied, sz + 1);
   beApplied[sz] = ticket;
}

// Remove closed position from the BE-applied list
void CleanBEList()
{
   int sz = ArraySize(beApplied);
   for(int i = sz - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(beApplied[i]))
      {
         // Position no longer exists — remove from list
         for(int j = i; j < sz - 1; j++)
            beApplied[j] = beApplied[j + 1];
         sz--;
         ArrayResize(beApplied, sz);
      }
   }
}

//+------------------------------------------------------------------+
//| ManageBreakeven — runs every tick                                 |
//|                                                                   |
//| Unlike a trailing stop (which keeps moving and cuts winners),    |
//| this moves SL to entry ONCE when we're up Breakeven_Pips.       |
//| After that it stays there — TP does the rest of the work.       |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   if(Breakeven_Pips <= 0) return;

   CleanBEList();
   double beTrigger = Breakeven_Pips * GetPipSize();
   double beBuffer  = 2 * _Point; // place SL 2 points from entry, not exactly at it

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      if(IsBEApplied(ticket)) continue; // already set breakeven for this trade

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid >= openPrice + beTrigger)
         {
            double newSL = NormalizeDouble(openPrice + beBuffer, _Digits);
            if(newSL > currentSL + _Point)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Breakeven set on BUY #", ticket, " at ", DoubleToString(newSL, _Digits));
                  MarkBEApplied(ticket);
               }
            }
         }
      }
      else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(ask <= openPrice - beTrigger)
         {
            double newSL = NormalizeDouble(openPrice - beBuffer, _Digits);
            if(currentSL == 0 || newSL < currentSL - _Point)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Breakeven set on SELL #", ticket, " at ", DoubleToString(newSL, _Digits));
                  MarkBEApplied(ticket);
               }
            }
         }
      }
   }
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
//| ClosePositions                                                    |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol     &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType)
      {
         if(!trade.PositionClose(ticket))
            Print("ERROR: Close failed #", ticket, " Code:", GetLastError());
         else
            Print("Closed ", EnumToString(posType), " #", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Breakeven management runs on every tick for precise trigger detection
   ManageBreakeven();

   if(!IsNewBar())           return;
   if(!IsSpreadAcceptable()) return;

   // --- Read indicator values for the last two CLOSED bars ---
   // MACD main line: buffer 0
   // MACD signal line: buffer 1
   double macdMain1[1], macdMain2[1];
   double macdSig1[1],  macdSig2[1];
   double ema200[1];
   double rsiVal[1];

   if(CopyBuffer(handleMACD, 0, 1, 1, macdMain1) < 1) return; // MACD main, last closed bar
   if(CopyBuffer(handleMACD, 0, 2, 1, macdMain2) < 1) return; // MACD main, bar before
   if(CopyBuffer(handleMACD, 1, 1, 1, macdSig1)  < 1) return; // Signal, last closed bar
   if(CopyBuffer(handleMACD, 1, 2, 1, macdSig2)  < 1) return; // Signal, bar before
   if(CopyBuffer(handleEMA,  0, 1, 1, ema200)    < 1) return; // 200 EMA
   if(CopyBuffer(handleRSI,  0, 1, 1, rsiVal)    < 1) return; // RSI

   double macdNow  = macdMain1[0];
   double macdPrev = macdMain2[0];
   double sigNow   = macdSig1[0];
   double sigPrev  = macdSig2[0];
   double ema       = ema200[0];
   double rsi       = rsiVal[0];
   double price     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Trend direction ---
   bool upTrend   = (price > ema); // price above 200 EMA = macro uptrend
   bool downTrend = (price < ema); // price below 200 EMA = macro downtrend

   // --- MACD signal-line crossover ---
   // MACD main crossed above signal = bullish momentum shift
   bool macdBullCross = (macdPrev <= sigPrev) && (macdNow > sigNow);
   // MACD main crossed below signal = bearish momentum shift
   bool macdBearCross = (macdPrev >= sigPrev) && (macdNow < sigNow);

   // --- Zero-line filter (optional) ---
   // Buy only if the MACD crossover occurs while MACD is still below zero.
   // This means we are catching momentum returning to the upside AFTER a
   // pullback took MACD negative — a much stronger signal than chasing
   // a crossover that happens when MACD is already high/positive.
   bool zeroOkBuy  = !UseZeroFilter || (macdNow < 0);
   bool zeroOkSell = !UseZeroFilter || (macdNow > 0);

   // --- RSI extremes filter ---
   // Block entries when RSI is already at an extreme — those moves are
   // often about to reverse and we'd be entering at the worst moment.
   bool rsiOkBuy  = (rsi < RSI_Upper);
   bool rsiOkSell = (rsi > RSI_Lower);

   // --- Final signals ---
   bool buySignal  = macdBullCross && upTrend   && zeroOkBuy  && rsiOkBuy;
   bool sellSignal = macdBearCross && downTrend  && zeroOkSell && rsiOkSell;

   double pip    = GetPipSize();
   double slDist = StopLoss_Pips   * pip;
   double tpDist = TakeProfit_Pips * pip;
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ================================================================
   // BUY
   // ================================================================
   if(buySignal)
   {
      if(CountPositions(POSITION_TYPE_SELL) > 0)
      {
         Print("BUY signal — closing SELL");
         ClosePositions(POSITION_TYPE_SELL);
      }

      if(CountPositions(POSITION_TYPE_BUY) == 0)
      {
         double lots    = CalculateLots(StopLoss_Pips, ORDER_TYPE_BUY);
         double slPrice = NormalizeDouble(ask - slDist, _Digits);
         double tpPrice = NormalizeDouble(ask + tpDist, _Digits);

         Print("BUY  | Lots=",  DoubleToString(lots, 2),
               " MACD=",  DoubleToString(macdNow, 6),
               " Sig=",   DoubleToString(sigNow, 6),
               " RSI=",   DoubleToString(rsi, 1),
               " EMA200=",DoubleToString(ema, _Digits),
               " SL=",    DoubleToString(slPrice, _Digits),
               " TP=",    DoubleToString(tpPrice, _Digits));

         if(!trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "MACD Trend Buy"))
            Print("ERROR Buy. Code:", GetLastError());
      }
   }

   // ================================================================
   // SELL
   // ================================================================
   else if(sellSignal)
   {
      if(CountPositions(POSITION_TYPE_BUY) > 0)
      {
         Print("SELL signal — closing BUY");
         ClosePositions(POSITION_TYPE_BUY);
      }

      if(CountPositions(POSITION_TYPE_SELL) == 0)
      {
         double lots    = CalculateLots(StopLoss_Pips, ORDER_TYPE_SELL);
         double slPrice = NormalizeDouble(bid + slDist, _Digits);
         double tpPrice = NormalizeDouble(bid - tpDist, _Digits);

         Print("SELL | Lots=",  DoubleToString(lots, 2),
               " MACD=",  DoubleToString(macdNow, 6),
               " Sig=",   DoubleToString(sigNow, 6),
               " RSI=",   DoubleToString(rsi, 1),
               " EMA200=",DoubleToString(ema, _Digits),
               " SL=",    DoubleToString(slPrice, _Digits),
               " TP=",    DoubleToString(tpPrice, _Digits));

         if(!trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "MACD Trend Sell"))
            Print("ERROR Sell. Code:", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
