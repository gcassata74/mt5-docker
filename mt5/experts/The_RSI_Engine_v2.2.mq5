//+------------------------------------------------------------------+
//|                                       The_RSI_Engine_v2.2.mq5   |
//|                                      Copyright 2025, SPLpulse   |
//|                                           https://splpulse.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, The RSI Engine MT5 EA by SPLpluse"
#property link      "https://splpulse.com"
#property version   "2.2"
// v2.2 strategy: RSI(2) fast scalping — many small trades
//   Entry: RSI(2) crosses back from extreme zone (< 10 oversold → BUY, > 90 overbought → SELL)
//   Filter: optional EMA200 trend filter (only buy above EMA, only sell below EMA)
//   Exit:   fixed tight TP (15 pips), fixed SL (20 pips) — no trailing (targets too tight)

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>

//--- Trade Management
input group "Trade Management"
input bool   InpUseRiskManagement = false;  // Use dynamic lot sizing based on risk %?
input double InpRiskPercent       = 1.0;    // Risk % of equity per trade (if enabled)
input double InpLots              = 0.1;    // Fixed lot size
input int    InpStopLossPoints    = 200;    // Stop Loss in points (20 pips)
input int    InpTakeProfitPoints  = 150;    // Take Profit in points (15 pips)
input bool   InpUseTrailing       = true;   // Enable trailing stop?
input int    InpTrailingTrigger   = 100;    // Profit in points before trailing activates (10 pips)
input int    InpTrailingStep      = 80;     // Trailing distance from price in points (8 pips)
input ulong  InpMagicNumber       = 2200;   // Unique EA ID
input int    InpMaxSpreadPoints   = 10;     // Max spread allowed for entry (tight for scalping)

//--- RSI Settings
input group "RSI Settings"
input int    InpRSI_Period      = 2;   // RSI period (2 = ultra-fast, many signals)
input int    InpRSI_Overbought  = 90;  // Overbought level
input int    InpRSI_Oversold    = 10;  // Oversold level

//--- Strategy Filters
input group "Strategy Filters"
input bool   InpUseEMAFilter   = true;   // Only buy above EMA, only sell below EMA?
input int    InpEMA_Period     = 200;    // EMA period for trend filter
input bool   InpUseADXFilter      = true;   // Use ADX to switch between mean-reversion and hidden-divergence?
input int    InpADX_Period        = 14;     // ADX period
input double InpADX_Threshold     = 30.0;  // ADX above this = trending regime (hidden divergence mode)
input bool   InpUseCorrelFilter   = true;   // Block new trades if already long/short USD in another pair?
input int    InpMaxUSDSameDir     = 1;      // Max open positions in the same USD direction across all pairs
input bool   InpVerboseLogs       = true;   // Print detailed logs

//--- Hidden Divergence Settings (Trending Regime)
input group "Hidden Divergence Settings (ADX Trending Mode)"
input int    InpDivLookback     = 20;   // Bars to look back for swing reference
input int    InpDivRSI_Pullback = 40;   // RSI must be below this to confirm pullback in uptrend
input int    InpDivRSI_Rally    = 60;   // RSI must be above this to confirm rally in downtrend

//--- Daily Limits
input group "Daily Limits (deposit currency)"
input bool   EnableDailyLimits  = true;    // Enable daily profit/loss limits?
input double DailyProfitTarget  = 300.0;   // Stop trading when daily profit reaches this
input double DailyLossLimit     = 150.0;   // Stop trading when daily loss reaches this

//--- News Filter
input group "News Filter (Server Time)"
input bool   InpUseNewsFilter      = false;  // Enable news filter?
input bool   InpCloseBeforeNews    = true;   // Close position before news window?
input int    InpNewsTimeHour       = 15;     // News hour
input int    InpNewsTimeMinute     = 30;     // News minute
input int    InpMinutesBeforeNews  = 30;     // Minutes before news to stop trading
input int    InpMinutesAfterNews   = 30;     // Minutes after news to resume

//--- Trading Hours
input group "Trading Hours (Server Time)"
input bool   EnableTimeFilter  = true;                       // Enable time filter?
input string MondayHours       = "09:00-12:00;14:00-21:00";
input string TuesdayHours      = "09:00-12:00;14:00-21:00";
input string WednesdayHours    = "09:00-12:00;14:00-21:00";
input string ThursdayHours     = "09:00-12:00;14:00-21:00";
input string FridayHours       = "09:00-12:00;14:00-20:00";
input string SaturdayHours     = "00:00-00:00";
input string SundayHours       = "00:00-00:00";
input bool   CloseAtEndTime    = true;  // Close positions when session ends?

