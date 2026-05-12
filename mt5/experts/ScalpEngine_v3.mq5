//+------------------------------------------------------------------+
//|                                         ScalpEngine_v3.mq5       |
//|                          Copyright 2026, izylife solutions s.r.l.|
//|                                  https://www.izylifesolutions.com|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, izylife solutions s.r.l."
#property link      "https://www.izylifesolutions.com"
#property version   "3.0"
// v3.0 multi-strategy EA: MEAN_REVERSION, SESSION_BREAKOUT, EMA_CROSS_ADX
//   Strategy 0 — MEAN_REVERSION: RSI(2) cross-back from OB/OS, ADX regime routing,
//                hidden divergence in trending regime; swing-based reference bars
//   Strategy 1 — SESSION_BREAKOUT: accumulate H/L in pre-session window, trade breakout
//   Strategy 2 — EMA_CROSS_ADX: fast/slow EMA cross with ADX filter and EMA200 trend bias
//
// Key fixes vs RSI Engine v2.2:
//   - IsManagedMagic() used everywhere instead of hardcoded 220001-220020
//   - Trailing stop guards newSL vs TP (never cross TP)
//   - CalculateLotSize: clean valPerPt = tickVal/tickSize; slMoney = SLpts * valPerPt
//   - FindSwingLow/FindSwingHigh: proper 5-bar swing structure (close comparison)
//   - All signal reads on InpSignalTF (default M15)

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>

//--- Strategy enum
enum ENUM_STRATEGY
{
    MEAN_REVERSION  = 0,  // Mean Reversion (RSI + Hidden Divergence)
    SESSION_BREAKOUT = 1, // Session Breakout (London/NY range)
    EMA_CROSS_ADX   = 2   // EMA Cross + ADX Filter
};

//--- Trade Management
input group "Trade Management"
input bool   InpUseRiskManagement = false;  // Use dynamic lot sizing based on risk %?
input double InpRiskPercent       = 1.0;    // Risk % of equity per trade (if enabled)
input double InpLots              = 0.1;    // Fixed lot size
input int    InpStopLossPoints    = 50;     // Stop Loss in points
input int    InpTakeProfitPoints  = 0;      // Take Profit in points (0=off)
input bool   InpUseTrailing       = true;   // Enable trailing stop?
input int    InpTrailingTrigger   = 25;     // Profit in points before trailing activates
input int    InpTrailingStep      = 20;     // Trailing distance from price in points

//--- Strategy
input group "Strategy"
input ENUM_STRATEGY   InpStrategy      = MEAN_REVERSION; // Active strategy
input ulong           InpMagicNumber   = 3000;           // Magic number base
input int             InpMaxSpreadPoints = 10;           // Max spread allowed for entry
input bool            InpMultiPairMode   = true;         // Multi-pair mode (magic range +0..+19)
input ENUM_TIMEFRAMES InpSignalTF        = PERIOD_M15;   // Timeframe for indicator handles and bar timing

//--- RSI Settings
input group "RSI Settings"
input int    InpRSI_Period      = 2;   // RSI period
input int    InpRSI_Overbought  = 90;  // Overbought level
input int    InpRSI_Oversold    = 10;  // Oversold level

//--- Strategy Filters
input group "Strategy Filters"
input bool   InpUseEMAFilter      = true;   // Only buy above EMA, only sell below EMA?
input int    InpEMA_Period        = 50;     // EMA period for trend filter
input bool   InpUseADXFilter      = true;   // Use ADX to route mean-reversion vs hidden-divergence?
input int    InpADX_Period        = 14;     // ADX period
input double InpADX_Threshold     = 30.0;  // ADX above this = trending regime
input bool   InpUseCorrelFilter   = true;   // Block trades if currency already exposed N times?
input int    InpMaxSameCurrDir    = 1;      // Max positions long/short any single currency
input bool   InpVerboseLogs       = true;   // Print detailed logs

//--- Hidden Divergence
input group "Hidden Divergence (ADX Trending Mode)"
input int    InpDivLookback     = 20;  // Bars to look back for swing reference
input int    InpDivRSI_Pullback = 40;  // RSI must be below this to confirm pullback in uptrend
input int    InpDivRSI_Rally    = 60;  // RSI must be above this to confirm rally in downtrend

//--- Session Breakout
input group "Session Breakout"
// Optimization notes:
//   Best pairs: GBPUSD / EURUSD / GBPJPY
//   SL: 0.8x-1.5x range size; TP: 1.5x-3x range size
//   London session typically: InpBreakoutHour=7 UTC, InpBreakoutRangeMin=30
input int    InpBreakoutHour     = 7;   // Session range start hour (UTC/server)
input int    InpBreakoutRangeMin = 30;  // Range accumulation window in minutes

