//+------------------------------------------------------------------+
//|                                                 Snipe_FX_Pro.mq5 |
//|                       Virtual Stealth Execution EA  (rebuilt v3) |
//+------------------------------------------------------------------+
#property copyright "Snipe FX"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  pos;

//--- Money -----------------------------------------------------------
input group "=== Money ==="
input double LotSize              = 0.01;   // Lot size
input long   MagicNumber          = 730115; // Magic number (isolates this EA)

//--- Entry -----------------------------------------------------------
input group "=== Entry ==="
input double DistancePips         = 2.0;    // Virtual stop distance from price
input int    PendingExpirySec     = 5;      // Virtual pending lifetime (sec)
input double MaxSpreadPips        = 1.5;    // Max spread allowed to arm
input bool   ReverseEntry         = false;  // Fade the break instead of following it
input int    LossCooldownSec      = 0;      // Pause after a losing trade (sec, 0 = off)
input int    MaxConsecLosses      = 0;      // Pause the day after N losses in a row (0 = off)
input bool   UseBarAnchor         = false;  // Break a real level instead of a rolling price
input int    AnchorBars           = 3;      // Bars whose high/low form that level
input int    AnchorTfIndex        = 0;      // 0=M1 1=M5 2=M15 3=M30 4=H1 (level timeframe)
input int    TrendTfIndex         = -1;     // -1 = use TrendTimeframe, else 0=M1 1=M5 2=M15 3=M30 4=H1
input bool   UseLimitEntry        = false;  // Wait for a pullback instead of buying the break
input double PullbackPips         = 1.0;    // How far back from the trigger to wait
input int    LimitValidSec        = 30;     // Give up on the pullback after this

//--- Direction filter ------------------------------------------------
input group "=== Direction filter ==="
input bool            UseTrendFilter  = true;       // Only trade with trend
input ENUM_TIMEFRAMES TrendTimeframe  = PERIOD_M1;  // Trend timeframe
input int             FastEmaPeriod   = 8;          // Fast EMA
input int             SlowEmaPeriod   = 21;         // Slow EMA
input bool            UseVolFilter    = true;       // Skip dead market
input double          MinAtrPips      = 1.0;        // Min ATR to trade

//--- Stop loss -------------------------------------------------------
input group "=== Stop loss ==="
input bool   UseAtrStop           = true;   // ATR based working stop
input int    AtrPeriod            = 14;     // ATR period
input double AtrSlMultiplier      = 1.2;    // ATR x this = working stop
input double MinStopPips          = 2.0;    // Floor for working stop
input double MaxStopPips          = 8.0;    // Cap for working stop
input double FixedStopPips        = 4.0;    // Used when UseAtrStop = false
input double EmergencySlPips      = 20.0;   // Broker side disaster stop (floor)
input double EmergencyTpPips      = 40.0;   // Broker side disaster target (floor)
input double EmergencyMultiple    = 3.0;    // Disaster stop must also be this x the working stop

//--- Take profit -----------------------------------------------------
input group "=== Take profit ==="
input bool   UseRiskRewardTp      = true;   // TP = working stop x ratio
input double RewardRatio          = 1.3;    // Reward to risk ratio
input double FixedTakeProfitPips  = 3.0;    // Used when UseRiskRewardTp = false

//--- Exit management -------------------------------------------------
input group "=== Exit management ==="
input bool   UseBreakEven         = true;   // Move to break even
input double BreakEvenTriggerPips = 1.5;    // Profit to trigger break even
input double BreakEvenLockPips    = 0.3;    // Profit locked at break even
input bool   UseTrailing          = true;   // Trail behind price
input double TrailingStartPips    = 2.5;    // Profit to start trailing
input double TrailingDistancePips = 1.2;    // Trail distance (must be < start)
input double TrailingStepPips     = 0.2;    // Min improvement to move stop

//--- Slippage --------------------------------------------------------
input group "=== Slippage ==="
input int    MaxDeviationPoints   = 10;     // Max deviation broker may fill at
input double MaxEntrySlippagePips = 1.0;    // Abandon fill worse than this

