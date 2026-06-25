//+------------------------------------------------------------------+
//|                                          EMA_RSI_Scalper.mq5    |
//|                    EMA+RSI+ADX Scalping Expert Advisor           |
//|                                          v3.0                    |
//|                                                                  |
//|  v3 core problem solved:                                         |
//|   EMA crossovers in ranging markets = constant false signals     |
//|   = 65% loss rate. Two new filters fix this:                    |
//|                                                                  |
//|   1. ADX filter — only enter when ADX > MinLevel (trending)     |
//|   2. DI lines  — +DI > -DI confirms bullish momentum            |
//|   3. H1 trend  — only trade WITH the higher timeframe direction  |
//|                                                                  |
//|  Recommended chart: M5                                           |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== EMA + RSI Settings ==="
input int    FastEMA_Period    = 5;    // Fast EMA period
input int    SlowEMA_Period    = 13;   // Slow EMA period
input int    RSI_Period        = 7;    // RSI period
input double RSI_Overbought    = 70.0; // Buy blocked above this RSI level
input double RSI_Oversold      = 30.0; // Sell blocked below this RSI level

input group "=== ADX Trend Strength Filter ==="
// ADX measures how strongly the market is trending (0-100).
// Below 20 = ranging/choppy market — EMA crossovers here are noise.
// Above 25 = clear trend. Above 40 = strong trend.
input int    ADX_Period        = 14;   // ADX period
input double ADX_MinLevel      = 20.0; // Skip entry if ADX is below this

input group "=== H1 Trend Direction Filter ==="
// Only buy when price is above the H1 EMA (uptrend on bigger picture).
// Only sell when price is below it. Eliminates counter-trend scalps.
input bool   UseHTF_Filter     = true; // Enable higher timeframe trend filter
input int    HTF_EMA_Period    = 50;   // H1 EMA period for trend baseline

input group "=== Risk & Money Management ==="
// IMPORTANT: Set RiskPercent to 5% first. Validate the strategy is
// profitable before increasing it. A losing strategy with 50% risk
// blows the account in a handful of trades.
input double RiskPercent       = 5.0;  // % of balance to risk per trade
input double MaxLots           = 20.0; // Hard ceiling on lot size
input int    StopLoss_Pips     = 15;   // Stop loss in pips
input int    TakeProfit_Pips   = 30;   // Take profit in pips (2:1 R:R)
input int    TrailingStop_Pips = 7;    // Trailing stop in pips (0 = disabled)
input int    MaxSpread_Pips    = 3;    // Skip entry if spread exceeds this (0 = off)

input group "=== EA Settings ==="
input long   MagicNumber       = 12345; // Unique tag for this EA's orders

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

