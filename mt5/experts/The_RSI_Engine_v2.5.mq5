//+------------------------------------------------------------------+
//|                                           The_RSI_Engine.mq5    |
//|                                      Copyright 2025, SPLpulse   |
//|                                           https://splpulse.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, The RSI Engine MT5 EA by SPLpluse"
#property link      "https://splpulse.com"
#property version   "2.5" // v2.5: exit requires BOTH price slope AND RSI slope reversal (breathing room)

//--- Include the standard MQL5 trading library
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\DealInfo.mqh>

//--- EA INPUT PARAMETERS
//--- Trade Management Group
input group "Trade Management"
input bool   InpUseRiskManagement  = false;     // Use dynamic lot sizing based on risk?
input double InpRiskPercent        = 1.0;       // Risk percentage of equity per trade (if enabled)
input double InpLots               = 0.1;       // Fixed Lot size (if risk management is disabled)
input int    InpStopLossPoints     = 500;       // Stop Loss in points -keep wide to give trades room to breathe
input int    InpTakeProfitPoints   = 300;       // Take Profit in points (0 = disabled; primary exit is slope reversal)
input ulong  InpMagicNumber        = 1901;      // Unique ID for EA's trades
input int    InpMaxSpreadPoints    = 30;        // Max allowed spread in points

//--- Trailing Stop Group
input group "Trailing Stop"
input bool   InpUseTrailingStop       = true;   // Enable Trailing Stop Loss?
input bool   InpUseBreakEven          = true;   // Move SL to break-even before trailing?
input int    InpBreakEvenTrigger      = 250;    // Profit (points) to trigger break-even
input int    InpTrailingStopTrigger   = 800;    // Profit (points) to start trailing
input int    InpTrailingStopStep      = 150;    // Trailing distance from current price (in points)

//--- RSI Settings Group
input group "RSI Settings"
input int    InpRSI_Period         = 7;         // Period for the RSI indicator
input int    InpRSI_Overbought     = 70;        // Overbought level (used only if RSI level exit is on)
input int    InpRSI_Oversold       = 30;        // Oversold level  (used only if RSI level exit is on)

//--- Strategy Signals & Exits Group
input group "Strategy Signals & Exits"
input bool   InpUse_RSI_Level_Exit       = false; // Exit when RSI reaches opposite extreme
input bool   InpUse_Slope_Alignment_Exit = true;  // Exit when BOTH price and RSI slopes reverse
input int    InpSlope_Lookback_Bars      = 50;    // Lookback bars for divergence detection and exit (stable)
input int    InpEntry_Lookback_Bars      = 20;    // Lookback bars for entry alignment trigger (responsive)
input bool   InpUseChannelSL             = true;  // Dynamic SL at regression channel band (trails with slope)
input double InpChannelSL_StdDevMul      = 2.0;   // Channel SL width: std deviations from regression line
input int    InpChannelSL_SforoBuf       = 30;    // Extra points beyond channel band (absorbs wicks / sforamenti)
input bool   InpVerboseEntryLogs         = false; // Print detailed entry-block reasons

//--- Daily Limits Group
input group "Daily Limits (in Deposit Currency)"
input bool   EnableDailyLimits    = false;      // Enable daily profit/loss limits?
input double DailyProfitTarget    = 500.0;      // Stop trading for the day if this profit is reached
input double DailyLossLimit       = 200.0;      // Stop trading for the day if this loss is reached

//--- News Filter Group
input group "News Filter (Server Time)"
input bool   InpUseNewsFilter       = false;    // Enable News Filter?
input bool   InpCloseBeforeNews     = true;     // Close open position when entering pre-news window?
input int    InpNewsTimeHour        = 15;       // News Event Hour (e.g., 15 for 3 PM)
input int    InpNewsTimeMinute      = 30;       // News Event Minute (e.g., 30)
input int    InpMinutesBeforeNews   = 10;       // Stop trading X minutes BEFORE news
input int    InpMinutesAfterNews    = 10;       // Resume trading X minutes AFTER news

