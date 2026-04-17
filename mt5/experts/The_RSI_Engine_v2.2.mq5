//+------------------------------------------------------------------+
//|                                           The_RSI_Engine.mq5    |
//|                                      Copyright 2025, SPLpulse   |
//|                                           https://splpulse.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, The RSI Engine MT5 EA by SPLpluse"
#property link      "https://splpulse.com"
#property version   "2.2" // v2.2: Classic swing divergence + OB/OS zone filter + break-even stop

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
input int    InpStopLossPoints     = 300;       // Stop Loss in points (REQUIRED for risk management)
input int    InpTakeProfitPoints   = 300;       // Take Profit in points
input ulong  InpMagicNumber        = 1901;      // Unique ID for EA's trades
input int    InpMaxSpreadPoints    = 30;        // Max allowed spread in points

//--- Trailing Stop Group
input group "Trailing Stop"
input bool   InpUseTrailingStop       = true;   // Enable Trailing Stop Loss?
input bool   InpUseBreakEven          = true;   // Move SL to break-even before trailing?
input int    InpBreakEvenTrigger      = 0;      // Profit (points) to trigger break-even (0 = same as SL)
input int    InpTrailingStopTrigger   = 3000;   // Profit (points) to trigger trailing stop
input int    InpTrailingStopStep      = 50;     // Trailing distance from price (in points)

//--- RSI Settings Group
input group "RSI Settings"
input int    InpRSI_Period         = 14;        // Period for the RSI indicator
input int    InpRSI_Overbought     = 70;        // Overbought level
input int    InpRSI_Oversold       = 30;        // Oversold level
input int    InpRSI_Centerline     = 50;        // Centerline level

//--- Strategy Signals & Exits Group
input group "Strategy Signals & Exits"
input bool   InpUse_Divergence_Signal            = true;  // Use RSI Divergence as a primary signal
input bool   InpUse_Classic_Divergence           = true;  // Use classic swing high/low divergence (v2.2)
input bool   InpUse_OverboughtOversold_Reversal  = true;  // Use Overbought/Oversold reversal as a primary signal
input bool   InpUse_Centerline_Confirmation      = true;  // Wait for RSI to cross 50 for entry confirmation
input bool   InpUse_RSI_Level_Exit               = false; // Exit trades when RSI reaches opposite extreme
input bool   InpUse_Slope_Alignment_Exit         = true;  // Exit when price slope aligns with RSI slope (divergence resolved)
input int    InpDivergence_Lookback_Bars         = 60;    // Bars to look back for classic swing divergence
input bool   InpRequire_Slope_Divergence         = false; // Require opposite price/RSI slopes for entries
input int    InpSlope_Lookback_Bars              = 50;    // Slope lookback bars (linear regression)
input bool   InpVerboseEntryLogs                 = true;  // Print detailed entry-block reasons

//--- Daily Limits Group
input group "Daily Limits (in Deposit Currency)"
input bool   EnableDailyLimits    = true;       // Enable daily profit/loss limits?
input double DailyProfitTarget    = 10000.0;    // Stop trading for the day if this profit is reached
input double DailyLossLimit       = 5000.0;     // Stop trading for the day if this loss is reached

//--- News Filter Group
input group "News Filter (Server Time)"
input bool   InpUseNewsFilter       = false;    // Enable News Filter?
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