int handleFastEMA;
int handleSlowEMA;
int handleRSI;
int handleADX;     // ADX indicator (gives ADX line + DI lines)
int handleHTF_EMA; // H1 trend EMA

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   handleFastEMA = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleADX     = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   handleHTF_EMA = iMA(_Symbol, PERIOD_H1, HTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(handleFastEMA == INVALID_HANDLE) { Print("ERROR: Fast EMA failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleSlowEMA == INVALID_HANDLE) { Print("ERROR: Slow EMA failed. Code:", GetLastError()); return INIT_FAILED; }
   if(handleRSI     == INVALID_HANDLE) { Print("ERROR: RSI failed. Code:",      GetLastError()); return INIT_FAILED; }
   if(handleADX     == INVALID_HANDLE) { Print("ERROR: ADX failed. Code:",      GetLastError()); return INIT_FAILED; }
   if(handleHTF_EMA == INVALID_HANDLE) { Print("ERROR: HTF EMA failed. Code:", GetLastError()); return INIT_FAILED; }

   if(RiskPercent > 20.0)
   {
      double rem = MathPow(1.0 - RiskPercent / 100.0, 3) * 100.0;
      Print("*** RISK WARNING: ", RiskPercent, "% risk. Three losses leave ",
            DoubleToString(rem, 1), "% of balance. Validate strategy at 5% first. ***");
   }

   Print("Scalper v3 | ", _Symbol, " ", EnumToString(PERIOD_CURRENT),
         " | ADX>", ADX_MinLevel, " | HTF:", UseHTF_Filter ? "ON" : "OFF",
         " | Risk:", RiskPercent, "% | SL:", StopLoss_Pips, " TP:", TakeProfit_Pips);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleHTF_EMA);
   Print("Scalper v3 removed. Reason:", reason);
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
//|                                                                   |
//| Sizes position so a full SL hit = RiskPercent% of balance.       |
//| Applies MaxLots cap then checks broker margin availability.       |
//+------------------------------------------------------------------+
double CalculateLots(int slPips, ENUM_ORDER_TYPE orderType)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = balance * RiskPercent / 100.0;

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

   // Scale down if broker margin would reject the order
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
         Print("Lots scaled to ", DoubleToString(lots, 2), " (margin limit: needed $",
               DoubleToString(marginNeeded, 2), " free $", DoubleToString(freeMargin, 2), ")");
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
   ManageTrailingStop();
   if(!IsNewBar())          return;
   if(!IsSpreadAcceptable()) return;

   // --- Read M5 EMA crossover data ---
   double fastNow[1], fastPrev[1], slowNow[1], slowPrev[1];
   if(CopyBuffer(handleFastEMA, 0, 1, 1, fastNow)  < 1) return;
   if(CopyBuffer(handleFastEMA, 0, 2, 1, fastPrev) < 1) return;
   if(CopyBuffer(handleSlowEMA, 0, 1, 1, slowNow)  < 1) return;
   if(CopyBuffer(handleSlowEMA, 0, 2, 1, slowPrev) < 1) return;

   // --- Read RSI ---
   double rsiVal[1];
   if(CopyBuffer(handleRSI, 0, 1, 1, rsiVal) < 1) return;

   // --- Read ADX (buffer 0) and DI lines (buffers 1, 2) ---
   // ADX main line tells us HOW STRONG the trend is.
   // +DI vs -DI tells us WHICH DIRECTION the trend is in.
   double adxMain[1], plusDI[1], minusDI[1];
   if(CopyBuffer(handleADX, 0, 1, 1, adxMain)  < 1) return;
   if(CopyBuffer(handleADX, 1, 1, 1, plusDI)   < 1) return;
   if(CopyBuffer(handleADX, 2, 1, 1, minusDI)  < 1) return;

   double fast   = fastNow[0];
   double fastP  = fastPrev[0];
   double slow   = slowNow[0];
   double slowP  = slowPrev[0];
   double rsi    = rsiVal[0];
   double adx    = adxMain[0];
   double pDI    = plusDI[0];
   double mDI    = minusDI[0];

   // --- ADX filter: skip choppy/ranging conditions ---
   // This is the most important filter. Below 20 ADX the market has no
   // trend — EMA crossovers are random noise and produce most of the losses.
   if(adx < ADX_MinLevel) return;

   // --- H1 trend filter ---
   // Read the last closed H1 bar EMA value to determine macro trend direction.
   bool htfBullish = true;
   bool htfBearish = true;
   if(UseHTF_Filter)
   {
      double htfEMA[1];
      if(CopyBuffer(handleHTF_EMA, 0, 1, 1, htfEMA) < 1) return;
      double price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      htfBullish = (price > htfEMA[0]); // price above H1 50 EMA → macro uptrend
      htfBearish = (price < htfEMA[0]); // price below H1 50 EMA → macro downtrend
   }

   // --- Crossover detection ---
   bool bullishCross = (fastP <= slowP) && (fast > slow);
   bool bearishCross = (fastP >= slowP) && (fast < slow);

   // --- Combined entry conditions ---
   // BUY requires all four to be true simultaneously:
   //   1. Bullish EMA crossover (timing trigger)
   //   2. RSI not overbought (not entering at exhaustion)
   //   3. +DI > -DI (ADX directional index confirms upward momentum)
   //   4. Price above H1 50 EMA (macro trend is up)
   bool buySignal  = bullishCross && (rsi < RSI_Overbought) && (pDI > mDI) && htfBullish;
   bool sellSignal = bearishCross && (rsi > RSI_Oversold)   && (mDI > pDI) && htfBearish;

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

         Print("BUY  | Lots=", DoubleToString(lots, 2),
               " ADX=",   DoubleToString(adx, 1),
               " +DI=",   DoubleToString(pDI, 1),
               " -DI=",   DoubleToString(mDI, 1),
               " RSI=",   DoubleToString(rsi, 1),
               " SL=",    DoubleToString(slPrice, _Digits),
               " TP=",    DoubleToString(tpPrice, _Digits));

         if(!trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "Scalper Buy"))
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

         Print("SELL | Lots=", DoubleToString(lots, 2),
               " ADX=",   DoubleToString(adx, 1),
               " +DI=",   DoubleToString(pDI, 1),
               " -DI=",   DoubleToString(mDI, 1),
               " RSI=",   DoubleToString(rsi, 1),
               " SL=",    DoubleToString(slPrice, _Digits),
               " TP=",    DoubleToString(tpPrice, _Digits));

         if(!trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "Scalper Sell"))
            Print("ERROR Sell. Code:", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
