//+------------------------------------------------------------------+
//|                                        XAUUSD_ProScalper.mq5    |
//|              XAUUSD Multi-Indicator Confluence EA  v1.0          |
//|                                                                  |
//|  A trade opens ONLY when every hard requirement passes AND at    |
//|  least MinScore of the 5 confirmation indicators agree.          |
//|  The Journal logs a detailed breakdown on every crossover signal.|
//|                                                                  |
//|  ── HARD REQUIREMENTS (all 5 must pass) ───────────────────────  |
//|  1. H4 Macro Trend  EMA(50) vs EMA(200) on H4 — golden/death   |
//|                     cross; price must be on the right side of   |
//|                     EMA(50).                                     |
//|  2. H1 Trend        Price above/below EMA(21) on H1.            |
//|  3. M5 Entry Signal EMA(10) crosses EMA(30) in trend direction. |
//|  4. Spread          Below MaxSpreadPoints.                       |
//|  5. ATR Spike Guard Current ATR < ATR_SpikeMultiplier × average.|
//|                     Skips news-spike candles.                    |
//|                                                                  |
//|  ── CONFIRMATION SCORE (need MinScore of these 5) ─────────────  |
//|  A. RSI(14)          Directional zone, not extreme.              |
//|  B. MACD(12,26,9)    Histogram positive for buys, negative sell. |
//|  C. Stochastic(5,3,3) %K not in overbought/oversold zone.       |
//|  D. Volume           Current bar tick volume > 20-bar average.   |
//|  E. Bollinger Bands  Price not near the opposite extreme band.   |
//|                                                                  |
//|  ── EXITS ──────────────────────────────────────────────────────  |
//|  • SL = ATR × SL_ATR,   TP = ATR × TP_ATR  (set at entry)      |
//|  • Breakeven: move SL→entry when price moves ATR × BE_ATR       |
//|  • Trailing stop: trail at ATR × Trail_ATR once in profit       |
//|                                                                  |
//|  ── SIZING ─────────────────────────────────────────────────────  |
//|  Risk-based: RiskPercent% of balance risked per trade.           |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== M5 Entry Signal ==="
input int    EMA_Fast        = 10;   // Fast EMA period (M5)
input int    EMA_Slow        = 30;   // Slow EMA period (M5)

input group "=== H1 Intermediate Trend ==="
input int    H1_EMA_Period   = 21;   // EMA period on H1

input group "=== H4 Macro Trend ==="
input int    H4_EMA_Fast     = 50;   // Fast EMA on H4 (golden/death cross)
input int    H4_EMA_Slow     = 200;  // Slow EMA on H4

input group "=== Confirmation A: RSI ==="
input int    RSI_Period      = 14;
input double RSI_BuyMin      = 40.0; // Buy zone: RSI must be above this
input double RSI_BuyMax      = 72.0; // Buy zone: RSI must be below this
input double RSI_SellMax     = 60.0; // Sell zone: RSI must be below this
input double RSI_SellMin     = 28.0; // Sell zone: RSI must be above this

input group "=== Confirmation B: MACD ==="
input int    MACD_Fast       = 12;
input int    MACD_Slow       = 26;
input int    MACD_Signal     = 9;

input group "=== Confirmation C: Stochastic ==="
input int    Stoch_K         = 5;
input int    Stoch_D         = 3;
input int    Stoch_Slowing   = 3;
input double Stoch_OBLevel   = 80.0; // Overbought level — blocks buys above this
input double Stoch_OSLevel   = 20.0; // Oversold level  — blocks sells below this

input group "=== Confirmation D: Volume ==="
input int    Vol_Lookback    = 20;   // Bars to average for volume comparison

input group "=== Confirmation E: Bollinger Bands ==="
input int    BB_Period       = 20;
input double BB_Deviation    = 2.0;
input double BB_ZonePercent  = 0.75; // Buy blocked above 75% of upper half; sell below 25% of lower

input group "=== Confluence Threshold ==="
input int    MinScore        = 3;    // Minimum confirmations required (1-5)

input group "=== ATR Exits ==="
input int    ATR_Period      = 14;
input double SL_ATR          = 1.5;  // SL distance = ATR × this
input double TP_ATR          = 3.0;  // TP distance = ATR × this  →  2:1 R:R
input double BE_ATR          = 1.0;  // Move SL to entry when price moves ATR × this in profit
input double Trail_ATR       = 1.5;  // Trailing stop distance in ATR (0 = disabled)