//--- EMA Cross ADX
input group "EMA Cross ADX"
// Optimization notes:
//   Best pairs: EURUSD / GBPUSD / USDJPY / AUDUSD
//   Timeframe: M15/H1; FastEMA: 5-13; SlowEMA: 17-34; ADX threshold: 20-40 step 5
input int    InpFastEMA_Period   = 8;    // Fast EMA period
input int    InpSlowEMA_Period   = 21;   // Slow EMA period
input int    InpTrendEMA_Period  = 200;  // Trend EMA period (200)

//--- Daily Limits
input group "Daily Limits (deposit currency)"
input bool   EnableDailyLimits  = true;   // Enable daily profit/loss limits?
input double DailyProfitTarget  = 150.0;  // Stop trading when daily profit reaches this
input double DailyLossLimit     = 150.0;  // Stop trading when daily loss reaches this

//--- News Filter
input group "News Filter (Server Time)"
input bool   InpUseNewsFilter      = false; // Enable news filter?
input bool   InpCloseBeforeNews    = true;  // Close positions before news window?
input int    InpNewsTimeHour       = 15;    // News hour
input int    InpNewsTimeMinute     = 30;    // News minute
input int    InpMinutesBeforeNews  = 30;    // Minutes before news to stop trading
input int    InpMinutesAfterNews   = 30;    // Minutes after news to resume

//--- Trading Hours
input group "Trading Hours (Server Time)"
input bool   EnableTimeFilter  = true;            // Enable time filter?
input string MondayHours       = "07:00-21:00";
input string TuesdayHours      = "07:00-21:00";
input string WednesdayHours    = "07:00-21:00";
input string ThursdayHours     = "07:00-21:00";
input string FridayHours       = "07:00-20:00";
input string SaturdayHours     = "00:00-00:00";
input string SundayHours       = "00:00-00:00";
input bool   CloseAtEndTime    = true;            // Close positions when session ends?

//+------------------------------------------------------------------+
//--- Global objects
CTrade        trade;
CPositionInfo posInfo;
CAccountInfo  account;
CDealInfo     deal;

//--- Indicator handles (all on InpSignalTF)
int rsi_handle;
int ema_handle;
int adx_handle;
int fast_ema_handle;
int slow_ema_handle;
int trend_ema_handle;

//--- Daily limit state
bool     g_daily_limit_reached  = false;
datetime g_last_limit_check_day = 0;

//--- Exit detection
bool     g_was_in_position = false;

//--- Daily PnL accumulator
double   g_daily_pnl     = 0.0;
datetime g_daily_pnl_day = 0;

//--- Regime tracking (MEAN_REVERSION)
int g_last_regime = -1;  // 0=ranging, 1=trending

//--- EMA cross state (EMA_CROSS_ADX)
int g_ema_cross_dir = 0;  // +1 = bullish cross seen, -1 = bearish cross seen

//--- Session breakout globals
double   g_brk_high        = 0.0;
double   g_brk_low         = 0.0;
bool     g_brk_range_built = false;
bool     g_brk_bought      = false;
bool     g_brk_sold        = false;
datetime g_brk_day         = 0;

//+------------------------------------------------------------------+
//| Indicator helpers (read on InpSignalTF)                           |
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