//--- Trading Hours Group
input group "Trading Hours (Server Time)"
input bool   EnableTimeFilter     = false;      // Enable or disable the time filter
input string MondayHours          = "16:30-18:00;09:00-11:00";
input string TuesdayHours         = "16:30-18:00;09:00-11:00";
input string WednesdayHours       = "16:30-18:00;09:00-11:00";
input string ThursdayHours        = "16:30-18:00;09:00-11:00";
input string FridayHours          = "16:30-18:00;09:00-11:00";
input string SaturdayHours        = "00:00-00:00";
input string SundayHours          = "00:00-00:00";
input bool   CloseAtEndTime       = false;      // Close all trades when a trading session ends?

//--- Global objects and variables
CTrade        trade;
CPositionInfo posInfo;
CAccountInfo  account;
CDealInfo     deal;
int           rsi_handle;

//--- Global state variables for limits
datetime      g_last_limit_check_day = 0;
bool          g_daily_limit_reached  = false;

bool          g_saw_bullish_div  = false;
bool          g_saw_bearish_div  = false;
bool          g_was_in_position  = false;
double        g_daily_pnl        = 0.0;
datetime      g_daily_pnl_day    = 0;

//+------------------------------------------------------------------+
//| Accumulates closed trade P&L and prints running daily total      |
//+------------------------------------------------------------------+
void LogTradePnl(double profit)
{
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(g_daily_pnl_day != today) { g_daily_pnl = 0.0; g_daily_pnl_day = today; }
    g_daily_pnl += profit;
    string cur = AccountInfoString(ACCOUNT_CURRENCY);
    PrintFormat("[PNL] trade: %+.2f %s | day total: %+.2f %s",
                profit, cur, g_daily_pnl, cur);
}

//+------------------------------------------------------------------+
//| Returns profit+commission+swap of the most recently closed deal  |
//+------------------------------------------------------------------+
double GetLastDealProfit()
{
    if(!HistorySelect(TimeCurrent() - 86400, TimeCurrent())) return 0.0;
    for(int i = (int)HistoryDealsTotal() - 1; i >= 0; i--)
    {
        if(!deal.SelectByIndex(i)) continue;
        if(deal.Magic() != InpMagicNumber) continue;
        if(deal.Symbol() != _Symbol) continue;
        if(deal.Entry() != DEAL_ENTRY_OUT) continue;
        return deal.Profit() + deal.Commission() + deal.Swap();
    }
    return 0.0;
}

//+------------------------------------------------------------------+
//| Returns the period used for slope-based divergence               |
//+------------------------------------------------------------------+
int GetSlopePeriod()
{
    return (InpSlope_Lookback_Bars > 2) ? InpSlope_Lookback_Bars : 3;
}