//--- Globals
CTrade        trade;
CPositionInfo posInfo;
CAccountInfo  account;
CDealInfo     deal;

int      rsi_handle;
int      ema_handle;
int      adx_handle;
bool     g_daily_limit_reached  = false;
datetime g_last_limit_check_day = 0;
bool     g_was_in_position      = false;
double   g_daily_pnl            = 0.0;
datetime g_daily_pnl_day        = 0;
int      g_last_regime          = -1;  // 0=ranging, 1=trending (for regime-change logging)

//+------------------------------------------------------------------+
double GetRSI(int shift)
{
    double buf[1];
    if(CopyBuffer(rsi_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

double GetEMA(int shift)
{
    double buf[1];
    if(CopyBuffer(ema_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

double GetADX(int shift)
{
    double buf[1];
    if(CopyBuffer(adx_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

// Returns USD direction of a trade: +1 = long USD, -1 = short USD, 0 = no USD leg
int USDDirection(string sym, ENUM_POSITION_TYPE posType)
{
    bool isUSDBase  = (StringSubstr(sym, 0, 3) == "USD");
    bool isUSDQuote = (StringSubstr(sym, 3, 3) == "USD");
    if(!isUSDBase && !isUSDQuote) return 0;

    // BUY on USD-base pair = long USD; BUY on USD-quote pair = short USD
    if(isUSDBase)  return (posType == POSITION_TYPE_BUY)  ?  1 : -1;
    if(isUSDQuote) return (posType == POSITION_TYPE_BUY)  ? -1 :  1;
    return 0;
}

// Counts open positions across ALL pairs with our magic number range that share the same USD direction
bool IsUSDCorrelated(int newUSDDir)
{
    if(!InpUseCorrelFilter || newUSDDir == 0) return false;

    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        ulong magic = posInfo.Magic();
        if(magic < 220001 || magic > 220020) continue;  // our EA range
        int dir = USDDirection(posInfo.Symbol(), posInfo.PositionType());
        if(dir == newUSDDir) count++;
    }
    if(count >= InpMaxUSDSameDir)
    {
        if(InpVerboseLogs)
            PrintFormat("Entry blocked: USD correlation filter (%d positions already %s USD)",
                        count, newUSDDir > 0 ? "long" : "short");
        return true;
    }
    return false;
}

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

double GetLastDealProfit()
{
    if(!HistorySelect(TimeCurrent() - 86400, TimeCurrent())) return 0.0;
    for(int i = (int)HistoryDealsTotal() - 1; i >= 0; i--)
    {
        if(!deal.SelectByIndex(i)) continue;
        if(deal.Magic()  != InpMagicNumber) continue;
        if(deal.Symbol() != _Symbol)        continue;
        if(deal.Entry()  != DEAL_ENTRY_OUT) continue;
        return deal.Profit() + deal.Commission() + deal.Swap();
    }
    return 0.0;
}

//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFillingBySymbol(_Symbol);

    rsi_handle = iRSI(_Symbol, _Period, InpRSI_Period, PRICE_CLOSE);
    if(rsi_handle == INVALID_HANDLE) { Print("RSI handle failed"); return INIT_FAILED; }

    ema_handle = iMA(_Symbol, _Period, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(ema_handle == INVALID_HANDLE) { Print("EMA handle failed"); return INIT_FAILED; }

    adx_handle = iADX(_Symbol, _Period, InpADX_Period);
    if(adx_handle == INVALID_HANDLE) { Print("ADX handle failed"); return INIT_FAILED; }

    PrintFormat("RSI Engine v2.2 initialized | RSI(%d) OB=%d OS=%d | EMA(%d) filter=%s | ADX(%d) regime=%s (threshold=%.0f) | DivLookback=%d | SL=%d TP=%d pts",
                InpRSI_Period, InpRSI_Overbought, InpRSI_Oversold,
                InpEMA_Period, InpUseEMAFilter ? "ON" : "OFF",
                InpADX_Period, InpUseADXFilter ? "ON" : "OFF", InpADX_Threshold,
                InpDivLookback, InpStopLossPoints, InpTakeProfitPoints);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(rsi_handle);
    IndicatorRelease(ema_handle);
    IndicatorRelease(adx_handle);
    Print("RSI Engine v2.2 deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
    ManageSessionEnd();
    ManageNewsClose();
    ManageTrailingStop();

    bool now_in_position = IsPositionOpen();

    // Detect external close (SL, TP, manual)
    if(g_was_in_position && !now_in_position)
    {
        if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))
        {
            for(int i = (int)HistoryDealsTotal() - 1; i >= 0; i--)
            {
                if(!deal.SelectByIndex(i)) continue;
                if(deal.Magic() != InpMagicNumber) continue;
                if(deal.Symbol() != _Symbol)       continue;
                if(deal.Entry()  != DEAL_ENTRY_OUT) continue;
                long   reason     = HistoryDealGetInteger(deal.Ticket(), DEAL_REASON);
                string closeDesc  = (reason == DEAL_REASON_SL) ? "STOP LOSS" :
                                    (reason == DEAL_REASON_TP) ? "TAKE PROFIT" : "closed externally";
                double extProfit  = deal.Profit() + deal.Commission() + deal.Swap();
                PrintFormat("[EXIT] %s | %s | profit: %+.2f %s | price: %.5f",
                            deal.Type() == DEAL_TYPE_SELL ? "BUY closed" : "SELL closed",
                            closeDesc, extProfit, AccountInfoString(ACCOUNT_CURRENCY), deal.Price());
                LogTradePnl(extProfit);
                break;
            }
        }
    }
    g_was_in_position = now_in_position;

    // Once per bar
    static datetime lastBar = 0;
    datetime curBar = iTime(_Symbol, _Period, 0);
    if(lastBar == curBar) return;
    lastBar = curBar;

    if(IsPositionOpen()) return;

    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    if(spread > InpMaxSpreadPoints)
    {
        if(InpVerboseLogs) PrintFormat("Entry blocked: spread %.1f > %d pts", spread, InpMaxSpreadPoints);
        return;
    }

    // Route to strategy based on market regime
    if(InpUseADXFilter)
    {
        double adx = GetADX(1);
        if(adx < 0) return;
        int regime = (adx >= InpADX_Threshold) ? 1 : 0;
        if(regime != g_last_regime)
        {
            if(regime == 1)
                PrintFormat("[REGIME] Switched to TRENDING (ADX=%.1f >= %.0f) — hidden divergence mode", adx, InpADX_Threshold);
            else
                PrintFormat("[REGIME] Switched to RANGING (ADX=%.1f < %.0f) — mean reversion mode", adx, InpADX_Threshold);
            g_last_regime = regime;
        }
        if(regime == 1)
            CheckForHiddenDivergence();
        else
            CheckForEntrySignals();
    }
    else
        CheckForEntrySignals();
}

//+------------------------------------------------------------------+
// v2.2 Entry: RSI crosses back from OB/OS zone
//   BUY:  previous bar RSI was below InpRSI_Oversold, current bar RSI crossed back above it
//   SELL: previous bar RSI was above InpRSI_Overbought, current bar RSI crossed back below it
//+------------------------------------------------------------------+
void CheckForEntrySignals()
{
    if(IsDailyLimitReached())
    {
        if(InpVerboseLogs) Print("Entry blocked: daily limit reached.");
        return;
    }
    if(!IsWithinTradingHours())
    {
        if(InpVerboseLogs) Print("Entry blocked: outside trading hours.");
        return;
    }
    if(IsNewsTimeRestricted())
    {
        if(InpVerboseLogs) Print("Entry blocked: news filter.");
        return;
    }

    double rsi1 = GetRSI(1); // last closed bar
    double rsi2 = GetRSI(2); // bar before that
    if(rsi1 < 0 || rsi2 < 0) return;

    // RSI crosses back from oversold → BUY
    bool buySignal  = (rsi2 < InpRSI_Oversold  && rsi1 >= InpRSI_Oversold);
    // RSI crosses back from overbought → SELL
    bool sellSignal = (rsi2 > InpRSI_Overbought && rsi1 <= InpRSI_Overbought);

    if(!buySignal && !sellSignal) return;

    // EMA trend filter
    if(InpUseEMAFilter)
    {
        double ema = GetEMA(1);
        double price = iClose(_Symbol, _Period, 1);
        if(ema < 0) return;

        if(buySignal  && price < ema)
        {
            if(InpVerboseLogs) PrintFormat("Entry blocked: BUY signal but price (%.5f) below EMA (%.5f)", price, ema);
            buySignal = false;
        }
        if(sellSignal && price > ema)
        {
            if(InpVerboseLogs) PrintFormat("Entry blocked: SELL signal but price (%.5f) above EMA (%.5f)", price, ema);
            sellSignal = false;
        }
        if(!buySignal && !sellSignal) return;
    }

    // USD correlation filter
    int usdDir = buySignal ? USDDirection(_Symbol, POSITION_TYPE_BUY)
                           : USDDirection(_Symbol, POSITION_TYPE_SELL);
    if(IsUSDCorrelated(usdDir)) return;

    double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
    if(lots <= 0) return;

    if(buySignal)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double sl  = (InpStopLossPoints   > 0) ? ask - InpStopLossPoints   * _Point : 0;
        double tp  = (InpTakeProfitPoints > 0) ? ask + InpTakeProfitPoints * _Point : 0;
        PrintFormat("[ENTRY] BUY @ %.5f | RSI: %.1f→%.1f | SL: %.5f | TP: %.5f | lots: %.2f",
                    ask, rsi2, rsi1, sl, tp, lots);
        if(!trade.Buy(lots, _Symbol, ask, sl, tp, "TRE_v22_Buy"))
            PrintFormat("[ENTRY] BUY failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    else
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double sl  = (InpStopLossPoints   > 0) ? bid + InpStopLossPoints   * _Point : 0;
        double tp  = (InpTakeProfitPoints > 0) ? bid - InpTakeProfitPoints * _Point : 0;
        PrintFormat("[ENTRY] SELL @ %.5f | RSI: %.1f→%.1f | SL: %.5f | TP: %.5f | lots: %.2f",
                    bid, rsi2, rsi1, sl, tp, lots);
        if(!trade.Sell(lots, _Symbol, bid, sl, tp, "TRE_v22_Sell"))
            PrintFormat("[ENTRY] SELL failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
// Hidden divergence entry (trending regime — ADX >= threshold)
//   Hidden bullish: uptrend + price higher low + RSI lower low → BUY (trend resumes after pullback)
//   Hidden bearish: downtrend + price lower high + RSI higher high → SELL (trend resumes after rally)
//+------------------------------------------------------------------+
void CheckForHiddenDivergence()
{
    if(IsDailyLimitReached())    { if(InpVerboseLogs) Print("Entry blocked: daily limit reached."); return; }
    if(!IsWithinTradingHours())  { if(InpVerboseLogs) Print("Entry blocked: outside trading hours."); return; }
    if(IsNewsTimeRestricted())   { if(InpVerboseLogs) Print("Entry blocked: news filter."); return; }

    double ema    = GetEMA(1);       if(ema < 0) return;
    double price1 = iClose(_Symbol, _Period, 1);
    double rsi1   = GetRSI(1);       if(rsi1 < 0) return;

    bool uptrend   = (price1 > ema);
    bool downtrend = (price1 < ema);
    if(!uptrend && !downtrend) return;

    // Find the reference swing bar in the lookback window
    int    refBar   = -1;
    double refClose = 0, refRSI = 0;

    if(uptrend && rsi1 < InpDivRSI_Pullback)
    {
        // Find bar with lowest close in [2..InpDivLookback]
        double minClose = DBL_MAX;
        for(int i = 2; i <= InpDivLookback; i++)
        {
            double c = iClose(_Symbol, _Period, i);
            if(c < minClose) { minClose = c; refBar = i; }
        }
        if(refBar < 0) return;
        refClose = iClose(_Symbol, _Period, refBar);
        refRSI   = GetRSI(refBar);  if(refRSI < 0) return;

        // Hidden bullish: price1 > refClose (higher low) AND rsi1 < refRSI (lower RSI)
        if(price1 > refClose && rsi1 < refRSI)
        {
            if(IsUSDCorrelated(USDDirection(_Symbol, POSITION_TYPE_BUY))) return;
            double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
            if(lots <= 0) return;
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl  = ask - InpStopLossPoints  * _Point;
            double tp  = ask + InpTakeProfitPoints * _Point;
            PrintFormat("[DIV] HIDDEN BULL BUY @ %.5f | RSI: %.1f < ref %.1f (bar %d) | price: %.5f > ref %.5f | SL: %.5f | TP: %.5f",
                        ask, rsi1, refRSI, refBar, price1, refClose, sl, tp);
            if(!trade.Buy(lots, _Symbol, ask, sl, tp, "TRE_v22_DivBuy"))
                PrintFormat("[DIV] BUY failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        else if(InpVerboseLogs)
            PrintFormat("[DIV] No hidden bull | RSI: %.1f ref: %.1f | price: %.5f ref: %.5f", rsi1, refRSI, price1, refClose);
    }
    else if(downtrend && rsi1 > InpDivRSI_Rally)
    {
        // Find bar with highest close in [2..InpDivLookback]
        double maxClose = -DBL_MAX;
        for(int i = 2; i <= InpDivLookback; i++)
        {
            double c = iClose(_Symbol, _Period, i);
            if(c > maxClose) { maxClose = c; refBar = i; }
        }
        if(refBar < 0) return;
        refClose = iClose(_Symbol, _Period, refBar);
        refRSI   = GetRSI(refBar);  if(refRSI < 0) return;

        // Hidden bearish: price1 < refClose (lower high) AND rsi1 > refRSI (higher RSI)
        if(price1 < refClose && rsi1 > refRSI)
        {
            if(IsUSDCorrelated(USDDirection(_Symbol, POSITION_TYPE_SELL))) return;
            double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
            if(lots <= 0) return;
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl  = bid + InpStopLossPoints  * _Point;
            double tp  = bid - InpTakeProfitPoints * _Point;
            PrintFormat("[DIV] HIDDEN BEAR SELL @ %.5f | RSI: %.1f > ref %.1f (bar %d) | price: %.5f < ref %.5f | SL: %.5f | TP: %.5f",
                        bid, rsi1, refRSI, refBar, price1, refClose, sl, tp);
            if(!trade.Sell(lots, _Symbol, bid, sl, tp, "TRE_v22_DivSell"))
                PrintFormat("[DIV] SELL failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        else if(InpVerboseLogs)
            PrintFormat("[DIV] No hidden bear | RSI: %.1f ref: %.1f | price: %.5f ref: %.5f", rsi1, refRSI, price1, refClose);
    }
}

//+------------------------------------------------------------------+
bool IsPositionOpen()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
            return true;
    return false;
}

//+------------------------------------------------------------------+
// Trailing stop: activates once profit >= InpTrailingTrigger points,
// then keeps SL at InpTrailingStep points behind price.
// Moves SL only forward (never back), locking in profit progressively.
void ManageTrailingStop()
{
    if(!InpUseTrailing) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic()  != InpMagicNumber) continue;
        if(posInfo.Symbol() != _Symbol)        continue;

        double open  = posInfo.PriceOpen();
        double sl    = posInfo.StopLoss();
        double tp    = posInfo.TakeProfit();
        double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double trigger = InpTrailingTrigger * _Point;
        double step    = InpTrailingStep    * _Point;

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            double profit = bid - open;
            if(profit < trigger) continue;          // not enough profit yet
            double newSL = bid - step;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL <= sl) continue;               // only move SL forward
            if(trade.PositionModify(posInfo.Ticket(), newSL, tp))
            {
                if(InpVerboseLogs)
                    PrintFormat("[TRAIL] BUY SL moved to %.5f (bid=%.5f profit=%.1f pts)",
                                newSL, bid, profit / _Point);
            }
        }
        else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
            double profit = open - ask;
            if(profit < trigger) continue;
            double newSL = ask + step;
            newSL = NormalizeDouble(newSL, _Digits);
            if(sl > 0 && newSL >= sl) continue;    // only move SL forward
            if(trade.PositionModify(posInfo.Ticket(), newSL, tp))
            {
                if(InpVerboseLogs)
                    PrintFormat("[TRAIL] SELL SL moved to %.5f (ask=%.5f profit=%.1f pts)",
                                newSL, ask, profit / _Point);
            }
        }
    }
}

//+------------------------------------------------------------------+
bool IsDailyLimitReached()
{
    if(!EnableDailyLimits) return false;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    datetime dayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);

    if(g_last_limit_check_day != dayStart)
    {
        g_last_limit_check_day = dayStart;
        g_daily_limit_reached  = false;
    }
    if(g_daily_limit_reached) return true;

    double profit = 0;
    if(HistorySelect(dayStart, TimeCurrent()))
        for(int i = 0; i < (int)HistoryDealsTotal(); i++)
            if(deal.SelectByIndex(i) && deal.Magic() == InpMagicNumber)
                profit += deal.Profit() + deal.Commission() + deal.Swap();

    if(posInfo.SelectByMagic(_Symbol, InpMagicNumber))
        profit += posInfo.Profit();

    if(profit >= DailyProfitTarget)
    {
        PrintFormat("[LIMIT] Daily profit target %.2f reached. Stopping.", DailyProfitTarget);
        g_daily_limit_reached = true; return true;
    }
    if(profit <= -DailyLossLimit)
    {
        PrintFormat("[LIMIT] Daily loss limit %.2f reached. Stopping.", DailyLossLimit);
        g_daily_limit_reached = true; return true;
    }
    return false;
}

//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    if(!EnableTimeFilter) return true;

    MqlDateTime t;
    TimeToStruct(TimeCurrent(), t);
    int nowMin = t.hour * 60 + t.min;

    string hours = "";
    switch(t.day_of_week)
    {
        case 0: hours = SundayHours;    break;
        case 1: hours = MondayHours;    break;
        case 2: hours = TuesdayHours;   break;
        case 3: hours = WednesdayHours; break;
        case 4: hours = ThursdayHours;  break;
        case 5: hours = FridayHours;    break;
        case 6: hours = SaturdayHours;  break;
    }

    string sessions[];
    int n = StringSplit(hours, ';', sessions);
    for(int i = 0; i < n; i++)
    {
        string times[];
        if(StringSplit(sessions[i], '-', times) != 2) continue;
        string sp[], ep[];
        if(StringSplit(times[0], ':', sp) != 2) continue;
        if(StringSplit(times[1], ':', ep) != 2) continue;
        int start = (int)(StringToInteger(sp[0]) * 60 + StringToInteger(sp[1]));
        int end   = (int)(StringToInteger(ep[0]) * 60 + StringToInteger(ep[1]));
        if(nowMin >= start && nowMin < end) return true;
    }
    return false;
}

//+------------------------------------------------------------------+
void ManageSessionEnd()
{
    if(!CloseAtEndTime) return;

    static bool wasInSession = true;
    bool isInSession = IsWithinTradingHours();

    if(wasInSession && !isInSession)
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagicNumber)
            {
                Print("Session ended. Closing position #", posInfo.Ticket());
                trade.PositionClose(posInfo.Ticket());
                LogTradePnl(GetLastDealProfit());
            }
        if(g_daily_pnl != 0.0)
            PrintFormat("[PNL] === DAILY SUMMARY %s: %+.2f %s ===",
                        TimeToString(TimeCurrent(), TIME_DATE), g_daily_pnl,
                        AccountInfoString(ACCOUNT_CURRENCY));
        g_daily_pnl = 0.0;
    }
    wasInSession = isInSession;
}

//+------------------------------------------------------------------+
bool IsNewsTimeRestricted()
{
    if(!InpUseNewsFilter) return false;

    datetime now = TimeCurrent();
    MqlDateTime ts;
    TimeToStruct(now, ts);
    ts.hour = InpNewsTimeHour; ts.min = InpNewsTimeMinute; ts.sec = 0;
    datetime newsTime = StructToTime(ts);
    datetime noStart  = (datetime)(newsTime - (long)InpMinutesBeforeNews * 60);
    datetime noEnd    = (datetime)(newsTime + (long)InpMinutesAfterNews  * 60);
    return (now >= noStart && now < noEnd);
}

void ManageNewsClose()
{
    if(!InpUseNewsFilter || !InpCloseBeforeNews) return;

    datetime now = TimeCurrent();
    MqlDateTime ts;
    TimeToStruct(now, ts);
    ts.hour = InpNewsTimeHour; ts.min = InpNewsTimeMinute; ts.sec = 0;
    datetime newsTime  = StructToTime(ts);
    datetime preStart  = (datetime)(newsTime - (long)InpMinutesBeforeNews * 60);

    if(now < preStart || now >= newsTime) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == InpMagicNumber)
        {
            Print("Pre-news: closing position #", posInfo.Ticket());
            trade.PositionClose(posInfo.Ticket());
            LogTradePnl(GetLastDealProfit());
        }
}

//+------------------------------------------------------------------+
double CalculateLotSize()
{
    if(InpStopLossPoints <= 0) return 0;
    double equity    = account.Equity();
    double riskAmt   = equity * (InpRiskPercent / 100.0);
    double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize == 0) return 0;
    double valPerPt  = tickVal / tickSize;
    double slMoney   = InpStopLossPoints * _Point * (valPerPt / _Point);
    if(slMoney <= 0) return 0;
    return NormalizeVolume(riskAmt / slMoney);
}

double NormalizeVolume(double vol)
{
    double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(vol < minV) vol = minV;
    if(vol > maxV) vol = maxV;
    if(step > 0)   vol = MathRound(vol / step) * step;
    if(vol < minV) vol = minV;
    if(vol > maxV) vol = maxV;
    return vol;
}