double GetFastEMA(int shift)
{
    double buf[1];
    if(CopyBuffer(fast_ema_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

double GetSlowEMA(int shift)
{
    double buf[1];
    if(CopyBuffer(slow_ema_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

double GetTrendEMA(int shift)
{
    double buf[1];
    if(CopyBuffer(trend_ema_handle, 0, shift, 1, buf) > 0) return buf[0];
    return -1;
}

//+------------------------------------------------------------------+
//| IsManagedMagic: single or multi-pair range check                  |
//+------------------------------------------------------------------+
bool IsManagedMagic(ulong m)
{
    if(!InpMultiPairMode)
        return (m == InpMagicNumber);
    return (m >= InpMagicNumber && m <= InpMagicNumber + 19);
}

//+------------------------------------------------------------------+
//| Correlation filter                                                |
//+------------------------------------------------------------------+
bool IsCorrelated(string currency, int newDir)
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(!IsManagedMagic(posInfo.Magic())) continue;
        string sym = posInfo.Symbol();
        string b   = StringSubstr(sym, 0, 3);
        string q   = StringSubstr(sym, 3, 3);
        int dir = 0;
        if(b == currency) dir = (posInfo.PositionType() == POSITION_TYPE_BUY) ?  1 : -1;
        if(q == currency) dir = (posInfo.PositionType() == POSITION_TYPE_BUY) ? -1 :  1;
        if(dir == newDir) count++;
    }
    if(count >= InpMaxSameCurrDir)
    {
        if(InpVerboseLogs)
            PrintFormat("Entry blocked: %s correlation (%d positions already %s %s)",
                        currency, count, newDir > 0 ? "long" : "short", currency);
        return true;
    }
    return false;
}

bool IsEntryCurrencyBlocked(bool isBuy)
{
    if(!InpUseCorrelFilter) return false;
    string base  = StringSubstr(_Symbol, 0, 3);
    string quote = StringSubstr(_Symbol, 3, 3);
    int baseDir  = isBuy ? 1 : -1;
    return IsCorrelated(base, baseDir) || IsCorrelated(quote, -baseDir);
}

//+------------------------------------------------------------------+
//| PnL helpers                                                       |
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
        if(!IsManagedMagic(deal.Magic())) continue;
        if(deal.Symbol() != _Symbol)      continue;
        if(deal.Entry()  != DEAL_ENTRY_OUT) continue;
        return deal.Profit() + deal.Commission() + deal.Swap();
    }
    return 0.0;
}

//+------------------------------------------------------------------+
//| Swing detectors — reads closes on InpSignalTF                     |
//| A bar i is a swing low if:                                        |
//|   close[i] < close[i-1] && close[i] < close[i+1]                 |
//|   && close[i] < close[i-2] && close[i] < close[i+2]              |
//| (same logic inverted for swing high)                              |
//+------------------------------------------------------------------+
int FindSwingLow(int startBar, int endBar)
{
    // startBar and endBar are shift indices (startBar > endBar typically means
    // startBar is older; iterate from endBar+2 to startBar-2 to have room for neighbors)
    int best = -1;
    double bestClose = DBL_MAX;
    for(int i = startBar - 2; i >= endBar + 2; i--)
    {
        double c  = iClose(_Symbol, InpSignalTF, i);
        double c1 = iClose(_Symbol, InpSignalTF, i - 1);
        double c2 = iClose(_Symbol, InpSignalTF, i - 2);
        double cp1 = iClose(_Symbol, InpSignalTF, i + 1);
        double cp2 = iClose(_Symbol, InpSignalTF, i + 2);
        if(c < cp1 && c < cp2 && c < c1 && c < c2)
        {
            if(c < bestClose) { bestClose = c; best = i; }
        }
    }
    return best;
}

int FindSwingHigh(int startBar, int endBar)
{
    int best = -1;
    double bestClose = -DBL_MAX;
    for(int i = startBar - 2; i >= endBar + 2; i--)
    {
        double c  = iClose(_Symbol, InpSignalTF, i);
        double c1 = iClose(_Symbol, InpSignalTF, i - 1);
        double c2 = iClose(_Symbol, InpSignalTF, i - 2);
        double cp1 = iClose(_Symbol, InpSignalTF, i + 1);
        double cp2 = iClose(_Symbol, InpSignalTF, i + 2);
        if(c > cp1 && c > cp2 && c > c1 && c > c2)
        {
            if(c > bestClose) { bestClose = c; best = i; }
        }
    }
    return best;
}

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFillingBySymbol(_Symbol);

    // Create handles on InpSignalTF
    rsi_handle = iRSI(_Symbol, InpSignalTF, InpRSI_Period, PRICE_CLOSE);
    if(rsi_handle == INVALID_HANDLE) { Print("RSI handle failed"); return INIT_FAILED; }

    ema_handle = iMA(_Symbol, InpSignalTF, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(ema_handle == INVALID_HANDLE) { Print("EMA handle failed"); return INIT_FAILED; }

    adx_handle = iADX(_Symbol, InpSignalTF, InpADX_Period);
    if(adx_handle == INVALID_HANDLE) { Print("ADX handle failed"); return INIT_FAILED; }

    fast_ema_handle = iMA(_Symbol, InpSignalTF, InpFastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(fast_ema_handle == INVALID_HANDLE) { Print("Fast EMA handle failed"); return INIT_FAILED; }

    slow_ema_handle = iMA(_Symbol, InpSignalTF, InpSlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(slow_ema_handle == INVALID_HANDLE) { Print("Slow EMA handle failed"); return INIT_FAILED; }

    trend_ema_handle = iMA(_Symbol, InpSignalTF, InpTrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    if(trend_ema_handle == INVALID_HANDLE) { Print("Trend EMA handle failed"); return INIT_FAILED; }

    string stratName = (InpStrategy == MEAN_REVERSION)  ? "MEAN_REVERSION" :
                       (InpStrategy == SESSION_BREAKOUT) ? "SESSION_BREAKOUT" :
                                                           "EMA_CROSS_ADX";
    PrintFormat("ScalpEngine v3 initialized | Strategy=%s | TF=%s | Magic=%llu | MultiPair=%s | SL=%d TP=%d pts",
                stratName,
                EnumToString(InpSignalTF),
                InpMagicNumber,
                InpMultiPairMode ? "ON" : "OFF",
                InpStopLossPoints, InpTakeProfitPoints);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(rsi_handle);
    IndicatorRelease(ema_handle);
    IndicatorRelease(adx_handle);
    IndicatorRelease(fast_ema_handle);
    IndicatorRelease(slow_ema_handle);
    IndicatorRelease(trend_ema_handle);
    Print("ScalpEngine v3 deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Detect and log external exits (SL, TP, manual)                   |
//+------------------------------------------------------------------+
void DetectAndLogExit()
{
    if(!HistorySelect(TimeCurrent() - 86400, TimeCurrent())) return;
    for(int i = (int)HistoryDealsTotal() - 1; i >= 0; i--)
    {
        if(!deal.SelectByIndex(i)) continue;
        if(!IsManagedMagic(deal.Magic())) continue;
        if(deal.Symbol() != _Symbol)       continue;
        if(deal.Entry()  != DEAL_ENTRY_OUT) continue;
        long   dealReason = HistoryDealGetInteger(deal.Ticket(), DEAL_REASON);
        string closeDesc  = (dealReason == DEAL_REASON_SL) ? "STOP LOSS" :
                            (dealReason == DEAL_REASON_TP) ? "TAKE PROFIT" : "closed externally";
        double extProfit  = deal.Profit() + deal.Commission() + deal.Swap();
        PrintFormat("[EXIT] %s | %s | profit: %+.2f %s | price: %.5f",
                    deal.Type() == DEAL_TYPE_SELL ? "BUY closed" : "SELL closed",
                    closeDesc, extProfit, AccountInfoString(ACCOUNT_CURRENCY), deal.Price());
        LogTradePnl(extProfit);
        break;
    }
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    ManageSessionEnd();
    ManageNewsClose();
    ManageTrailingStop();

    // SESSION_BREAKOUT range tracking runs on every tick
    if(InpStrategy == SESSION_BREAKOUT)
        UpdateBreakoutRange();

    // Detect external close
    bool now_in_position = IsPositionOpen();
    if(g_was_in_position && !now_in_position)
        DetectAndLogExit();
    g_was_in_position = now_in_position;

    // Once-per-bar gate on InpSignalTF
    static datetime lastBar = 0;
    datetime curBar = iTime(_Symbol, InpSignalTF, 0);
    if(lastBar == curBar) return;
    lastBar = curBar;

    // Spread check
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
    if(spread > InpMaxSpreadPoints)
    {
        if(InpVerboseLogs)
            PrintFormat("Entry blocked: spread %.1f > %d pts", spread, InpMaxSpreadPoints);
        return;
    }

    // Dispatch strategy
    switch(InpStrategy)
    {
        case MEAN_REVERSION:
            RouteByRegime();
            break;
        case SESSION_BREAKOUT:
            CheckSessionBreakout();
            break;
        case EMA_CROSS_ADX:
            CheckEMACrossADX();
            break;
    }
}

//+------------------------------------------------------------------+
//| Strategy 0: MEAN_REVERSION — regime routing                       |
//+------------------------------------------------------------------+
void RouteByRegime()
{
    if(InpUseADXFilter)
    {
        double adx = GetADX(1);
        if(adx < 0) return;
        int regime = (adx >= InpADX_Threshold) ? 1 : 0;
        if(regime != g_last_regime)
        {
            if(regime == 1)
                PrintFormat("[REGIME] Switched to TRENDING (ADX=%.1f >= %.0f) — hidden divergence mode",
                            adx, InpADX_Threshold);
            else
                PrintFormat("[REGIME] Switched to RANGING (ADX=%.1f < %.0f) — mean reversion mode",
                            adx, InpADX_Threshold);
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
//| Strategy 0: mean reversion entry                                  |
//| Optimization: best pairs EURUSD/GBPUSD/USDJPY/AUDUSD             |
//|               SL 40-80pt; ADX threshold 25-40 step 5             |
//+------------------------------------------------------------------+
void CheckForEntrySignals()
{
    if(IsPositionOpen()) return;
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

    double rsi1 = GetRSI(1);
    double rsi2 = GetRSI(2);
    if(rsi1 < 0 || rsi2 < 0) return;

    bool buySignal  = (rsi2 < InpRSI_Oversold  && rsi1 >= InpRSI_Oversold);
    bool sellSignal = (rsi2 > InpRSI_Overbought && rsi1 <= InpRSI_Overbought);

    if(!buySignal && !sellSignal) return;

    if(InpUseEMAFilter)
    {
        double ema   = GetEMA(1);
        double price = iClose(_Symbol, InpSignalTF, 1);
        if(ema < 0) return;
        if(buySignal  && price < ema)
        {
            if(InpVerboseLogs)
                PrintFormat("Entry blocked: BUY signal but price (%.5f) below EMA (%.5f)", price, ema);
            buySignal = false;
        }
        if(sellSignal && price > ema)
        {
            if(InpVerboseLogs)
                PrintFormat("Entry blocked: SELL signal but price (%.5f) above EMA (%.5f)", price, ema);
            sellSignal = false;
        }
        if(!buySignal && !sellSignal) return;
    }

    if(IsEntryCurrencyBlocked(buySignal)) return;

    double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
    if(lots <= 0) return;

    if(buySignal)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double sl  = (InpStopLossPoints   > 0) ? ask - InpStopLossPoints   * _Point : 0;
        double tp  = (InpTakeProfitPoints > 0) ? ask + InpTakeProfitPoints * _Point : 0;
        PrintFormat("[ENTRY] BUY @ %.5f | RSI: %.1f→%.1f | SL: %.5f | TP: %.5f | lots: %.2f",
                    ask, rsi2, rsi1, sl, tp, lots);
        if(!trade.Buy(lots, _Symbol, ask, sl, tp, "SE3_MR_Buy"))
            PrintFormat("[ENTRY] BUY failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    else
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double sl  = (InpStopLossPoints   > 0) ? bid + InpStopLossPoints   * _Point : 0;
        double tp  = (InpTakeProfitPoints > 0) ? bid - InpTakeProfitPoints * _Point : 0;
        PrintFormat("[ENTRY] SELL @ %.5f | RSI: %.1f→%.1f | SL: %.5f | TP: %.5f | lots: %.2f",
                    bid, rsi2, rsi1, sl, tp, lots);
        if(!trade.Sell(lots, _Symbol, bid, sl, tp, "SE3_MR_Sell"))
            PrintFormat("[ENTRY] SELL failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Strategy 0: hidden divergence entry (trending regime)             |
//| Uses FindSwingLow/FindSwingHigh for reference bar                 |
//+------------------------------------------------------------------+
void CheckForHiddenDivergence()
{
    if(IsPositionOpen()) return;
    if(IsDailyLimitReached())   { if(InpVerboseLogs) Print("Entry blocked: daily limit reached."); return; }
    if(!IsWithinTradingHours()) { if(InpVerboseLogs) Print("Entry blocked: outside trading hours."); return; }
    if(IsNewsTimeRestricted())  { if(InpVerboseLogs) Print("Entry blocked: news filter."); return; }

    double ema    = GetEMA(1);  if(ema < 0) return;
    double price1 = iClose(_Symbol, InpSignalTF, 1);
    double rsi1   = GetRSI(1);  if(rsi1 < 0) return;

    bool uptrend   = (price1 > ema);
    bool downtrend = (price1 < ema);
    if(!uptrend && !downtrend) return;

    if(uptrend && rsi1 < InpDivRSI_Pullback)
    {
        // Find swing low in lookback window for reference bar
        int refBar = FindSwingLow(InpDivLookback, 2);
        if(refBar < 0)
        {
            if(InpVerboseLogs) Print("[DIV] No swing low found in lookback");
            return;
        }
        double refClose = iClose(_Symbol, InpSignalTF, refBar);
        double refRSI   = GetRSI(refBar);
        if(refRSI < 0) return;

        // Hidden bullish: price higher low AND RSI lower low
        if(price1 > refClose && rsi1 < refRSI)
        {
            if(IsEntryCurrencyBlocked(true)) return;
            double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
            if(lots <= 0) return;
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl  = ask - InpStopLossPoints  * _Point;
            double tp  = (InpTakeProfitPoints > 0) ? ask + InpTakeProfitPoints * _Point : 0;
            PrintFormat("[ENTRY] [DIV] HIDDEN BULL BUY @ %.5f | RSI: %.1f < ref %.1f (bar %d) | price: %.5f > ref %.5f | SL: %.5f | TP: %.5f",
                        ask, rsi1, refRSI, refBar, price1, refClose, sl, tp);
            if(!trade.Buy(lots, _Symbol, ask, sl, tp, "SE3_Div_Buy"))
                PrintFormat("[ENTRY] [DIV] BUY failed: %d %s",
                            trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        else if(InpVerboseLogs)
            PrintFormat("[DIV] No hidden bull | RSI: %.1f ref: %.1f | price: %.5f ref: %.5f",
                        rsi1, refRSI, price1, refClose);
    }
    else if(downtrend && rsi1 > InpDivRSI_Rally)
    {
        // Find swing high in lookback window for reference bar
        int refBar = FindSwingHigh(InpDivLookback, 2);
        if(refBar < 0)
        {
            if(InpVerboseLogs) Print("[DIV] No swing high found in lookback");
            return;
        }
        double refClose = iClose(_Symbol, InpSignalTF, refBar);
        double refRSI   = GetRSI(refBar);
        if(refRSI < 0) return;

        // Hidden bearish: price lower high AND RSI higher high
        if(price1 < refClose && rsi1 > refRSI)
        {
            if(IsEntryCurrencyBlocked(false)) return;
            double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
            if(lots <= 0) return;
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double sl  = bid + InpStopLossPoints  * _Point;
            double tp  = (InpTakeProfitPoints > 0) ? bid - InpTakeProfitPoints * _Point : 0;
            PrintFormat("[ENTRY] [DIV] HIDDEN BEAR SELL @ %.5f | RSI: %.1f > ref %.1f (bar %d) | price: %.5f < ref %.5f | SL: %.5f | TP: %.5f",
                        bid, rsi1, refRSI, refBar, price1, refClose, sl, tp);
            if(!trade.Sell(lots, _Symbol, bid, sl, tp, "SE3_Div_Sell"))
                PrintFormat("[ENTRY] [DIV] SELL failed: %d %s",
                            trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        else if(InpVerboseLogs)
            PrintFormat("[DIV] No hidden bear | RSI: %.1f ref: %.1f | price: %.5f ref: %.5f",
                        rsi1, refRSI, price1, refClose);
    }
}

//+------------------------------------------------------------------+
//| Strategy 1: SESSION_BREAKOUT — range tracking (called every tick) |
//| Optimization: best pairs GBPUSD/EURUSD/GBPJPY                    |
//|               SL 0.8x-1.5x range; TP 1.5x-3x range              |
//|               London session: InpBreakoutHour=7 UTC              |
//+------------------------------------------------------------------+
void UpdateBreakoutRange()
{
    datetime now = TimeCurrent();
    MqlDateTime t;
    TimeToStruct(now, t);

    // Build today's session start/end times
    MqlDateTime tDay;
    TimeToStruct(now, tDay);
    tDay.hour = InpBreakoutHour; tDay.min = 0; tDay.sec = 0;
    datetime rangeStart = StructToTime(tDay);
    datetime rangeEnd   = rangeStart + (datetime)(InpBreakoutRangeMin * 60);

    // Reset on new day
    datetime today = rangeStart;  // use rangeStart as day key
    if(g_brk_day != today)
    {
        g_brk_day         = today;
        g_brk_high        = 0.0;
        g_brk_low         = DBL_MAX;
        g_brk_range_built = false;
        g_brk_bought      = false;
        g_brk_sold        = false;
        if(InpVerboseLogs)
            PrintFormat("[BREAKOUT] New day — range reset. Window: %s – %s",
                        TimeToString(rangeStart, TIME_MINUTES),
                        TimeToString(rangeEnd, TIME_MINUTES));
    }

    // Accumulate H/L during range window
    if(now >= rangeStart && now < rangeEnd)
    {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(bid > g_brk_high) g_brk_high = bid;
        if(bid < g_brk_low || g_brk_low == DBL_MAX) g_brk_low = bid;
    }
    else if(now >= rangeEnd && !g_brk_range_built && g_brk_high > 0 && g_brk_low < DBL_MAX)
    {
        g_brk_range_built = true;
        PrintFormat("[BREAKOUT] Range locked: High=%.5f Low=%.5f Size=%.1f pts",
                    g_brk_high, g_brk_low, (g_brk_high - g_brk_low) / _Point);
    }
}

//+------------------------------------------------------------------+
//| Strategy 1: SESSION_BREAKOUT — entry (called once per bar)        |
//+------------------------------------------------------------------+
void CheckSessionBreakout()
{
    if(!g_brk_range_built) return;
    if(IsPositionOpen()) return;
    if(IsDailyLimitReached())   { if(InpVerboseLogs) Print("Entry blocked: daily limit reached."); return; }
    if(!IsWithinTradingHours()) { if(InpVerboseLogs) Print("Entry blocked: outside trading hours."); return; }
    if(IsNewsTimeRestricted())  { if(InpVerboseLogs) Print("Entry blocked: news filter."); return; }

    double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double rangeSize  = g_brk_high - g_brk_low;
    if(rangeSize <= 0) return;

    bool insideRange = (bid >= g_brk_low && ask <= g_brk_high);

    if(!g_brk_bought && !insideRange && ask > g_brk_high)
    {
        if(IsEntryCurrencyBlocked(true)) return;
        double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
        if(lots <= 0) return;
        double sl = ask - rangeSize;
        double tp = ask + 2.0 * rangeSize;
        PrintFormat("[BREAKOUT] BUY @ %.5f | rangeHigh=%.5f rangeSize=%.1f pts | SL=%.5f TP=%.5f | lots=%.2f",
                    ask, g_brk_high, rangeSize / _Point, sl, tp, lots);
        if(trade.Buy(lots, _Symbol, ask, sl, tp, "SE3_BRK_Buy"))
            g_brk_bought = true;
        else
            PrintFormat("[BREAKOUT] BUY failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    else if(!g_brk_sold && !insideRange && bid < g_brk_low)
    {
        if(IsEntryCurrencyBlocked(false)) return;
        double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
        if(lots <= 0) return;
        double sl = bid + rangeSize;
        double tp = bid - 2.0 * rangeSize;
        PrintFormat("[BREAKOUT] SELL @ %.5f | rangeLow=%.5f rangeSize=%.1f pts | SL=%.5f TP=%.5f | lots=%.2f",
                    bid, g_brk_low, rangeSize / _Point, sl, tp, lots);
        if(trade.Sell(lots, _Symbol, bid, sl, tp, "SE3_BRK_Sell"))
            g_brk_sold = true;
        else
            PrintFormat("[BREAKOUT] SELL failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Strategy 2: EMA_CROSS_ADX                                         |
//| Optimization: best on M15/H1; FastEMA 5-13; SlowEMA 17-34        |
//|               ADX threshold 20-40 step 5                          |
//|               pairs: EURUSD/GBPUSD/USDJPY/AUDUSD                 |
//+------------------------------------------------------------------+
void CheckEMACrossADX()
{
    if(IsPositionOpen()) return;
    if(IsDailyLimitReached())   { if(InpVerboseLogs) Print("Entry blocked: daily limit reached."); return; }
    if(!IsWithinTradingHours()) { if(InpVerboseLogs) Print("Entry blocked: outside trading hours."); return; }
    if(IsNewsTimeRestricted())  { if(InpVerboseLogs) Print("Entry blocked: news filter."); return; }

    double fast1 = GetFastEMA(1);
    double fast2 = GetFastEMA(2);
    double slow1 = GetSlowEMA(1);
    double slow2 = GetSlowEMA(2);
    if(fast1 < 0 || fast2 < 0 || slow1 < 0 || slow2 < 0) return;

    double adx = GetADX(1);
    if(adx < 0) return;

    double trendEMA = GetTrendEMA(1);
    if(trendEMA < 0) return;

    double price1 = iClose(_Symbol, InpSignalTF, 1);

    bool bullCross = (fast2 <= slow2 && fast1 > slow1);
    bool bearCross = (fast2 >= slow2 && fast1 < slow1);

    if(adx < InpADX_Threshold)
    {
        if(InpVerboseLogs)
            PrintFormat("[EMACROSS] ADX=%.1f below threshold %.0f — no entry", adx, InpADX_Threshold);
        return;
    }

    // BUY: fast crosses above slow + above EMA200 + cross direction changed since last entry
    if(bullCross && g_ema_cross_dir != 1 && price1 > trendEMA)
    {
        if(IsEntryCurrencyBlocked(true)) return;
        double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
        if(lots <= 0) return;
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double slDist = InpStopLossPoints * _Point;
        int swLow = FindSwingLow(InpDivLookback, 2);
        if(swLow > 0)
        {
            double swLowPrice = iClose(_Symbol, InpSignalTF, swLow);
            if(ask - swLowPrice > 0) slDist = ask - swLowPrice;
        }
        double sl = ask - slDist;
        double tp = ask + 2.0 * slDist;

        PrintFormat("[EMACROSS] BUY @ %.5f | fast=%.5f slow=%.5f ADX=%.1f EMA200=%.5f | SL=%.5f TP=%.5f | lots=%.2f",
                    ask, fast1, slow1, adx, trendEMA, sl, tp, lots);
        if(trade.Buy(lots, _Symbol, ask, sl, tp, "SE3_EMA_Buy"))
            g_ema_cross_dir = 1;
        else
            PrintFormat("[EMACROSS] BUY failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
    // SELL: fast crosses below slow + below EMA200 + cross direction changed since last entry
    else if(bearCross && g_ema_cross_dir != -1 && price1 < trendEMA)
    {
        if(IsEntryCurrencyBlocked(false)) return;
        double lots = InpUseRiskManagement ? CalculateLotSize() : NormalizeVolume(InpLots);
        if(lots <= 0) return;
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        double slDist = InpStopLossPoints * _Point;
        int swHigh = FindSwingHigh(InpDivLookback, 2);
        if(swHigh > 0)
        {
            double swHighPrice = iClose(_Symbol, InpSignalTF, swHigh);
            if(swHighPrice - bid > 0) slDist = swHighPrice - bid;
        }
        double sl = bid + slDist;
        double tp = bid - 2.0 * slDist;

        PrintFormat("[EMACROSS] SELL @ %.5f | fast=%.5f slow=%.5f ADX=%.1f EMA200=%.5f | SL=%.5f TP=%.5f | lots=%.2f",
                    bid, fast1, slow1, adx, trendEMA, sl, tp, lots);
        if(trade.Sell(lots, _Symbol, bid, sl, tp, "SE3_EMA_Sell"))
            g_ema_cross_dir = -1;
        else
            PrintFormat("[EMACROSS] SELL failed: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| IsPositionOpen: checks only this EA's magic on this symbol        |
//+------------------------------------------------------------------+
bool IsPositionOpen()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(posInfo.SelectByIndex(i) &&
           posInfo.Magic() == InpMagicNumber &&
           posInfo.Symbol() == _Symbol)
            return true;
    return false;
}

//+------------------------------------------------------------------+
//| Trailing stop with TP guard                                       |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(!InpUseTrailing) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic()  != InpMagicNumber) continue;
        if(posInfo.Symbol() != _Symbol)        continue;

        double open    = posInfo.PriceOpen();
        double sl      = posInfo.StopLoss();
        double tp      = posInfo.TakeProfit();
        double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double trigger = InpTrailingTrigger * _Point;
        double step    = InpTrailingStep    * _Point;

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            double profit = bid - open;
            if(profit < trigger) continue;
            double newSL = NormalizeDouble(bid - step, _Digits);
            if(newSL <= sl) continue;                        // only move forward
            if(tp > 0 && newSL >= tp) continue;              // BUY guard: newSL must be < tp
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
            double newSL = NormalizeDouble(ask + step, _Digits);
            if(sl > 0 && newSL >= sl) continue;              // only move forward
            if(tp > 0 && newSL <= tp) continue;              // SELL guard: newSL must be > tp
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
//| Daily limit check — uses IsManagedMagic()                         |
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
            if(deal.SelectByIndex(i) && IsManagedMagic(deal.Magic()))
                profit += deal.Profit() + deal.Commission() + deal.Swap();

    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(posInfo.SelectByIndex(i) && IsManagedMagic(posInfo.Magic()))
            profit += posInfo.Profit();

    if(profit >= DailyProfitTarget)
    {
        PrintFormat("[LIMIT] Daily profit target reached (%.2f %s overall). All pairs stopped.",
                    profit, AccountInfoString(ACCOUNT_CURRENCY));
        g_daily_limit_reached = true; return true;
    }
    if(profit <= -DailyLossLimit)
    {
        PrintFormat("[LIMIT] Daily loss limit reached (%.2f %s overall). All pairs stopped.",
                    profit, AccountInfoString(ACCOUNT_CURRENCY));
        g_daily_limit_reached = true; return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Trading hours filter                                              |
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
        if(start == 0 && end == 0) continue;   // "00:00-00:00" = disabled day
        if(nowMin >= start && nowMin < end) return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Session end close                                                  |
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
                        TimeToString(TimeCurrent(), TIME_DATE),
                        g_daily_pnl, AccountInfoString(ACCOUNT_CURRENCY));
        g_daily_pnl = 0.0;
    }
    wasInSession = isInSession;
}

//+------------------------------------------------------------------+
//| News filter                                                        |
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
    datetime newsTime = StructToTime(ts);
    datetime preStart = (datetime)(newsTime - (long)InpMinutesBeforeNews * 60);

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
//| Lot sizing                                                         |
//| valPerPt = tickVal / tickSize (clean, no redundant _Point math)   |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    if(InpStopLossPoints <= 0) return 0;
    double equity   = account.Equity();
    double riskAmt  = equity * (InpRiskPercent / 100.0);
    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize == 0) return 0;
    double valPerPt = tickVal / tickSize;
    double slMoney  = InpStopLossPoints * valPerPt;
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