//+------------------------------------------------------------------+
//| Custom RSI Function using the indicator handle                   |
//+------------------------------------------------------------------+
double GetRSI(const int shift)
{
    double rsi_buffer[1];
    if(CopyBuffer(rsi_handle, 0, shift, 1, rsi_buffer) > 0)
        return rsi_buffer[0];
    Print("Error copying RSI buffer - ", GetLastError());
    return -1;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFillingBySymbol(_Symbol);

    rsi_handle = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
    if(rsi_handle == INVALID_HANDLE)
    {
        Print("Error creating RSI indicator handle - ", GetLastError());
        return(INIT_FAILED);
    }

    if(InpUseRiskManagement && InpStopLossPoints <= 0)
    {
        Print("Error: Stop Loss must be > 0 for risk management. EA will not trade.");
        return(INIT_FAILED);
    }

    int bePoints = (InpBreakEvenTrigger > 0) ? InpBreakEvenTrigger : InpStopLossPoints;
    PrintFormat("RSI Engine v2.5 initialized. BreakEven trigger: %d pts, Trailing trigger: %d pts",
                bePoints, InpTrailingStopTrigger);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(rsi_handle);
    Print("RSI Engine v2.5 deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (main logic)                                |
//+------------------------------------------------------------------+
void OnTick()
{
    // Tasks that run on EVERY tick
    ManageSessionEnd();
    ManageNewsClose();
    ManageTrailingStop();
    bool now_in_position = IsPositionOpen();
    if(now_in_position) ManageOpenTrades();
    if(g_was_in_position && !now_in_position)
    {
        // Position closed externally (SL, TP, or manual) -log the last deal
        if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))
        {
            int total = (int)HistoryDealsTotal();
            for(int i = total - 1; i >= 0; i--)
            {
                if(!deal.SelectByIndex(i)) continue;
                if(deal.Magic() != InpMagicNumber) continue;
                if(deal.Entry() != DEAL_ENTRY_OUT) continue;
                long dealReason = HistoryDealGetInteger(deal.Ticket(), DEAL_REASON);
                string closeReason = "";
                if(dealReason == DEAL_REASON_SL)       closeReason = "STOP LOSS hit";
                else if(dealReason == DEAL_REASON_TP)  closeReason = "TAKE PROFIT hit";
                else if(dealReason == DEAL_REASON_SO)  closeReason = "STOP OUT (margin)";
                else                                   closeReason = "closed externally";
                double extProfit = deal.Profit() + deal.Commission() + deal.Swap();
                PrintFormat("[EXIT] %s -%s | profit: %+.2f %s | price: %.5f",
                            deal.Type() == DEAL_TYPE_BUY ? "SELL closed" : "BUY closed",
                            closeReason, extProfit, AccountInfoString(ACCOUNT_CURRENCY), deal.Price());
                LogTradePnl(extProfit);
                break;
            }
        }
        g_saw_bullish_div = false;
        g_saw_bearish_div = false;
    }
    g_was_in_position = now_in_position;

    // Tasks that run ONCE PER BAR
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if(lastBarTime == currentBarTime) return;
    lastBarTime = currentBarTime;


    if(IsPositionOpen()) return;

    // Spread filter -only for new entries
    double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    if(spreadPoints > InpMaxSpreadPoints)
    {
        PrintFormat("Entry blocked: spread too high (%.1f > %d pts)", spreadPoints, InpMaxSpreadPoints);
        return;
    }

    CheckForEntrySignals();
}

//+------------------------------------------------------------------+
//| Computes regression channel: midline ± K*stdDev on last N bars  |
//+------------------------------------------------------------------+
bool ComputeChannelBands(double &lowerBand, double &upperBand)
{
    const int period = GetSlopePeriod();
    double prices[];
    if(CopyClose(_Symbol, _Period, 1, period, prices) < period) return false;

    double sumx=0, sumxx=0, sumxy=0, sumy=0;
    for(int k=0; k<period; k++)
    {
        sumx  += k;
        sumxx += (double)k * k;
        sumxy += (double)k * prices[k];
        sumy  += prices[k];
    }
    double denom = sumx*sumx - (double)period*sumxx;
    if(MathAbs(denom) < DBL_EPSILON) return false;

    double slope     = ((double)period*sumxy - sumx*sumy) / denom;
    double intercept = (sumy - slope*sumx) / period;
    double lineVal   = intercept; // regression value at k=0 (most recent closed bar)

    double ss = 0;
    for(int k=0; k<period; k++)
    {
        double res = prices[k] - (intercept + slope*k);
        ss += res*res;
    }
    double stdDev = MathSqrt(ss / period);
    if(stdDev < _Point) return false;

    lowerBand = lineVal - InpChannelSL_StdDevMul * stdDev;
    upperBand = lineVal + InpChannelSL_StdDevMul * stdDev;
    return true;
}

//+------------------------------------------------------------------+
//| Channel SL for broker: band + sforo buffer so wicks don't fire  |
//+------------------------------------------------------------------+
bool ComputeChannelBandSL(bool isBuy, double &slLevel)
{
    double lowerBand, upperBand;
    if(!ComputeChannelBands(lowerBand, upperBand)) return false;
    double sforoBuf = InpChannelSL_SforoBuf * _Point;
    slLevel = isBuy ? (lowerBand - sforoBuf) : (upperBand + sforoBuf);
    return true;
}

