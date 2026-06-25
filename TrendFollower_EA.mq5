//+------------------------------------------------------------------+
//|                                          TrendFollower_EA.mq5   |
//|                  Three-EMA + RSI Trend Following EA              |
//|                                                                  |
//|  Strategy overview:                                              |
//|   TREND  — Three EMAs must all be stacked in the same order.    |
//|            EMA21 > EMA50 > EMA200 = uptrend.                    |
//|            EMA21 < EMA50 < EMA200 = downtrend.                  |
//|            If EMAs are tangled/mixed = no trade, market ranging. |
//|                                                                  |
//|   ENTRY  — Wait for price to pull back against the trend        |
//|            until RSI dips near 50, then enter as RSI crosses    |
//|            back above 50 (momentum resuming with the trend).    |
//|                                                                  |
//|   EXIT   — Fixed TP (3:1 R:R), trailing stop, OR early close   |
//|            if the EMA stack loses alignment (trend ended).       |
//|                                                                  |
//|  Recommended chart: H1                                           |
//|  Recommended pair:  EURUSD, GBPUSD, USDJPY                      |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== EMA Settings ==="
input int    EMA_Fast          = 21;   // Fast EMA (short-term momentum)
input int    EMA_Mid           = 50;   // Mid EMA (medium-term trend)
input int    EMA_Slow          = 200;  // Slow EMA (long-term trend baseline)

input group "=== RSI Settings ==="
input int    RSI_Period        = 14;   // RSI period
input double RSI_Upper         = 70.0; // Overbought — block buys above this
input double RSI_Lower         = 30.0; // Oversold — block sells below this

input group "=== Risk & Money Management ==="
// IMPORTANT: Validate at 5% risk first.
// Only increase to 50% after confirming the strategy is profitable.
input double RiskPercent       = 5.0;  // % of account balance to risk per trade
input double MaxLots           = 20.0; // Hard ceiling on lot size
input int    StopLoss_Pips     = 40;   // Stop loss in pips (H1 needs room to breathe)
input int    TakeProfit_Pips   = 120;  // Take profit in pips (3:1 R:R)
input int    TrailingStop_Pips = 25;   // Trailing stop in pips (0 = disabled)
input int    MaxSpread_Pips    = 3;    // Skip entry if spread exceeds this (0 = off)