//--- Risk guard ------------------------------------------------------
input group "=== Risk guard ==="
input bool   UseDailyLossLimit    = true;   // Stop after daily loss
input double DailyLossPercent     = 5.0;    // Percent of start balance (0 = off)
input int    MaxTradesPerDay      = 0;      // 0 = unlimited
input bool   UseSessionFilter     = false;  // Restrict trading hours
input int    SessionStartHour     = 0;      // Server hour, inclusive
input int    SessionEndHour       = 24;     // Server hour, exclusive

//--- Misc ------------------------------------------------------------
input group "=== Misc ==="
input double PipSizeOverride      = 0.0;    // 0 = auto detect pip size
input bool   VerboseLog           = true;   // Print detail to journal

//--- Globals ---------------------------------------------------------
double   pip            = 0.10;
int      ema_fast_h     = INVALID_HANDLE;
int      ema_slow_h     = INVALID_HANDLE;
int      atr_h          = INVALID_HANDLE;

double   v_buy_price    = 0.0;
double   v_sell_price   = 0.0;
datetime v_place_time   = 0;

bool     pullback_on   = false;
bool     pullback_buy    = false;
double   pullback_px     = 0.0;
datetime pullback_until    = 0;

ulong    current_ticket = 0;
double   virtual_sl     = 0.0;
double   virtual_tp     = 0.0;
double   entry_price    = 0.0;
bool     be_done        = false;

datetime day_stamp      = 0;
double   day_start_bal  = 0.0;
int      day_trades     = 0;
bool     day_blocked    = false;

int      consec_losses  = 0;
datetime cooldown_until = 0;
datetime last_anchor_bar = 0;
double   last_balance   = 0.0;

double   closed_cache   = 0.0;
datetime closed_cache_t = 0;
bool     closed_dirty   = true;

string   gv_prefix      = "";