//+------------------------------------------------------------------+
//| Strategy: divergence → wait for alignment → decide via RSI slope|
//| Step 1: detect divergence (price and RSI opposite) on long window|
//| Step 2: wait for alignment (both same direction) on short window |
//| Step 3: RSI slope up → BUY, RSI slope down → SELL               |
//+------------------------------------------------------------------+
void EvaluateSlopeAlignmentCycle(bool &bullishEntry, bool &bearishEntry)
{
    bullishEntry = false;
    bearishEntry = false;

    // Step 1: detect divergence on stable long window
    bool bullish, bearish;
    double ps, rs;
    if(!EvaluateSlopeDivergence(bullish, bearish, ps, rs)) return;

    double rsi1 = GetRSI(1);
    if(bullish) {
        if(!g_saw_bullish_div)
            PrintFormat("[DIV] BULLISH | price slope: %+.6f (dn) | RSI slope: %+.6f (up) | RSI: %.1f | p=%d",
                        ps, rs, rsi1, GetSlopePeriod());
        g_saw_bullish_div = true;
        g_saw_bearish_div = false;
    }
    if(bearish) {
        if(!g_saw_bearish_div)
            PrintFormat("[DIV] BEARISH | price slope: %+.6f (up) | RSI slope: %+.6f (dn) | RSI: %.1f | p=%d",
                        ps, rs, rsi1, GetSlopePeriod());
        g_saw_bearish_div = true;
        g_saw_bullish_div = false;
    }

    if(!g_saw_bullish_div && !g_saw_bearish_div) return;

    // Step 2: wait for alignment on short responsive window
    int entryPeriod = (InpEntry_Lookback_Bars > 2) ? InpEntry_Lookback_Bars : GetSlopePeriod();
    bool dummy1, dummy2;
    double eps, ers;
    if(!EvaluateSlopeDivergence(dummy1, dummy2, eps, ers, entryPeriod)) return;

    if(InpVerboseEntryLogs)
        PrintFormat("[WAIT] div=%s | entry slope(p=%d): ps=%+.6f rs=%+.6f",
                    g_saw_bullish_div ? "bull" : "bear", entryPeriod, eps, ers);

    // Step 3: slopes aligned — decide by RSI slope direction
    if(g_saw_bullish_div && eps > 0.0 && ers > 0.0)
    {
        bullishEntry = true;
        g_saw_bullish_div = false;
        PrintFormat("[ALIGN] BUY | RSI slope up (%+.6f) | price slope (%+.6f) | RSI: %.1f",
                    ers, eps, rsi1);
    }
    else if(g_saw_bearish_div && eps < 0.0 && ers < 0.0)
    {
        bearishEntry = true;
        g_saw_bearish_div = false;
        PrintFormat("[ALIGN] SELL | RSI slope dn (%+.6f) | price slope (%+.6f) | RSI: %.1f",
                    ers, eps, rsi1);
    }
}