input group "=== EA Behaviour ==="
// When EMAs lose their alignment the trend may be over.
// Enabling this closes the trade early rather than waiting for SL/TP.
input bool   CloseOnTrendEnd   = true; // Close trade if EMA stack loses alignment
input long   MagicNumber       = 77777; // Unique ID for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int handleFast;   // EMA 21
int handleMid;    // EMA 50
int handleSlow;   // EMA 200
int handleRSI;    // RSI 14

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   handleFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleMid  = iMA(_Symbol, PERIOD_CURRENT, EMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
   handleSlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI  = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(handleFast == INVALID_HANDLE) { Print("ERROR: EMA", EMA_Fast, " failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleMid  == INVALID_HANDLE) { Print("ERROR: EMA", EMA_Mid,  " failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleSlow == INVALID_HANDLE) { Print("ERROR: EMA", EMA_Slow, " failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleRSI  == INVALID_HANDLE) { Print("ERROR: RSI failed. Code:", GetLastError());               return INIT_FAILED; }

   if(RiskPercent > 20.0)
   {
      double rem = MathPow(1.0 - RiskPercent / 100.0, 3) * 100.0;
      Print("*** RISK WARNING: ", RiskPercent, "% risk. Three losses leave ",
            DoubleToString(rem, 1), "% of balance. Run at 5% first. ***");
   }

   Print("TrendFollower EA ready | ", _Symbol, " ", EnumToString(PERIOD_CURRENT),
         " | EMA ", EMA_Fast, "/", EMA_Mid, "/", EMA_Slow,
         " | RSI ", RSI_Period,
         " | SL ", StopLoss_Pips, " TP ", TakeProfit_Pips, " pips",
         " | Risk ", RiskPercent, "%");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFast);
   IndicatorRelease(handleMid);
   IndicatorRelease(handleSlow);
   IndicatorRelease(handleRSI);
   Print("TrendFollower EA removed. Reason:", reason);
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

   // Scale down if free margin is insufficient
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
               " (margin: needed $", DoubleToString(marginNeeded, 2),
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
//| GetPositionTicket — returns ticket of first matching position     |
//+------------------------------------------------------------------+
ulong GetPositionTicket(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol     &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType)
         return ticket;
   }
   return 0;
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
//| ManageTrailingStop — every tick                                   |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(TrailingStop_Pips <= 0) return;
   double trailDist = TrailingStop_Pips * GetPipSize();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > sl + _Point)
            trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(sl == 0 || newSL < sl - _Point)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Trailing stop runs on every tick for precise price tracking
   ManageTrailingStop();

   if(!IsNewBar())           return;
   if(!IsSpreadAcceptable()) return;

   // --- Read the last two closed bars for all indicators ---
   // Index 1 = last closed bar (used for current state)
   // Index 2 = bar before that (used to detect RSI crossing 50)

   double fast1[1], fast2[1];
   double mid1[1];
   double slow1[1];
   double rsi1[1], rsi2[1];

   if(CopyBuffer(handleFast, 0, 1, 1, fast1) < 1) return;
   if(CopyBuffer(handleFast, 0, 2, 1, fast2) < 1) return;
   if(CopyBuffer(handleMid,  0, 1, 1, mid1)  < 1) return;
   if(CopyBuffer(handleSlow, 0, 1, 1, slow1) < 1) return;
   if(CopyBuffer(handleRSI,  0, 1, 1, rsi1)  < 1) return;
   if(CopyBuffer(handleRSI,  0, 2, 1, rsi2)  < 1) return;

   double ema21  = fast1[0];
   double ema50  = mid1[0];
   double ema200 = slow1[0];
   double rsiNow  = rsi1[0];
   double rsiPrev = rsi2[0];

   // --- EMA stack alignment ---
   // All three must be in strict order for a valid trend.
   // Any other arrangement = market is transitioning or ranging = no trade.
   bool stackBull = (ema21 > ema50) && (ema50 > ema200); // 21 > 50 > 200 → uptrend
   bool stackBear = (ema21 < ema50) && (ema50 < ema200); // 21 < 50 < 200 → downtrend

   // --- Early exit: close trade if trend ends ---
   // If we're in a buy and the EMA stack loses bullish alignment, the trend
   // may be reversing. Close to protect profit rather than wait for SL.
   if(CloseOnTrendEnd)
   {
      if(CountPositions(POSITION_TYPE_BUY) > 0 && !stackBull)
      {
         Print("Trend ended (EMA stack lost alignment) — closing BUY");
         ClosePositions(POSITION_TYPE_BUY);
      }
      if(CountPositions(POSITION_TYPE_SELL) > 0 && !stackBear)
      {
         Print("Trend ended (EMA stack lost alignment) — closing SELL");
         ClosePositions(POSITION_TYPE_SELL);
      }
   }

   // --- RSI cross of 50 — the entry trigger ---
   // In an uptrend, price pulls back slightly → RSI drops near/below 50.
   // When RSI crosses back above 50 it signals momentum is resuming with
   // the trend — that's our entry point.
   bool rsiBullCross = (rsiPrev < 50.0) && (rsiNow >= 50.0); // RSI crossed above 50
   bool rsiBearCross = (rsiPrev > 50.0) && (rsiNow <= 50.0); // RSI crossed below 50

   // Block entries at overbought/oversold extremes — if RSI is already at 70+
   // on a buy trigger, the pullback entry is too late and the move is exhausted
   bool notExtreme_buy  = (rsiNow < RSI_Upper);
   bool notExtreme_sell = (rsiNow > RSI_Lower);

   // --- Final entry signals ---
   bool buySignal  = stackBull && rsiBullCross && notExtreme_buy;
   bool sellSignal = stackBear && rsiBearCross && notExtreme_sell;

   double pip    = GetPipSize();
   double slDist = StopLoss_Pips   * pip;
   double tpDist = TakeProfit_Pips * pip;
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ================================================================
   // BUY: uptrend confirmed + RSI momentum resuming from pullback
   // ================================================================
   if(buySignal)
   {
      // Close any open sell before reversing direction
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

         Print("BUY  | Lots=",   DoubleToString(lots, 2),
               " EMA21=",  DoubleToString(ema21, _Digits),
               " EMA50=",  DoubleToString(ema50, _Digits),
               " EMA200=", DoubleToString(ema200, _Digits),
               " RSI=",    DoubleToString(rsiNow, 1),
               " SL=",     DoubleToString(slPrice, _Digits),
               " TP=",     DoubleToString(tpPrice, _Digits));

         if(!trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "Trend Buy"))
            Print("ERROR Buy. Code:", GetLastError());
      }
   }

   // ================================================================
   // SELL: downtrend confirmed + RSI momentum resuming from pullback
   // ================================================================
   else if(sellSignal)
   {
      // Close any open buy before reversing direction
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

         Print("SELL | Lots=",   DoubleToString(lots, 2),
               " EMA21=",  DoubleToString(ema21, _Digits),
               " EMA50=",  DoubleToString(ema50, _Digits),
               " EMA200=", DoubleToString(ema200, _Digits),
               " RSI=",    DoubleToString(rsiNow, 1),
               " SL=",     DoubleToString(slPrice, _Digits),
               " TP=",     DoubleToString(tpPrice, _Digits));

         if(!trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "Trend Sell"))
            Print("ERROR Sell. Code:", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
