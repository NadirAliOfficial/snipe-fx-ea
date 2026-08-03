# Snipe FX Pro — MT5 Virtual Stealth Execution EA

Rebuild of a tick scalping EA that used virtual (in memory) stop orders and virtual exits.
The original logic was sound in structure but negative in expectancy. This version keeps the
stealth execution model and fixes the risk math, the exit logic and the missing isolation.

**File:** `Snipe_FX_Pro.mq5` — MT5 only (MQL5, build 2300+ for `input group`).

---

## Why the original could not be profitable

| Item | Original | Effect |
|---|---|---|
| Virtual take profit | 3.0 pips | real exit |
| Hard stop loss | 20.0 pips | real loss |

```
expectancy @ 65% win rate = 0.65 x 3 − 0.35 x 20 = −5.05 pips per trade
break even win rate       = 20 / (20 + 3)        = 86.96%
```

A 65% win rate against a 1 : 6.7 reward-to-risk ratio loses by construction. No amount of
parameter tuning fixes that; the ratio itself had to change.

Four further defects:

1. **Spread was not gated against the target.** `MaxSpreadPips = 5` (0.50 on gold) allowed
   entries where price had to travel 8 pips to bank a 3 pip target, while the stop stayed at 20.
2. **`TrailingStartPips == TrailingDistancePips`** (both 1.5), so activating the trail placed the
   stop exactly at the open price. Every trailed exit banked zero, minus spread and commission.
3. **No entry filter.** Both a virtual buy stop and a virtual sell stop were armed 2 pips either
   side of price, re-armed every 5 seconds, with no directional bias. That is a coin flip that
   pays the spread on every toss.
4. **No isolation.** `PositionsTotal() == 0` counted positions on *every* symbol, so an unrelated
   trade blocked all entries; and with no magic number the trailing routine would manage and
   close manual trades and other EAs' positions on the same symbol.

---

## What changed

### Risk structure
- Working stop is **ATR based** (`AtrSlMultiplier`, clamped by `MinStopPips` / `MaxStopPips`), so
  stop size tracks current volatility instead of sitting at a fixed 20 pips.
- Target is derived from the stop: `TP = working stop x RewardRatio`. Risk and reward now scale
  together instead of drifting to 1 : 6.7.
- The 20 pip broker side stop is retained purely as a **disaster stop** (`EmergencySlPips`) for
  disconnects and gaps. It is no longer the working exit.

### Exits
- Break even move at `BreakEvenTriggerPips`, locking `BreakEvenLockPips` of real profit.
- Trailing validated at init: **`TrailingDistancePips` must be smaller than `TrailingStartPips`**,
  or the EA refuses to load. This is the bug that made winners exit flat.
- `TrailingStepPips` prevents pointless stop churn on every tick.

### Entry quality
- EMA trend filter (`FastEmaPeriod` / `SlowEmaPeriod` on `TrendTimeframe`) arms only the side that
  agrees with direction, instead of straddling both ways.
- ATR volatility floor (`MinAtrPips`) skips dead, ranging conditions where a 2 pip trigger is noise.
- `MaxSpreadPips` defaults to 1.5 and is checked at init against the smallest possible target;
  a warning is printed if the spread allowance is more than half the target.

### Execution
- `SetDeviationInPoints(MaxDeviationPoints)` so the broker rejects fills outside tolerance.
- Post fill slippage measured against the trigger price; a fill worse than
  `MaxEntrySlippagePips` is closed out immediately rather than carried.
- Market orders sent with price `0.0` (correct for market execution), fill filtering set per
  symbol, retcodes logged, close retried up to three times.
- Broker `SYMBOL_TRADE_STOPS_LEVEL` checked before sending.
- Lots normalised to `SYMBOL_VOLUME_STEP` / min / max.

### Isolation and safety
- Magic number on every order; all position scans filtered by **symbol and magic**.
- Daily loss limit as a percent of the day's opening balance, counting closed plus floating P/L.
  Optional max trades per day and trading hour window. Set `DailyLossPercent = 0` to disable —
  it caps loss only, it never limits trade count.
- Virtual SL/TP persisted to terminal global variables, so a restart or reconnect does not
  leave a position running naked on the emergency stop. An adopted position is rebuilt from
  its open price.
- Pip size auto detected from `_Digits` (4 digit and integer quoted symbols use point, all
  others use 10 x point), with `PipSizeOverride` for unusual feeds.

---

## Default settings

Shipped defaults target XAUUSD on an ECN feed:

```
LotSize              0.01      DistancePips          2.0
MaxSpreadPips        1.5       PendingExpirySec      5
UseAtrStop           true      AtrSlMultiplier       1.2
MinStopPips          2.0       MaxStopPips           8.0
UseRiskRewardTp      true      RewardRatio           1.3
EmergencySlPips      20.0      EmergencyTpPips       40.0
BreakEvenTriggerPips 1.5       BreakEvenLockPips     0.3
TrailingStartPips    2.5       TrailingDistancePips  1.2
MaxDeviationPoints   10        MaxEntrySlippagePips  1.0
DailyLossPercent     5.0       MaxTradesPerDay       0 (unlimited)
```

On XAUUSD one pip = 0.10. Confirm `pip=` in the journal line printed at startup before running
on any other symbol.

## Install

1. Copy `Snipe_FX_Pro.mq5` to `MQL5/Experts/`.
2. Compile in MetaEditor (F7).
3. Attach to the chart, enable algo trading.
4. Backtest with **every tick based on real ticks** and a realistic spread and commission model.

## Notes on testing

The tester does not model latency or slippage on entry. A strategy holding targets this small is
sensitive to both, so live results will sit below backtest results. Validate on demo before
running capital.

---

This is trading software, not financial advice, and no result is guaranteed. Execution quality,
spread and market conditions depend on the broker and the market.