//+------------------------------------------------------------------+
//| Checks for new buy or sell entry signals                         |
//+------------------------------------------------------------------+
void CheckForEntrySignals()
{
    if(IsDailyLimitReached())
    {
        if(InpVerboseEntryLogs) Print("Entry blocked: daily limit reached.");
        return;
    }
    if(!IsWithinTradingHours())
    {
        if(InpVerboseEntryLogs) Print("Entry blocked: outside trading hours.");
        return;
    }
    if(IsNewsTimeRestricted())
    {
        if(InpVerboseEntryLogs) Print("Entry blocked: news filter window.");
        return;
    }

    // Block if a position is already open on this symbol
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(posInfo.SelectByIndex(i) &&
           posInfo.Symbol() == _Symbol &&
           posInfo.Magic()  == InpMagicNumber)
            return;
    }

    bool bullishSignal = false;
    bool bearishSignal = false;
    EvaluateSlopeAlignmentCycle(bullishSignal, bearishSignal);

    if(!bullishSignal && !bearishSignal) return;

    // --- Lot sizing ---
    double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
    if(lots <= 0) return;

    // --- Margin check ---
    double margin;
    double price       = 0;
    ENUM_ORDER_TYPE ot = WRONG_VALUE;

    if(bullishSignal) { price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); ot = ORDER_TYPE_BUY;  }
    else              { price = SymbolInfoDouble(_Symbol, SYMBOL_BID); ot = ORDER_TYPE_SELL; }

    if(!OrderCalcMargin(ot, _Symbol, lots, price, margin))
    {
        Print("Failed to calculate margin. Error: ", GetLastError());
        return;
    }
    if(margin > account.FreeMargin())
    {
        PrintFormat("Not enough margin. Required: %.2f, Available: %.2f",
                    margin, account.FreeMargin());
        return;
    }

    // --- Compute initial SL ---
    double bandSL = 0;
    bool   gotBand = InpUseChannelSL && ComputeChannelBandSL(bullishSignal, bandSL);

    // --- Place order ---
    if(bullishSignal)
    {
        double fixedSL = (InpStopLossPoints > 0) ? price - InpStopLossPoints * _Point : 0;
        double sl = gotBand ? MathMin(bandSL, fixedSL > 0 ? fixedSL : bandSL) : fixedSL;
        double tp = (InpTakeProfitPoints > 0) ? price + InpTakeProfitPoints * _Point : 0;
        double slPts = (sl > 0) ? (price - sl) / _Point : 0;
        PrintFormat("[ENTRY] BUY @ %.5f | lots: %.2f | SL: %.5f (%s, %.0f pts) | TP: %.5f",
                    price, lots, sl,
                    gotBand ? "channel" : "fixed", slPts,
                    tp);
        if(!trade.Buy(lots, _Symbol, price, sl, tp, "TRE_Buy_v25"))
            PrintFormat("[ENTRY] BUY failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    else
    {
        double fixedSL = (InpStopLossPoints > 0) ? price + InpStopLossPoints * _Point : 0;
        double sl = gotBand ? MathMax(bandSL, fixedSL > 0 ? fixedSL : bandSL) : fixedSL;
        double tp = (InpTakeProfitPoints > 0) ? price - InpTakeProfitPoints * _Point : 0;
        double slPts = (sl > 0) ? (sl - price) / _Point : 0;
        PrintFormat("[ENTRY] SELL @ %.5f | lots: %.2f | SL: %.5f (%s, %.0f pts) | TP: %.5f",
                    price, lots, sl,
                    gotBand ? "channel" : "fixed", slPts,
                    tp);
        if(!trade.Sell(lots, _Symbol, price, sl, tp, "TRE_Sell_v25"))
            PrintFormat("[ENTRY] SELL failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Linear regression slope on latest closed bars                    |
//+------------------------------------------------------------------+
double CalculateLinearRegressionSlope(const double &values[], const int period)
{
    if(period < 3) return 0.0;

    double sumx = 0, sumxx = 0, sumxy = 0, sumy = 0;
    for(int k = 0; k < period; k++)
    {
        sumx  += k;
        sumxx += (double)k * k;
        sumxy += (double)k * values[k];
        sumy  += values[k];
    }

    double denom = sumx * sumx - (double)period * sumxx;
    if(MathAbs(denom) < DBL_EPSILON) return 0.0;

    return ((double)period * sumxy - sumx * sumy) / denom;
}

//+------------------------------------------------------------------+
//| Slope divergence filter                                          |
//+------------------------------------------------------------------+
bool EvaluateSlopeDivergence(bool &bullish, bool &bearish, double &priceSlope, double &rsiSlope, int period = 0)
{
    bullish    = false;
    bearish    = false;
    priceSlope = 0.0;
    rsiSlope   = 0.0;

    if(period <= 0) period = GetSlopePeriod();
    double rsiValues[], closePrices[];

    if(CopyBuffer(rsi_handle, 0, 1, period, rsiValues) < period)  return false;
    if(CopyClose(_Symbol, _Period, 1, period, closePrices) < period) return false;

    rsiSlope   = CalculateLinearRegressionSlope(rsiValues,   period);
    priceSlope = CalculateLinearRegressionSlope(closePrices, period);

    // k=0 is most recent bar. Formula gives: price going DOWN = slope < 0, price going UP = slope > 0
    bullish = (priceSlope < 0.0 && rsiSlope > 0.0); // price down + RSI up = bullish div
    bearish = (priceSlope > 0.0 && rsiSlope < 0.0); // price up + RSI down = bearish div
    return true;
}

//+------------------------------------------------------------------+
//| Manages currently open trades: RSI exit + slope alignment exit   |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
    if(!posInfo.SelectByMagic(_Symbol, InpMagicNumber)) return;

    bool   isBuy      = (posInfo.PositionType() == POSITION_TYPE_BUY);
    double openPrice  = posInfo.PriceOpen();
    double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double profitPts  = isBuy ? (currentPrice - openPrice) / _Point
                              : (openPrice - currentPrice) / _Point;

    // --- RSI level exit ---
    if(InpUse_RSI_Level_Exit)
    {
        double rsi = GetRSI(1);
        if(isBuy && rsi >= InpRSI_Overbought)
        {
            PrintFormat("[EXIT] BUY closed -RSI overbought (%.1f >= %d) | profit: %+.0f pts | open: %.5f close: %.5f",
                        rsi, InpRSI_Overbought, profitPts, openPrice, currentPrice);
            trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit()); return;
        }
        if(!isBuy && rsi <= InpRSI_Oversold)
        {
            PrintFormat("[EXIT] SELL closed -RSI oversold (%.1f <= %d) | profit: %+.0f pts | open: %.5f close: %.5f",
                        rsi, InpRSI_Oversold, profitPts, openPrice, currentPrice);
            trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit()); return;
        }
    }

    // Exit only when BOTH price slope AND RSI slope reverse — gives trade breathing room.
    // Price-only wiggles that RSI doesn't confirm are ignored; SL is the backstop.
    if(InpUse_Slope_Alignment_Exit)
    {
        int exitPeriod = (InpEntry_Lookback_Bars > 2) ? InpEntry_Lookback_Bars : GetSlopePeriod();
        bool bullish, bearish;
        double ps, rs;
        if(!EvaluateSlopeDivergence(bullish, bearish, ps, rs, exitPeriod)) return;

        // RSI leads price: exit when RSI slope reverses, even if price hasn't turned yet.
        // Slope formula gives NEGATIVE values for downtrends (k=0 = most recent bar).
        // BUY: RSI going down (rs<0) means momentum fading — get out before price turns
        // SELL: RSI going up  (rs>0) means momentum fading — get out before price turns
        bool exitBuy  = isBuy  && rs < 0.0;
        bool exitSell = !isBuy && rs > 0.0;

        if(exitBuy || exitSell)
        {
            PrintFormat("[EXIT] %s closed -RSI slope reversed (rs=%+.6f ps=%+.6f p=%d) | profit: %+.0f pts | open: %.5f close: %.5f",
                        isBuy ? "BUY" : "SELL", rs, ps, exitPeriod, profitPts, openPrice, currentPrice);
            trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit());
            return;
        }
    }

    // Once per bar: exit if last closed bar's close breached the channel boundary
    if(InpUseChannelSL)
    {
        static datetime lastChannelExitBar = 0;
        datetime currentBar = iTime(_Symbol, _Period, 0);
        if(lastChannelExitBar != currentBar)
        {
            lastChannelExitBar = currentBar;
            double lowerBand, upperBand;
            if(ComputeChannelBands(lowerBand, upperBand))
            {
                double lastClose = iClose(_Symbol, _Period, 1);
                bool breachBuy  = isBuy  && lastClose < lowerBand;
                bool breachSell = !isBuy && lastClose > upperBand;
                if(breachBuy || breachSell)
                {
                    PrintFormat("[EXIT] %s closed -channel breach (close=%.5f %s band=%.5f) | profit: %+.0f pts | open: %.5f",
                                isBuy ? "BUY" : "SELL", lastClose,
                                isBuy ? "< lower" : "> upper",
                                isBuy ? lowerBand : upperBand,
                                profitPts, openPrice);
                    trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit());
                    return;
                }
            }
        }
    }

    // --- Channel SL trail: move SL to current band, only in favorable direction ---
    if(InpUseChannelSL)
    {
        double bandSL;
        if(ComputeChannelBandSL(isBuy, bandSL))
        {
            double currentSL = posInfo.StopLoss();
            bool improve = isBuy ? (bandSL > currentSL || currentSL == 0)
                                 : (bandSL < currentSL || currentSL == 0);
            if(improve)
            {
                trade.PositionModify(posInfo.Ticket(), bandSL, posInfo.TakeProfit());
                if(InpVerboseEntryLogs)
                    PrintFormat("Channel SL trailed to %.5f", bandSL);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| News filter                                                      |
//+------------------------------------------------------------------+
bool IsNewsTimeRestricted()
{
    if(!InpUseNewsFilter) return false;

    datetime now = TimeCurrent();
    MqlDateTime ts;
    TimeToStruct(now, ts);
    ts.hour = InpNewsTimeHour;
    ts.min  = InpNewsTimeMinute;
    ts.sec  = 0;
    datetime news_time = StructToTime(ts);

    datetime no_trade_start = (datetime)(news_time - (long)InpMinutesBeforeNews * 60);
    datetime no_trade_end   = (datetime)(news_time + (long)InpMinutesAfterNews  * 60);

    return (now >= no_trade_start && now < no_trade_end);
}

//+------------------------------------------------------------------+
//| Closes open position when entering the pre-news window           |
//+------------------------------------------------------------------+
void ManageNewsClose()
{
    if(!InpUseNewsFilter || !InpCloseBeforeNews) return;

    datetime now = TimeCurrent();
    MqlDateTime ts;
    TimeToStruct(now, ts);
    ts.hour = InpNewsTimeHour;
    ts.min  = InpNewsTimeMinute;
    ts.sec  = 0;
    datetime news_time    = StructToTime(ts);
    datetime pre_news_start = (datetime)(news_time - (long)InpMinutesBeforeNews * 60);

    if(now < pre_news_start || now >= news_time) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic() != InpMagicNumber) continue;
        Print("Pre-news window: closing position #", posInfo.Ticket());
        trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit());
    }
}