//+------------------------------------------------------------------+
//| Returns the period used for slope-based divergence               |
//+------------------------------------------------------------------+
int GetSlopePeriod()
{
    if(InpSlope_Lookback_Bars > 2) return InpSlope_Lookback_Bars;
    if(InpDivergence_Lookback_Bars > 2) return InpDivergence_Lookback_Bars;
    return 3;
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
    PrintFormat("RSI Engine v2.2 initialized. BreakEven trigger: %d pts, Trailing trigger: %d pts",
                bePoints, InpTrailingStopTrigger);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(rsi_handle);
    Print("RSI Engine v2.2 deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (main logic)                                |
//+------------------------------------------------------------------+
void OnTick()
{
    // Tasks that run on EVERY tick
    ManageSessionEnd();
    ManageTrailingStop();

    // Tasks that run ONCE PER BAR
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if(lastBarTime == currentBarTime) return;
    lastBarTime = currentBarTime;

    if(IsPositionOpen())
    {
        ManageOpenTrades();
        return;
    }

    // Spread filter — only for new entries
    double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    if(spreadPoints > InpMaxSpreadPoints)
    {
        PrintFormat("Entry blocked: spread too high (%.1f > %d pts)", spreadPoints, InpMaxSpreadPoints);
        return;
    }

    CheckForEntrySignals();
}

//+------------------------------------------------------------------+
//| Classic swing divergence: compares price swing lows/highs vs RSI |
//| FIX v2.2: uses InpDivergence_Lookback_Bars correctly             |
//+------------------------------------------------------------------+
bool CheckClassicBullishDivergence()
{
    int lookback = InpDivergence_Lookback_Bars;
    if(lookback < 4) return false;

    // Find the two most recent swing lows in price within lookback
    int bar1 = iLowest(_Symbol, _Period, MODE_LOW, lookback, 1);
    if(bar1 <= 0) return false;

    int bar2 = iLowest(_Symbol, _Period, MODE_LOW, lookback, bar1 + 1);
    if(bar2 <= bar1) return false;

    double priceLow1 = iLow(_Symbol, _Period, bar1);
    double priceLow2 = iLow(_Symbol, _Period, bar2);

    double rsiLow1 = GetRSI(bar1);
    double rsiLow2 = GetRSI(bar2);
    if(rsiLow1 < 0 || rsiLow2 < 0) return false;

    // Classic bullish divergence: price lower low, RSI higher low, RSI in oversold zone
    bool priceMakesLowerLow = (priceLow1 < priceLow2);
    bool rsiMakesHigherLow  = (rsiLow1 > rsiLow2);
    bool rsiInOversold      = (rsiLow1 < InpRSI_Oversold);

    if(priceMakesLowerLow && rsiMakesHigherLow && rsiInOversold)
    {
        PrintFormat("Classic Bullish Divergence: price %.5f < %.5f, RSI %.2f > %.2f (oversold: %.2f)",
                    priceLow1, priceLow2, rsiLow1, rsiLow2, (double)InpRSI_Oversold);
        return true;
    }
    return false;
}

bool CheckClassicBearishDivergence()
{
    int lookback = InpDivergence_Lookback_Bars;
    if(lookback < 4) return false;

    // Find the two most recent swing highs in price within lookback
    int bar1 = iHighest(_Symbol, _Period, MODE_HIGH, lookback, 1);
    if(bar1 <= 0) return false;

    int bar2 = iHighest(_Symbol, _Period, MODE_HIGH, lookback, bar1 + 1);
    if(bar2 <= bar1) return false;

    double priceHigh1 = iHigh(_Symbol, _Period, bar1);
    double priceHigh2 = iHigh(_Symbol, _Period, bar2);

    double rsiHigh1 = GetRSI(bar1);
    double rsiHigh2 = GetRSI(bar2);
    if(rsiHigh1 < 0 || rsiHigh2 < 0) return false;

    // Classic bearish divergence: price higher high, RSI lower high, RSI in overbought zone
    bool priceMakesHigherHigh = (priceHigh1 > priceHigh2);
    bool rsiMakesLowerHigh    = (rsiHigh1 < rsiHigh2);
    bool rsiInOverbought      = (rsiHigh1 > InpRSI_Overbought);

    if(priceMakesHigherHigh && rsiMakesLowerHigh && rsiInOverbought)
    {
        PrintFormat("Classic Bearish Divergence: price %.5f > %.5f, RSI %.2f < %.2f (overbought: %.2f)",
                    priceHigh1, priceHigh2, rsiHigh1, rsiHigh2, (double)InpRSI_Overbought);
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Slope divergence: linear regression comparison                   |
//| FIX v2.2: OB/OS zone filter added                                |
//+------------------------------------------------------------------+
bool CheckBullishDivergence()
{
    double rsi1 = GetRSI(1);
    if(rsi1 < 0) return false;

    // OB/OS filter: only apply when user set a meaningful oversold level (> 0)
    if(InpRSI_Oversold > 0 && rsi1 >= InpRSI_Oversold)
    {
        if(InpVerboseEntryLogs)
            PrintFormat("Slope bullish blocked: RSI(1)=%.2f not in oversold zone (<%d)", rsi1, InpRSI_Oversold);
        return false;
    }

    bool bullish, bearish;
    double ps, rs;
    if(!EvaluateSlopeDivergence(bullish, bearish, ps, rs)) return false;

    if(bullish)
        PrintFormat("Slope Bullish Divergence: priceSlope=%.8f rsiSlope=%.8f RSI=%.2f", ps, rs, rsi1);

    return bullish;
}

bool CheckBearishDivergence()
{
    double rsi1 = GetRSI(1);
    if(rsi1 < 0) return false;

    // OB/OS filter: only apply when user set a meaningful overbought level (< 100)
    if(InpRSI_Overbought < 100 && rsi1 <= InpRSI_Overbought)
    {
        if(InpVerboseEntryLogs)
            PrintFormat("Slope bearish blocked: RSI(1)=%.2f not in overbought zone (>%d)", rsi1, InpRSI_Overbought);
        return false;
    }

    bool bullish, bearish;
    double ps, rs;
    if(!EvaluateSlopeDivergence(bullish, bearish, ps, rs)) return false;

    if(bearish)
        PrintFormat("Slope Bearish Divergence: priceSlope=%.8f rsiSlope=%.8f RSI=%.2f", ps, rs, rsi1);

    return bearish;
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

    bool bullishSignal = false;
    bool bearishSignal = false;

    // --- Divergence signals ---
    bool bullishDivergence = false;
    bool bearishDivergence = false;

    if(InpUse_Divergence_Signal)
    {
        if(InpUse_Classic_Divergence)
        {
            // FIX v2.2: classic swing divergence using InpDivergence_Lookback_Bars
            bullishDivergence = CheckClassicBullishDivergence();
            bearishDivergence = CheckClassicBearishDivergence();
        }
        else
        {
            // Legacy slope divergence (with OB/OS zone filter in v2.2)
            bullishDivergence = CheckBullishDivergence();
            bearishDivergence = CheckBearishDivergence();
        }
    }

    // --- OB/OS Reversal signals ---
    bool bullishReversal = InpUse_OverboughtOversold_Reversal
        ? (GetRSI(2) < InpRSI_Oversold && GetRSI(1) > InpRSI_Oversold)
        : false;
    bool bearishReversal = InpUse_OverboughtOversold_Reversal
        ? (GetRSI(2) > InpRSI_Overbought && GetRSI(1) < InpRSI_Overbought)
        : false;

    if(!bullishDivergence && !bearishDivergence && !bullishReversal && !bearishReversal)
    {
        if(InpVerboseEntryLogs)
            PrintFormat("No signal: RSI(2)=%.2f RSI(1)=%.2f", GetRSI(2), GetRSI(1));
        return;
    }

    // --- Centerline confirmation ---
    if(bullishDivergence || bullishReversal)
    {
        if(InpUse_Centerline_Confirmation)
        {
            if(GetRSI(2) < InpRSI_Centerline && GetRSI(1) > InpRSI_Centerline)
                bullishSignal = true;
            else if(InpVerboseEntryLogs)
                Print("Bullish blocked: centerline confirmation not met.");
        }
        else
            bullishSignal = true;
    }

    if(bearishDivergence || bearishReversal)
    {
        if(InpUse_Centerline_Confirmation)
        {
            if(GetRSI(2) > InpRSI_Centerline && GetRSI(1) < InpRSI_Centerline)
                bearishSignal = true;
            else if(InpVerboseEntryLogs)
                Print("Bearish blocked: centerline confirmation not met.");
        }
        else
            bearishSignal = true;
    }

    // --- Slope divergence filter (FIX v2.2: called once, not redundantly) ---
    if(InpRequire_Slope_Divergence && (bullishSignal || bearishSignal))
    {
        bool bullishSlope, bearishSlope;
        double ps, rs;
        if(!EvaluateSlopeDivergence(bullishSlope, bearishSlope, ps, rs))
        {
            Print("Entry blocked: unable to evaluate slope divergence.");
            return;
        }
        if(bullishSignal && !bullishSlope)
        {
            PrintFormat("Bullish blocked by slope filter: priceSlope=%.8f rsiSlope=%.8f", ps, rs);
            bullishSignal = false;
        }
        if(bearishSignal && !bearishSlope)
        {
            PrintFormat("Bearish blocked by slope filter: priceSlope=%.8f rsiSlope=%.8f", ps, rs);
            bearishSignal = false;
        }
    }

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

    // --- Place order ---
    if(bullishSignal)
    {
        double sl = (InpStopLossPoints  > 0) ? price - InpStopLossPoints  * _Point : 0;
        double tp = (InpTakeProfitPoints > 0) ? price + InpTakeProfitPoints * _Point : 0;
        if(!trade.Buy(lots, _Symbol, price, sl, tp, "TRE_Buy_v22"))
            PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    else
    {
        double sl = (InpStopLossPoints  > 0) ? price + InpStopLossPoints  * _Point : 0;
        double tp = (InpTakeProfitPoints > 0) ? price - InpTakeProfitPoints * _Point : 0;
        if(!trade.Sell(lots, _Symbol, price, sl, tp, "TRE_Sell_v22"))
            PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
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
bool EvaluateSlopeDivergence(bool &bullish, bool &bearish, double &priceSlope, double &rsiSlope)
{
    bullish    = false;
    bearish    = false;
    priceSlope = 0.0;
    rsiSlope   = 0.0;

    const int period = GetSlopePeriod();
    double rsiValues[], closePrices[];

    if(CopyBuffer(rsi_handle, 0, 1, period, rsiValues) < period)  return false;
    if(CopyClose(_Symbol, _Period, 1, period, closePrices) < period) return false;

    rsiSlope   = CalculateLinearRegressionSlope(rsiValues,   period);
    priceSlope = CalculateLinearRegressionSlope(closePrices, period);

    // k=0 is most recent bar: price going DOWN over time = slope > 0, RSI going UP = slope < 0
    bullish = (priceSlope > 0.0 && rsiSlope < 0.0); // price down + RSI up = bullish div
    bearish = (priceSlope < 0.0 && rsiSlope > 0.0); // price up + RSI down = bearish div
    return true;
}

//+------------------------------------------------------------------+
//| Manages currently open trades: RSI exit + slope alignment exit   |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
    if(!posInfo.SelectByMagic(_Symbol, InpMagicNumber)) return;

    // --- RSI level exit ---
    if(InpUse_RSI_Level_Exit)
    {
        double rsi = GetRSI(1);
        if(posInfo.PositionType() == POSITION_TYPE_BUY  && rsi >= InpRSI_Overbought)
        { trade.PositionClose(posInfo.Ticket()); return; }
        if(posInfo.PositionType() == POSITION_TYPE_SELL && rsi <= InpRSI_Oversold)
        { trade.PositionClose(posInfo.Ticket()); return; }
    }

    // --- Slope alignment exit ---
    // BUY entered on price bearish (priceSlope>0): exit when price slope turns bullish (priceSlope<0)
    // SELL entered on price bullish (priceSlope<0): exit when price slope turns bearish (priceSlope>0)
    if(InpUse_Slope_Alignment_Exit)
    {
        bool bullish, bearish;
        double ps, rs;
        if(!EvaluateSlopeDivergence(bullish, bearish, ps, rs)) return;

        bool isBuy  = (posInfo.PositionType() == POSITION_TYPE_BUY);
        bool isSell = (posInfo.PositionType() == POSITION_TYPE_SELL);

        // Profit exit: price inverted in expected direction
        bool profitExitBuy  = isBuy  && ps < 0.0; // price turned bullish after being bearish
        bool profitExitSell = isSell && ps > 0.0; // price turned bearish after being bullish

        // Signal failed: both slopes aligned AGAINST the trade
        bool failedBuy  = isBuy  && ps > 0.0 && rs > 0.0; // both bearish = BUY signal failed
        bool failedSell = isSell && ps < 0.0 && rs < 0.0; // both bullish = SELL signal failed

        if(profitExitBuy || profitExitSell || failedBuy || failedSell)
        {
            string reason = (profitExitBuy || profitExitSell) ? "profit" : "signal failed";
            PrintFormat("Slope exit (%s): priceSlope=%.8f rsiSlope=%.8f", reason, ps, rs);
            trade.PositionClose(posInfo.Ticket());
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
                trade.PositionClose(posInfo.Ticket());
            }
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

            // Step 1 — Break-even
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

            // Step 2 — Trailing stop
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

            // Step 1 — Break-even
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

            // Step 2 — Trailing stop
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
//+------------------------------------------------------------------+