//+------------------------------------------------------------------+
int OnInit()
{
   pip = DetectPipSize();
   if(pip <= 0.0)
   {
      Print("Init failed: could not resolve pip size for ", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(TrailingDistancePips >= TrailingStartPips && UseTrailing)
   {
      Print("Init failed: TrailingDistancePips must be smaller than TrailingStartPips, "
            "otherwise the trail locks in zero profit.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   double ref_tp = UseRiskRewardTp ? MinStopPips * RewardRatio : FixedTakeProfitPips;
   if(MaxSpreadPips > ref_tp * 0.5)
      PrintFormat("Warning: MaxSpreadPips (%.2f) is more than half the smallest target (%.2f). "
                  "Trades armed at that spread need a much larger move to reach target.",
                  MaxSpreadPips, ref_tp);

   if(EmergencySlPips <= MaxStopPips)
      PrintFormat("Note: EmergencySlPips (%.1f) is inside MaxStopPips (%.1f); "
                  "the disaster stop will be widened to %.1fx the working stop.",
                  EmergencySlPips, MaxStopPips, EmergencyMultiple);

   if(UseTrendFilter)
   {
      ema_fast_h = iMA(_Symbol, TrendTf(), FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      ema_slow_h = iMA(_Symbol, TrendTf(), SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(ema_fast_h == INVALID_HANDLE || ema_slow_h == INVALID_HANDLE)
      {
         Print("Init failed: EMA handle error ", GetLastError());
         return(INIT_FAILED);
      }
   }

   if(UseAtrStop || UseVolFilter)
   {
      atr_h = iATR(_Symbol, TrendTf(), AtrPeriod);
      if(atr_h == INVALID_HANDLE)
      {
         Print("Init failed: ATR handle error ", GetLastError());
         return(INIT_FAILED);
      }
   }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(MaxDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   gv_prefix = StringFormat("SFX_%d_%s_", (int)MagicNumber, _Symbol);
   RestoreState();
   ResetDayIfNeeded();

   PrintFormat("Snipe FX Pro started. pip=%.5f  digits=%d  stops_level=%d points",
               pip, _Digits, (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ema_fast_h != INVALID_HANDLE) IndicatorRelease(ema_fast_h);
   if(ema_slow_h != INVALID_HANDLE) IndicatorRelease(ema_slow_h);
   if(atr_h      != INVALID_HANDLE) IndicatorRelease(atr_h);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDayIfNeeded();

   if(HasPosition())
   {
      v_buy_price  = 0.0;
      v_sell_price = 0.0;
      ManagePosition();
      return;
   }

   if(current_ticket != 0 || virtual_sl != 0.0)
   {
      closed_dirty = true;      // the broker closed it (emergency SL/TP)
      RecordOutcome();
      ClearState();
   }

   if(cooldown_until > 0 && TimeCurrent() < cooldown_until) return;

   if(day_blocked)                 return;
   if(!DailyLossOk())              { BlockDay("daily loss limit reached"); return; }
   if(MaxTradesPerDay > 0 && day_trades >= MaxTradesPerDay) { BlockDay("max trades per day reached"); return; }
   if(!SessionOk())                return;

   ArmVirtualOrders();
   CheckVirtualTrigger();
}

//+------------------------------------------------------------------+
//| Outcome tracking.                                                |
//|                                                                  |
//| Re-arming straight after a stop out is what produced runs of 25  |
//| losses: in a trend the EA kept buying every small bounce and kept |
//| getting stopped. A cooldown breaks that loop.                     |
//+------------------------------------------------------------------+
void RecordOutcome()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(last_balance == 0.0) { last_balance = bal; return; }

   bool lost = (bal < last_balance);
   last_balance = bal;

   if(!lost) { consec_losses = 0; return; }

   consec_losses++;

   if(LossCooldownSec > 0)
      cooldown_until = TimeCurrent() + LossCooldownSec;

   if(MaxConsecLosses > 0 && consec_losses >= MaxConsecLosses)
   {
      BlockDay(StringFormat("%d losses in a row", consec_losses));
      consec_losses = 0;
   }
}

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
void ArmVirtualOrders()
{
   if(UseBarAnchor)
   {
      // Refresh only when a new bar closes. Re-arming every few seconds from a
      // rolling price means breaking out of nothing, which is what produced
      // hundreds of trades a day against a level that did not exist.
      datetime bar = iTime(_Symbol, AnchorTf(), 0);
      if(bar == last_anchor_bar && (v_buy_price > 0.0 || v_sell_price > 0.0)) return;
      last_anchor_bar = bar;
   }
   else if(v_buy_price > 0.0 || v_sell_price > 0.0)
   {
      if(TimeCurrent() - v_place_time >= PendingExpirySec)
      {
         v_buy_price  = 0.0;
         v_sell_price = 0.0;
      }
      else
         return;
   }

   if(!SpreadOk())        return;
   if(!VolatilityOk())    return;

   int bias = TrendBias();          // 1 buy only, -1 sell only, 0 both, -2 no data
   if(bias == -2) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // When fading, the trend filter has to be read the other way round: a break
   // upward is only worth selling if the larger trend is still down.
   int arm = ReverseEntry ? -bias : bias;

   if(arm >= 0)
      v_buy_price = NormalizeDouble(ask + DistancePips * pip, _Digits);
   if(arm <= 0)
      v_sell_price = NormalizeDouble(bid - DistancePips * pip, _Digits);

   v_place_time = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Highest high and lowest low of the last AnchorBars closed bars.  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TfFromIndex(const int idx)
{
   switch(idx)
   {
      case 1:  return PERIOD_M5;
      case 2:  return PERIOD_M15;
      case 3:  return PERIOD_M30;
      case 4:  return PERIOD_H1;
      default: return PERIOD_M1;
   }
}

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TrendTf()
{
   return (TrendTfIndex < 0) ? TrendTimeframe : TfFromIndex(TrendTfIndex);
}

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES AnchorTf()
{
   switch(AnchorTfIndex)
   {
      case 1:  return PERIOD_M5;
      case 2:  return PERIOD_M15;
      case 3:  return PERIOD_M30;
      case 4:  return PERIOD_H1;
      default: return PERIOD_M1;
   }
}

//+------------------------------------------------------------------+
bool AnchorRange(double &hi, double &lo)
{
   int n = MathMax(AnchorBars, 1);
   double h[], l[];
   if(CopyHigh(_Symbol, AnchorTf(), 1, n, h) != n) return false;
   if(CopyLow (_Symbol, AnchorTf(), 1, n, l) != n) return false;

   hi = h[ArrayMaximum(h)];
   lo = l[ArrayMinimum(l)];
   return (hi > 0.0 && lo > 0.0 && hi > lo);
}

//+------------------------------------------------------------------+
void CheckVirtualTrigger()
{
   if(v_buy_price <= 0.0 && v_sell_price <= 0.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // A waiting pullback order takes priority over arming a new one.
   if(pullback_on)
   {
      if(TimeCurrent() > pullback_until) { pullback_on = false; return; }

      bool ready = pullback_buy ? (ask <= pullback_px) : (bid >= pullback_px);
      if(ready)
      {
         pullback_on = false;
         OpenTrade(pullback_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, pullback_px);
      }
      return;
   }

   // ReverseEntry fades the break instead of following it. A 2 pip move on M1
   // gold is noise, and the tester shows the break-following version paying the
   // spread on every trade with nothing to offset it.
   bool hit_up   = (v_buy_price  > 0.0 && ask >= v_buy_price);
   bool hit_down = (v_sell_price > 0.0 && bid <= v_sell_price);
   if(!hit_up && !hit_down) return;

   bool want_buy = hit_up ? !ReverseEntry : ReverseEntry;

   if(UseLimitEntry)
   {
      // Entering at market the instant price has moved takes the worst fill of
      // the micro cycle, in both directions. Wait for price to come back to us.
      double from  = hit_up ? v_buy_price : v_sell_price;
      pullback_px  = want_buy ? from - PullbackPips * pip
                              : from + PullbackPips * pip;
      pullback_px  = NormalizeDouble(pullback_px, _Digits);
      pullback_buy = want_buy;
      pullback_until = TimeCurrent() + LimitValidSec;
      pullback_on = true;
      v_buy_price  = 0.0;
      v_sell_price = 0.0;
      return;
   }

   OpenTrade(want_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
             hit_up ? v_buy_price : v_sell_price);
}

//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double trigger)
{
   double stop_pips = WorkingStopPips();
   if(stop_pips <= 0.0) return;

   double tp_pips = UseRiskRewardTp ? stop_pips * RewardRatio : FixedTakeProfitPips;
   double lots    = NormalizeLots(LotSize);
   if(lots <= 0.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ref = (type == ORDER_TYPE_BUY) ? ask : bid;

   // The broker side stop has to sit well beyond the working stop. Left at a
   // fixed 20 pips it fires first whenever the working stop is wider, so every
   // setting collapses to the same 20/40 structure and nothing else matters.
   double hard_sl_pips = MathMax(EmergencySlPips, stop_pips * EmergencyMultiple);
   double hard_tp_pips = MathMax(EmergencyTpPips, tp_pips   * EmergencyMultiple);

   double hard_sl, hard_tp;
   if(type == ORDER_TYPE_BUY)
   {
      hard_sl = NormalizeDouble(ref - hard_sl_pips * pip, _Digits);
      hard_tp = NormalizeDouble(ref + hard_tp_pips * pip, _Digits);
   }
   else
   {
      hard_sl = NormalizeDouble(ref + hard_sl_pips * pip, _Digits);
      hard_tp = NormalizeDouble(ref - hard_tp_pips * pip, _Digits);
   }

   if(!StopsRespectLevel(type, ref, hard_sl, hard_tp))
   {
      if(VerboseLog) Print("Entry skipped: emergency SL/TP inside broker stops level.");
      return;
   }

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, 0.0, hard_sl, hard_tp, "SnipeFX")
             : trade.Sell(lots, _Symbol, 0.0, hard_sl, hard_tp, "SnipeFX");

   if(!ok)
   {
      PrintFormat("Order failed. retcode=%d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      v_buy_price  = 0.0;
      v_sell_price = 0.0;
      return;
   }

   double filled = trade.ResultPrice();
   if(filled <= 0.0) filled = ref;

   double slip_pips = (type == ORDER_TYPE_BUY) ? (filled - trigger) / pip
                                               : (trigger - filled) / pip;

   if(MaxEntrySlippagePips > 0.0 && slip_pips > MaxEntrySlippagePips)
   {
      PrintFormat("Fill %.2f pips worse than allowed (%.2f). Closing immediately.",
                  slip_pips, MaxEntrySlippagePips);
      ClosePositionByMagic("bad fill");
      v_buy_price  = 0.0;
      v_sell_price = 0.0;
      return;
   }

   entry_price = filled;
   virtual_tp  = (type == ORDER_TYPE_BUY) ? filled + tp_pips   * pip : filled - tp_pips   * pip;
   virtual_sl  = (type == ORDER_TYPE_BUY) ? filled - stop_pips * pip : filled + stop_pips * pip;
   virtual_tp  = NormalizeDouble(virtual_tp, _Digits);
   virtual_sl  = NormalizeDouble(virtual_sl, _Digits);
   be_done     = false;

   current_ticket = 0;
   if(PositionSelect(_Symbol))
      current_ticket = (ulong)PositionGetInteger(POSITION_TICKET);

   day_trades++;
   SaveState();

   if(VerboseLog)
      PrintFormat("%s filled %.5f  slip %.2f pips  stop %.2f pips  target %.2f pips",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), filled, slip_pips, stop_pips, tp_pips);
}

//+------------------------------------------------------------------+
//| Position management                                              |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!SelectOwnPosition()) return;

   ulong  ticket    = (ulong)PositionGetInteger(POSITION_TICKET);
   double open      = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   if(current_ticket != ticket || virtual_sl == 0.0)
   {
      // Position adopted after a restart, or state lost. Rebuild from open price.
      current_ticket = ticket;
      entry_price    = open;
      be_done        = false;

      double stop_pips = WorkingStopPips();
      double tp_pips   = UseRiskRewardTp ? stop_pips * RewardRatio : FixedTakeProfitPips;

      virtual_sl = (ptype == POSITION_TYPE_BUY) ? open - stop_pips * pip : open + stop_pips * pip;
      virtual_tp = (ptype == POSITION_TYPE_BUY) ? open + tp_pips   * pip : open - tp_pips   * pip;
      virtual_sl = NormalizeDouble(virtual_sl, _Digits);
      virtual_tp = NormalizeDouble(virtual_tp, _Digits);
      SaveState();
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double close_px = (ptype == POSITION_TYPE_BUY) ? bid : ask;
   double profit_pips = ((ptype == POSITION_TYPE_BUY) ? (bid - open) : (open - ask)) / pip;

   // Target
   if(virtual_tp > 0.0)
   {
      bool hit = (ptype == POSITION_TYPE_BUY) ? (bid >= virtual_tp) : (ask <= virtual_tp);
      if(hit) { ClosePositionByMagic("virtual TP"); return; }
   }

   // Break even
   if(UseBreakEven && !be_done && profit_pips >= BreakEvenTriggerPips)
   {
      double be = (ptype == POSITION_TYPE_BUY) ? open + BreakEvenLockPips * pip
                                               : open - BreakEvenLockPips * pip;
      be = NormalizeDouble(be, _Digits);
      if(Improves(ptype, be, virtual_sl)) { virtual_sl = be; be_done = true; SaveState(); }
   }

   // Trailing
   if(UseTrailing && profit_pips >= TrailingStartPips)
   {
      double trail = (ptype == POSITION_TYPE_BUY) ? close_px - TrailingDistancePips * pip
                                                  : close_px + TrailingDistancePips * pip;
      trail = NormalizeDouble(trail, _Digits);
      if(Improves(ptype, trail, virtual_sl) && MathAbs(trail - virtual_sl) >= TrailingStepPips * pip)
      {
         virtual_sl = trail;
         SaveState();
      }
   }

   // Stop
   if(virtual_sl > 0.0)
   {
      bool hit = (ptype == POSITION_TYPE_BUY) ? (bid <= virtual_sl) : (ask >= virtual_sl);
      if(hit) ClosePositionByMagic("virtual SL");
   }
}

//+------------------------------------------------------------------+
bool Improves(const ENUM_POSITION_TYPE ptype, const double candidate, const double current)
{
   if(current == 0.0) return true;
   return (ptype == POSITION_TYPE_BUY) ? (candidate > current) : (candidate < current);
}

//+------------------------------------------------------------------+
void ClosePositionByMagic(const string why)
{
   if(!SelectOwnPosition()) return;
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);

   for(int attempt = 0; attempt < 3; attempt++)
   {
      if(trade.PositionClose(ticket))
      {
         if(VerboseLog) Print("Closed ", ticket, " (", why, ")");
         closed_dirty = true;
         ClearState();
         return;
      }
      if(VerboseLog)
         PrintFormat("Close attempt %d failed. retcode=%d %s",
                     attempt + 1, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool SpreadOk()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;
   return (((ask - bid) / pip) <= MaxSpreadPips);
}

//+------------------------------------------------------------------+
bool VolatilityOk()
{
   if(!UseVolFilter) return true;
   double atr = AtrPips();
   if(atr <= 0.0) return false;
   return (atr >= MinAtrPips);
}

//+------------------------------------------------------------------+
int TrendBias()
{
   if(!UseTrendFilter) return 0;

   double f[], s[];
   if(CopyBuffer(ema_fast_h, 0, 0, 1, f) != 1) return -2;
   if(CopyBuffer(ema_slow_h, 0, 0, 1, s) != 1) return -2;

   if(f[0] > s[0]) return 1;
   if(f[0] < s[0]) return -1;
   return -2;
}

//+------------------------------------------------------------------+
double AtrPips()
{
   if(atr_h == INVALID_HANDLE) return 0.0;
   double a[];
   if(CopyBuffer(atr_h, 0, 0, 1, a) != 1) return 0.0;
   return (a[0] / pip);
}

//+------------------------------------------------------------------+
double WorkingStopPips()
{
   if(!UseAtrStop) return FixedStopPips;

   double atr = AtrPips();
   if(atr <= 0.0) return FixedStopPips;

   double v = atr * AtrSlMultiplier;
   v = MathMax(v, MinStopPips);
   v = MathMin(v, MaxStopPips);
   return v;
}

//+------------------------------------------------------------------+
bool SessionOk()
{
   if(!UseSessionFilter) return true;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(SessionStartHour <= SessionEndHour)
      return (t.hour >= SessionStartHour && t.hour < SessionEndHour);
   return (t.hour >= SessionStartHour || t.hour < SessionEndHour);   // wraps midnight
}

//+------------------------------------------------------------------+
//| Daily guard                                                      |
//+------------------------------------------------------------------+
void ResetDayIfNeeded()
{
   datetime today = DayStart(TimeCurrent());
   if(today == day_stamp) return;

   day_stamp     = today;
   day_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   day_trades    = 0;
   day_blocked   = false;
   consec_losses = 0;
   cooldown_until = 0;
   closed_cache  = 0.0;
   closed_dirty  = true;

   if(VerboseLog)
      PrintFormat("New trading day. Start balance %.2f", day_start_bal);
}

//+------------------------------------------------------------------+
datetime DayStart(const datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

//+------------------------------------------------------------------+
bool DailyLossOk()
{
   if(!UseDailyLossLimit || DailyLossPercent <= 0.0) return true;
   if(day_start_bal <= 0.0) return true;

   double limit = day_start_bal * DailyLossPercent / 100.0;
   double loss  = -(ClosedProfitToday() + FloatingProfit());
   return (loss < limit);
}

//+------------------------------------------------------------------+
double ClosedProfitToday()
{
   // Scanning history on every tick is far too heavy for a tick scalper,
   // so it is recomputed only after a close and at most once per second.
   if(!closed_dirty && TimeCurrent() - closed_cache_t < 1) return closed_cache;
   if(!HistorySelect(day_stamp, TimeCurrent() + 60)) return closed_cache;

   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;

      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }

   closed_cache   = sum;
   closed_cache_t = TimeCurrent();
   closed_dirty   = false;
   return sum;
}

//+------------------------------------------------------------------+
double FloatingProfit()
{
   if(!SelectOwnPosition()) return 0.0;
   return PositionGetDouble(POSITION_PROFIT)
        + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
void BlockDay(const string why)
{
   if(day_blocked) return;
   day_blocked = true;
   Print("Trading stopped for today: ", why);
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool SelectOwnPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   return SelectOwnPosition();
}

//+------------------------------------------------------------------+
bool StopsRespectLevel(const ENUM_ORDER_TYPE type, const double ref,
                       const double sl, const double tp)
{
   long   lvl_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = lvl_pts * _Point;
   if(min_dist <= 0.0) return true;

   return (MathAbs(ref - sl) > min_dist && MathAbs(tp - ref) > min_dist);
}

//+------------------------------------------------------------------+
double NormalizeLots(const double lots)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   double v = MathFloor(lots / step) * step;
   v = MathMax(v, min_lot);
   v = MathMin(v, max_lot);
   return NormalizeDouble(v, 2);
}

//+------------------------------------------------------------------+
double DetectPipSize()
{
   if(PipSizeOverride > 0.0) return PipSizeOverride;

   double point = _Point;
   if(point <= 0.0) return 0.0;

   // 4 digit FX and integer quoted symbols use point directly,
   // everything else uses the conventional 10 x point pip.
   if(_Digits == 4 || _Digits == 0) return point;
   return point * 10.0;
}

//+------------------------------------------------------------------+
//| State persistence (survives restart / reconnect)                 |
//+------------------------------------------------------------------+
void SaveState()
{
   GlobalVariableSet(gv_prefix + "sl",     virtual_sl);
   GlobalVariableSet(gv_prefix + "tp",     virtual_tp);
   GlobalVariableSet(gv_prefix + "entry",  entry_price);
   GlobalVariableSet(gv_prefix + "ticket", (double)current_ticket);
   GlobalVariableSet(gv_prefix + "be",     be_done ? 1.0 : 0.0);
}

//+------------------------------------------------------------------+
void RestoreState()
{
   if(!GlobalVariableCheck(gv_prefix + "sl")) return;
   virtual_sl     = GlobalVariableGet(gv_prefix + "sl");
   virtual_tp     = GlobalVariableGet(gv_prefix + "tp");
   entry_price    = GlobalVariableGet(gv_prefix + "entry");
   current_ticket = (ulong)GlobalVariableGet(gv_prefix + "ticket");
   be_done        = (GlobalVariableGet(gv_prefix + "be") > 0.5);
   if(VerboseLog && virtual_sl > 0.0)
      PrintFormat("State restored. ticket=%I64u sl=%.5f tp=%.5f", current_ticket, virtual_sl, virtual_tp);
}

//+------------------------------------------------------------------+
void ClearState()
{
   virtual_sl     = 0.0;
   virtual_tp     = 0.0;
   entry_price    = 0.0;
   current_ticket = 0;
   be_done        = false;
   pullback_on   = false;

   GlobalVariableDel(gv_prefix + "sl");
   GlobalVariableDel(gv_prefix + "tp");
   GlobalVariableDel(gv_prefix + "entry");
   GlobalVariableDel(gv_prefix + "ticket");
   GlobalVariableDel(gv_prefix + "be");
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Optimization score.                                              |
//|                                                                  |
//| Win rate on its own is a trap: a tiny target against a wide stop |
//| wins most trades and still empties the account, which is exactly |
//| what the original EA did at 63%. So a pass only scores if it is  |
//| actually profitable, and among profitable passes the highest win |
//| rate wins. Optimize with criterion 6 (custom max) to use it.     |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 20) return 0.01;                // too few to mean anything

   double pf    = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd    = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double wins  = TesterStatistics(STAT_PROFIT_TRADES);
   double wr    = (wins / trades) * 100.0;

   // Never return 0: MetaTrader drops those passes from the report entirely,
   // and a losing pass is still information worth seeing.
   if(pf <= 1.0)   return pf;                  // 0 .. 1  = unprofitable
   if(dd  > 25.0)  return 1.0 + pf * 0.01;     // profitable but unusable
   return 100.0 + wr;                          // profitable: rank by win rate
}
//+------------------------------------------------------------------+