//+------------------------------------------------------------------+
//| Daily limits                                                     |
//+------------------------------------------------------------------+
bool IsDailyLimitReached()
{
    if(!EnableDailyLimits) return false;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    datetime day_start = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);

    if(g_last_limit_check_day != day_start)
    {
        g_last_limit_check_day = day_start;
        g_daily_limit_reached  = false;
    }
    if(g_daily_limit_reached) return true;

    double profit = 0;
    if(HistorySelect(day_start, TimeCurrent()))
    {
        int n = (int)HistoryDealsTotal();
        for(int i = 0; i < n; i++)
            if(deal.SelectByIndex(i) && deal.Magic() == InpMagicNumber)
                profit += deal.Profit() + deal.Commission() + deal.Swap();
    }
    if(posInfo.SelectByMagic(_Symbol, InpMagicNumber))
        profit += posInfo.Profit();

    if(profit >= DailyProfitTarget)
    {
        PrintFormat("Daily profit target %.2f reached. Stopping for today.", DailyProfitTarget);
        g_daily_limit_reached = true;
        return true;
    }
    if(profit <= -DailyLossLimit)
    {
        PrintFormat("Daily loss limit %.2f reached. Stopping for today.", DailyLossLimit);
        g_daily_limit_reached = true;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Trading hours filter                                             |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    if(!EnableTimeFilter) return true;

    MqlDateTime time;
    TimeToStruct(TimeCurrent(), time);
    int now_min = time.hour * 60 + time.min;

    string hours_string = "";
    switch(time.day_of_week)
    {
        case 0: hours_string = SundayHours;    break;
        case 1: hours_string = MondayHours;    break;
        case 2: hours_string = TuesdayHours;   break;
        case 3: hours_string = WednesdayHours; break;
        case 4: hours_string = ThursdayHours;  break;
        case 5: hours_string = FridayHours;    break;
        case 6: hours_string = SaturdayHours;  break;
    }

    string sessions[];
    int k = StringSplit(hours_string, ';', sessions);
    for(int i = 0; i < k; i++)
    {
        string times[];
        if(StringSplit(sessions[i], '-', times) == 2)
        {
            string sp[], ep[];
            if(StringSplit(times[0], ':', sp) == 2 && StringSplit(times[1], ':', ep) == 2)
            {
                int start = (int)(StringToInteger(sp[0]) * 60 + StringToInteger(sp[1]));
                int end   = (int)(StringToInteger(ep[0]) * 60 + StringToInteger(ep[1]));
                if(now_min >= start && now_min < end) return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Session end management                                           |
//+------------------------------------------------------------------+
void ManageSessionEnd()
{
    if(!CloseAtEndTime) return;

    static bool was_in_session = true;
    bool is_in_session = IsWithinTradingHours();

    if(was_in_session && !is_in_session)
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagicNumber)
            {
                Print("Session ended. Closing position #", posInfo.Ticket());
                trade.PositionClose(posInfo.Ticket()); LogTradePnl(GetLastDealProfit());
            }
        if(g_daily_pnl != 0.0)
            PrintFormat("[PNL] === DAILY SUMMARY %s: %+.2f %s ===",
                        TimeToString(TimeCurrent(), TIME_DATE), g_daily_pnl, AccountInfoString(ACCOUNT_CURRENCY));
        g_daily_pnl = 0.0;
    }
    was_in_session = is_in_session;
}

//+------------------------------------------------------------------+
//| Trailing Stop + Break-Even manager (runs every tick)             |
//| FIX v2.2: break-even step added before trailing stop             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!InpUseTrailingStop || InpTrailingStopTrigger <= 0 || InpTrailingStopStep <= 0) return;

    int bePoints = (InpBreakEvenTrigger > 0) ? InpBreakEvenTrigger : InpStopLossPoints;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic() != InpMagicNumber) continue;
        if(posInfo.Symbol() != _Symbol) continue;

        double open_price  = posInfo.PriceOpen();
        double current_sl  = posInfo.StopLoss();
        ulong  ticket      = posInfo.Ticket();

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            double bid          = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profit_pts   = (bid - open_price) / _Point;

            // Step 1 -Break-even
            if(InpUseBreakEven && profit_pts >= bePoints && current_sl < open_price)
            {
                double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - bid) / _Point;
                double be_sl  = open_price + (spread + 2) * _Point;
                if(be_sl > current_sl)
                {
                    trade.PositionModify(ticket, be_sl, posInfo.TakeProfit());
                    PrintFormat("Break-even set at %.5f (profit: %.1f pts)", be_sl, profit_pts);
                }
            }

            // Step 2 -Trailing stop
            if(profit_pts >= InpTrailingStopTrigger)
            {
                double new_sl = bid - InpTrailingStopStep * _Point;
                if((new_sl > current_sl || current_sl == 0) && new_sl > open_price)
                    trade.PositionModify(ticket, new_sl, posInfo.TakeProfit());
            }
        }
        else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
            double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profit_pts = (open_price - ask) / _Point;

            // Step 1 -Break-even
            if(InpUseBreakEven && profit_pts >= bePoints && current_sl > open_price)
            {
                double spread = (ask - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
                double be_sl  = open_price - (spread + 2) * _Point;
                if(be_sl < current_sl || current_sl == 0)
                {
                    trade.PositionModify(ticket, be_sl, posInfo.TakeProfit());
                    PrintFormat("Break-even set at %.5f (profit: %.1f pts)", be_sl, profit_pts);
                }
            }

            // Step 2 -Trailing stop
            if(profit_pts >= InpTrailingStopTrigger)
            {
                double new_sl = ask + InpTrailingStopStep * _Point;
                if((new_sl < current_sl || current_sl == 0) && new_sl < open_price)
                    trade.PositionModify(ticket, new_sl, posInfo.TakeProfit());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Checks if a position is open for this EA on this symbol          |
//+------------------------------------------------------------------+
bool IsPositionOpen()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagicNumber)
            return true;
    return false;
}

//+------------------------------------------------------------------+
//| Calculates lot size based on risk percentage and stop loss       |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double equity      = account.Equity();
    double risk_amount = equity * (InpRiskPercent / 100.0);

    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tick_size == 0) return 0.0;

    double value_per_point       = tick_value / tick_size;
    double sl_price              = InpStopLossPoints * _Point;
    if(sl_price <= 0) return 0.0;

    double sl_money_per_lot = sl_price * (value_per_point / _Point);
    if(sl_money_per_lot <= 0) return 0.0;

    return NormalizeVolume(risk_amount / sl_money_per_lot);
}

//+------------------------------------------------------------------+
//| Normalizes trade volume to broker's requirements                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
    double min_v = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_v = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(volume < min_v) volume = min_v;
    if(volume > max_v) volume = max_v;
    if(step > 0) volume = round(volume / step) * step;
    if(volume < min_v) volume = min_v;
    if(volume > max_v) volume = max_v;

    return volume;
}