input group "=== Risk & Sizing ==="
input double RiskPercent     = 1.0;  // % of account balance to risk per trade
input double MaxLots         = 1.0;  // Hard lot cap regardless of risk calc
input int    MaxPositions    = 1;    // Max simultaneous open positions per direction

input group "=== Filters ==="
input int    MaxSpreadPoints    = 50;  // Max allowed spread in points (0 = off)
input double ATR_SpikeMultiplier = 2.5; // Block if ATR > this × avg ATR (0 = off)
input int    CooldownSeconds    = 60;  // Seconds to wait after a close

input group "=== Session Filter (GMT) ==="
input bool   UseSessionFilter   = true;
input int    SessionStartHour   = 7;   // London open
input int    SessionEndHour     = 22;  // NY close

input group "=== EA Settings ==="
input long   MagicNumber     = 77777;

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade trade;

// Indicator handles
int h_FastEMA;   // EMA(10)  M5
int h_SlowEMA;   // EMA(30)  M5
int h_H1_EMA;    // EMA(21)  H1
int h_H4_Fast;   // EMA(50)  H4
int h_H4_Slow;   // EMA(200) H4
int h_RSI;       // RSI(14)  M5
int h_MACD;      // MACD     M5
int h_Stoch;     // Stoch    M5
int h_ATR;       // ATR(14)  M5
int h_BB;        // BB(20,2) M5

datetime lastBarTime   = 0;
datetime lastCloseTime = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   h_FastEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast,      0, MODE_EMA, PRICE_CLOSE);
   h_SlowEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow,      0, MODE_EMA, PRICE_CLOSE);
   h_H1_EMA  = iMA(_Symbol, PERIOD_H1,     H1_EMA_Period,  0, MODE_EMA, PRICE_CLOSE);
   h_H4_Fast = iMA(_Symbol, PERIOD_H4,     H4_EMA_Fast,    0, MODE_EMA, PRICE_CLOSE);
   h_H4_Slow = iMA(_Symbol, PERIOD_H4,     H4_EMA_Slow,    0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   h_Stoch   = iStochastic(_Symbol, PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slowing,
                            MODE_SMA, STO_LOWHIGH);
   h_ATR     = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   h_BB      = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);

   bool ok = true;
   if(h_FastEMA == INVALID_HANDLE) { Print("ERROR: M5 Fast EMA"); ok = false; }
   if(h_SlowEMA == INVALID_HANDLE) { Print("ERROR: M5 Slow EMA"); ok = false; }
   if(h_H1_EMA  == INVALID_HANDLE) { Print("ERROR: H1 EMA");      ok = false; }
   if(h_H4_Fast == INVALID_HANDLE) { Print("ERROR: H4 Fast EMA"); ok = false; }
   if(h_H4_Slow == INVALID_HANDLE) { Print("ERROR: H4 Slow EMA"); ok = false; }
   if(h_RSI     == INVALID_HANDLE) { Print("ERROR: RSI");         ok = false; }
   if(h_MACD    == INVALID_HANDLE) { Print("ERROR: MACD");        ok = false; }
   if(h_Stoch   == INVALID_HANDLE) { Print("ERROR: Stochastic");  ok = false; }
   if(h_ATR     == INVALID_HANDLE) { Print("ERROR: ATR");         ok = false; }
   if(h_BB      == INVALID_HANDLE) { Print("ERROR: Bol Bands");   ok = false; }
   if(!ok) return INIT_FAILED;

   Print("=== XAUUSD ProScalper v1.0 Started ===");
   Print("Symbol: ", _Symbol, " | Risk: ", RiskPercent, "% | MaxLots: ", MaxLots);
   Print("ATR exits: SL×", SL_ATR, " TP×", TP_ATR, " BE×", BE_ATR, " Trail×", Trail_ATR);
   Print("Min confirmation score: ", MinScore, "/5");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int handles[] = {h_FastEMA, h_SlowEMA, h_H1_EMA, h_H4_Fast,
                    h_H4_Slow, h_RSI, h_MACD, h_Stoch, h_ATR, h_BB};
   for(int i = 0; i < ArraySize(handles); i++)
      IndicatorRelease(handles[i]);
   Print("XAUUSD ProScalper removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| CalcLots — risk-based position sizing                             |
//|                                                                   |
//| Sizes the position so that if SL is hit, the loss equals         |
//| RiskPercent% of current account balance.                         |
//+------------------------------------------------------------------+
double CalcLots(double slDistPrice)
{
   if(slDistPrice <= 0) return 0.01;
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt     = balance * RiskPercent / 100.0;
   double tickSz      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSz <= 0 || tickVal <= 0) return 0.01;
   double lossPerLot  = (slDistPrice / tickSz) * tickVal;
   if(lossPerLot <= 0) return 0.01;
   double lots = riskAmt / lossPerLot;
   lots = MathFloor(lots / 0.01) * 0.01;
   lots = MathMax(lots, 0.01);
   lots = MathMin(lots, MaxLots);
   return lots;
}

//+------------------------------------------------------------------+
//| ReadATR — returns last closed bar ATR; 0 on failure              |
//+------------------------------------------------------------------+
double ReadATR()
{
   double buf[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, buf) < 1) return 0;
   return buf[0];
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
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > MaxSpreadPoints)
   {
      static datetime last = 0;
      if(TimeCurrent() - last > 60) { Print("FILTER: Spread=", sp, " > max ", MaxSpreadPoints); last = TimeCurrent(); }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsATRNormal — compares current ATR against recent average        |
//+------------------------------------------------------------------+
bool IsATRNormal(double currentATR)
{
   if(ATR_SpikeMultiplier <= 0 || currentATR <= 0) return true;
   double buf[20];
   if(CopyBuffer(h_ATR, 0, 1, 20, buf) < 20) return true;
   double sum = 0;
   for(int i = 0; i < 20; i++) sum += buf[i];
   double avg = sum / 20.0;
   if(currentATR > ATR_SpikeMultiplier * avg)
   {
      Print("FILTER: ATR spike ", DoubleToString(currentATR,2),
            " > ", ATR_SpikeMultiplier, "× avg(", DoubleToString(avg,2), ")");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| IsSessionOK                                                       |
//+------------------------------------------------------------------+
bool IsSessionOK()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   if(SessionStartHour <= SessionEndHour)
      return (h >= SessionStartHour && h < SessionEndHour);
   return (h >= SessionStartHour || h < SessionEndHour);
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
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol     &&
         PositionGetInteger(POSITION_MAGIC)  == MagicNumber &&
         PositionGetInteger(POSITION_TYPE)   == posType) n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| ManageOpenPositions                                               |
//|                                                                   |
//| Runs every tick. Applies breakeven and trailing stop.            |
//| Broker handles the SL/TP price levels set at entry automatically. |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atr = ReadATR();
   if(atr <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;

         // Breakeven
         double beTrigger = atr * BE_ATR;
         double beSL      = NormalizeDouble(openPrice + _Point, _Digits);
         if(BE_ATR > 0 && profit >= beTrigger && currentSL < openPrice)
         {
            trade.PositionModify(ticket, beSL, currentTP);
            Print("Breakeven set BUY #", ticket, " SL→", DoubleToString(beSL, _Digits));
            currentSL = beSL;
         }

         // Trailing stop (only once at breakeven or better)
         if(Trail_ATR > 0 && currentSL >= openPrice - _Point)
         {
            double trailSL = NormalizeDouble(bid - atr * Trail_ATR, _Digits);
            if(trailSL > currentSL + _Point)
            {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;

         // Breakeven
         double beTrigger = atr * BE_ATR;
         double beSL      = NormalizeDouble(openPrice - _Point, _Digits);
         if(BE_ATR > 0 && profit >= beTrigger &&
            (currentSL == 0 || currentSL > openPrice))
         {
            trade.PositionModify(ticket, beSL, currentTP);
            Print("Breakeven set SELL #", ticket, " SL→", DoubleToString(beSL, _Digits));
            currentSL = beSL;
         }

         // Trailing stop
         if(Trail_ATR > 0 && currentSL > 0 && currentSL <= openPrice + _Point)
         {
            double trailSL = NormalizeDouble(ask + atr * Trail_ATR, _Digits);
            if(trailSL < currentSL - _Point)
            {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CalcConfirmationScore                                             |
//|                                                                   |
//| Evaluates the 5 confirmation indicators and returns a score       |
//| (0-5). Also builds a breakdown string for Journal logging.       |
//+------------------------------------------------------------------+
int CalcConfirmationScore(bool isBuy, double bid, string &breakdown)
{
   int score = 0;
   breakdown = "";

   // ── A. RSI ───────────────────────────────────────────────────────
   double rsiBuf[1];
   string rsiLabel = "RSI:NO_DATA";
   if(CopyBuffer(h_RSI, 0, 1, 1, rsiBuf) >= 1)
   {
      double rsi = rsiBuf[0];
      bool rsiOk = isBuy ? (rsi >= RSI_BuyMin && rsi <= RSI_BuyMax)
                         : (rsi <= RSI_SellMax && rsi >= RSI_SellMin);
      if(rsiOk) score++;
      rsiLabel = StringFormat("RSI:%.1f%s", rsi, rsiOk ? "✓" : "✗");
   }
   breakdown += rsiLabel + " ";

   // ── B. MACD histogram ────────────────────────────────────────────
   double macdMain[1], macdSig[1];
   string macdLabel = "MACD:NO_DATA";
   if(CopyBuffer(h_MACD, 0, 1, 1, macdMain) >= 1 &&
      CopyBuffer(h_MACD, 1, 1, 1, macdSig)  >= 1)
   {
      double hist  = macdMain[0] - macdSig[0];
      bool macdOk  = isBuy ? (hist > 0) : (hist < 0);
      if(macdOk) score++;
      macdLabel = StringFormat("MACD:%.4f%s", hist, macdOk ? "✓" : "✗");
   }
   breakdown += macdLabel + " ";

   // ── C. Stochastic ────────────────────────────────────────────────
   double stochK[1];
   string stochLabel = "STOCH:NO_DATA";
   if(CopyBuffer(h_Stoch, 0, 1, 1, stochK) >= 1)
   {
      double k     = stochK[0];
      bool stochOk = isBuy ? (k < Stoch_OBLevel) : (k > Stoch_OSLevel);
      if(stochOk) score++;
      stochLabel = StringFormat("STOCH:%.1f%s", k, stochOk ? "✓" : "✗");
   }
   breakdown += stochLabel + " ";

   // ── D. Volume ────────────────────────────────────────────────────
   long volBuf[];
   string volLabel = "VOL:NO_DATA";
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, Vol_Lookback + 1, volBuf) >= Vol_Lookback + 1)
   {
      long currentVol = volBuf[0];
      double sum = 0;
      for(int i = 1; i <= Vol_Lookback; i++) sum += (double)volBuf[i];
      double avgVol = sum / Vol_Lookback;
      bool volOk = (avgVol > 0 && currentVol > avgVol);
      if(volOk) score++;
      volLabel = StringFormat("VOL:%d/avg%.0f%s", currentVol, avgVol, volOk ? "✓" : "✗");
   }
   breakdown += volLabel + " ";

   // ── E. Bollinger Bands ───────────────────────────────────────────
   double bbMid[1], bbUpper[1], bbLower[1];
   string bbLabel = "BB:NO_DATA";
   if(CopyBuffer(h_BB, 0, 1, 1, bbMid)   >= 1 &&
      CopyBuffer(h_BB, 1, 1, 1, bbUpper) >= 1 &&
      CopyBuffer(h_BB, 2, 1, 1, bbLower) >= 1)
   {
      double upperHalf = bbMid[0] + (bbUpper[0] - bbMid[0]) * BB_ZonePercent;
      double lowerHalf = bbLower[0] + (bbMid[0] - bbLower[0]) * (1.0 - BB_ZonePercent);
      bool bbOk = isBuy ? (bid < upperHalf) : (bid > lowerHalf);
      if(bbOk) score++;
      bbLabel = StringFormat("BB:%s", bbOk ? "room✓" : "extreme✗");
   }
   breakdown += bbLabel;

   return score;
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPositions();

   if(!IsNewBar())       return;
   if(!IsCooldownOver()) return;
   if(!IsSpreadOK())     return;
   if(!IsSessionOK())    return;

   // ── Read ATR — needed for spike filter and sizing ─────────────────
   double atr = ReadATR();
   if(atr <= 0 || !IsATRNormal(atr)) return;

   // ── M5 EMA Crossover ─────────────────────────────────────────────
   double fastBuf[2], slowBuf[2];
   if(CopyBuffer(h_FastEMA, 0, 1, 2, fastBuf) < 2) return;
   if(CopyBuffer(h_SlowEMA, 0, 1, 2, slowBuf) < 2) return;

   double fastNow  = fastBuf[0]; double fastPrev = fastBuf[1];
   double slowNow  = slowBuf[0]; double slowPrev = slowBuf[1];

   bool bullCross = (fastPrev <= slowPrev) && (fastNow > slowNow);
   bool bearCross = (fastPrev >= slowPrev) && (fastNow < slowNow);
   if(!bullCross && !bearCross) return; // No crossover — nothing to evaluate

   bool isBuy = bullCross;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // ── HARD REQUIREMENT 1: H4 Macro Trend ───────────────────────────
   // EMA(50) vs EMA(200) golden/death cross + price on correct side
   double h4FastBuf[1], h4SlowBuf[1];
   bool h4ok = false;
   string h4Label = "H4:NO_DATA";
   if(CopyBuffer(h_H4_Fast, 0, 1, 1, h4FastBuf) >= 1 &&
      CopyBuffer(h_H4_Slow, 0, 1, 1, h4SlowBuf) >= 1)
   {
      double h4Fast = h4FastBuf[0];
      double h4Slow = h4SlowBuf[0];
      if(isBuy)  h4ok = (h4Fast > h4Slow) && (bid > h4Fast); // golden cross, price above EMA50
      else       h4ok = (h4Fast < h4Slow) && (bid < h4Fast); // death cross, price below EMA50
      h4Label = StringFormat("H4(EMA%d=%.1f/EMA%d=%.1f)%s",
                              H4_EMA_Fast, h4Fast, H4_EMA_Slow, h4Slow, h4ok ? "✓" : "✗");
   }

   // ── HARD REQUIREMENT 2: H1 Intermediate Trend ────────────────────
   double h1Buf[1];
   bool h1ok = false;
   string h1Label = "H1:NO_DATA";
   if(CopyBuffer(h_H1_EMA, 0, 1, 1, h1Buf) >= 1)
   {
      double h1ema = h1Buf[0];
      h1ok = isBuy ? (bid > h1ema) : (bid < h1ema);
      h1Label = StringFormat("H1EMA%d=%.1f%s", H1_EMA_Period, h1ema, h1ok ? "✓" : "✗");
   }

   // ── Confirmation Score ────────────────────────────────────────────
   string scoreBD;
   int score = CalcConfirmationScore(isBuy, bid, scoreBD);

   // ── Full diagnostic log on every crossover ────────────────────────
   string crossDir = isBuy ? "BUY↑" : "SELL↓";
   Print(crossDir, " CROSS | ", h4Label, " | ", h1Label,
         " | Score=", score, "/", MinScore, " [", scoreBD, "]");

   // ── Check all hard requirements ───────────────────────────────────
   if(!h4ok)        { Print("  BLOCKED by H4 trend"); return; }
   if(!h1ok)        { Print("  BLOCKED by H1 trend"); return; }
   if(score < MinScore) { Print("  BLOCKED: score ", score, " < min ", MinScore); return; }

   // ── Position limit ────────────────────────────────────────────────
   ENUM_POSITION_TYPE direction = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   if(CountPositions(direction) >= MaxPositions)
   {
      Print("  BLOCKED: already at MaxPositions(", MaxPositions, ")");
      return;
   }

   // ── Calculate SL, TP and lot size ────────────────────────────────
   double slDist  = atr * SL_ATR;
   double tpDist  = atr * TP_ATR;
   double lots    = CalcLots(slDist);

   // ── Execute ───────────────────────────────────────────────────────
   if(isBuy)
   {
      double slPrice = NormalizeDouble(ask - slDist, _Digits);
      double tpPrice = NormalizeDouble(ask + tpDist, _Digits);
      Print("  >>> OPENING BUY | Lots=", lots,
            " ATR=", DoubleToString(atr, 2),
            " SL=", DoubleToString(slPrice, _Digits),
            " TP=", DoubleToString(tpPrice, _Digits));
      if(!trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "ProScalper Buy"))
         Print("  ERROR Buy: ", GetLastError());
   }
   else
   {
      double slPrice = NormalizeDouble(bid + slDist, _Digits);
      double tpPrice = NormalizeDouble(bid - tpDist, _Digits);
      Print("  >>> OPENING SELL | Lots=", lots,
            " ATR=", DoubleToString(atr, 2),
            " SL=", DoubleToString(slPrice, _Digits),
            " TP=", DoubleToString(tpPrice, _Digits));
      if(!trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "ProScalper Sell"))
         Print("  ERROR Sell: ", GetLastError());
   }
}
//+------------------------------------------------------------------+
