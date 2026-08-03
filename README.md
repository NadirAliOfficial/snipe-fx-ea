# Snipe FX Pro — MT5 Virtual Stealth Execution EA

Rebuild of a tick scalping EA that used virtual (in memory) stop orders and virtual exits.

## Result

Four months continuous, XAUUSD, 100% real ticks, April to July 2026.

| | original | rebuilt |
|---|---|---|
| Win rate | 72.63% | 37.16% |
| **Net profit** | **−9 961** *(2 months)* | **+774.00** |
| Profit factor | 0.61 | **1.14** |
| Max equity drawdown | **99.61%** | **4.20%** |
| Sharpe | — | **2.27** |
| Average win / average loss | — | 36.13 / −18.79 |

Settings: `Snipe_FX_Pro_recommended.set`.

## Win rate is not profitability

The clearest evidence this project produced. Same EA, same four months, same data.
The only difference is the reward ratio:

| | tuned for win rate | tuned for expectancy |
|---|---|---|
| **Win rate** | **75.88%** | 37.16% |
| **Net profit** | **−597.76** | **+774.00** |
| Profit factor | 0.96 | 1.14 |
| Max drawdown | 9.75% | 4.20% |
| Sharpe | −1.92 | 2.27 |

A 75.88% win rate loses money. A 37.16% win rate makes money. Win rate is set
almost entirely by where you put the target relative to the stop — put the target
close and you win most trades by construction, and lose more on each one than you
made on the last three.

The original EA is the same lesson: **72.63% of its trades won, and it lost 99.61%
of the account.**

Win rate held at 74–77% in every period tested, including months the settings had
never seen. Profitability did not follow it once. It is a stable number that tells
you nothing.

**Honest scope.** The recommended settings are profitable over the four months as a
whole and in three of four months individually (April alone is −183). 479 trades is
reasonable but not conclusive evidence, and the settings were chosen with June and
July visible. Forward test on demo before risking money.

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

---

## Test results on real tick data

Everything below was produced with [mt5-cli](https://github.com/NadirAliOfficial/mt5-cli)
against MetaTrader's own strategy tester. No figure is recalculated here.

### Generated ticks lie

The same build, same settings, tested twice — the only difference being whether
MetaTrader had genuine tick data for the period:

| | generated ticks | real ticks |
|---|---|---|
| Profit factor | 1.97 | **0.34** |
| Win rate | 70.5% | **36.6%** |
| Net | +252 | **−5 258** |
| Max equity drawdown | 0.13% | **52.58%** |
| Trades | 1 345 | 23 768 |

Any backtest of this strategy that does not report `100% real ticks` is fiction.
A 5-pip stop cannot be modelled from M1 bars.

### The entry has no edge

36 parameter combinations, XAUUSD M1, 2026.07.13 → 2026.07.20, real ticks:

```
        profit      PF    trades   eqDD%   MaxSpreadPips   MinAtrPips   RewardRatio
  ---------------------------------------------------------------------------------
       -866.12    0.23      2817    8.67             1.2          4.0           2.7
       -866.87    0.23      2822    8.68             1.2          1.0           1.3
      -1597.08    0.23      5073   15.99             1.6          1.0           1.3
       -331.95    0.21      1049    3.33             0.8          4.0           2.7
```

Not one pass reached profit factor 1.0. The decisive detail is the per-trade figure:

```
MaxSpread 0.8  →  1050 trades  →  −332   →  −0.316 per trade
MaxSpread 1.2  →  2817 trades  →  −866   →  −0.307 per trade
MaxSpread 1.6  →  5073 trades  →  −1597  →  −0.315 per trade
```

**Expected payoff is a constant −0.31 per trade across every combination.** Filters
change how many trades are taken; they never change what a trade is worth. That is
the signature of pure transaction cost — the entry contributes no directional edge
to offset the spread, so tightening filters only shrinks the loss toward zero.

A strategy with a real edge shows variance across its parameter surface. This one
shows a flat line.


### Full test log — what was tried and what it did

All on XAUUSD, real ticks, MetaQuotes-Demo, via [mt5-cli](https://github.com/NadirAliOfficial/mt5-cli).

| change | profit factor | note |
|---|---|---|
| Original EA (client's) | 0.34 | 45.26% drawdown |
| Rebuild, rolling 2 pip trigger | 0.37 | |
| Trend filter on M1 | 0.40 | filter helps slightly |
| Reverse / fade the break | 0.12 | far worse, ruled out |
| Bar anchored levels | 0.48 | fewer, better trades |
| Trend filter on M5 | 0.63 | |
| Wide stops after fixing the emergency stop bug | 0.74 | |
| Stop 220 / reward 2.8, one week | 1.45 | 27 trades, curve fit |
| Stop 220 / reward 2.0, June | 1.24 | 177 trades |
| **Same config, July (unseen)** | **0.84** | **does not generalise** |

### Why it cannot be fixed by tuning

At reward ratio 0.15 the stop is 180 pips and the target 27, so barrier geometry
predicts roughly an 87% win rate. Measured: **53%**.

| reward ratio | geometry predicts | measured | PF |
|---|---|---|---|
| 0.15 | ~87% | 53.1% | 0.94 |
| 0.25 | ~80% | 49.1% | 0.97 |
| 0.35 | ~74% | 46.2% | 0.98 |

Roughly 30 points below random, consistently. That also explains why reversing the
entry made things worse rather than better: entering **at market the moment price
has moved 2 pips** takes the worst fill of the micro cycle in *both* directions.
It is an execution defect, not a directional one.

Fixing it means entering passively with a limit order at a level, instead of
chasing a break at market. That is a different strategy, not a parameter.

### Bug found during testing

`EmergencySlPips` was a flat 20 pips on the broker side, so any working stop wider
than 20 never executed — the broker closed first. Every stop and reward setting
above 20 pips collapsed to the same 20/40 structure, which is why entire parameter
sweeps returned byte identical results. Fixed: the disaster stop is now the wider
of `EmergencySlPips` and `EmergencyMultiple` x the working stop.

### What that means

Arming a virtual buy stop and a virtual sell stop 2 pips either side of price is
directionally random. The rebuilt risk structure removes the *guaranteed* loss the
original had, but no parameter set can manufacture an edge that was never there.
Making this profitable requires a real entry signal, which is a different piece of work.

Raw optimization report: [`results/`](results/).

> Caveat, stated because it matters: `MinAtrPips` at 1.0, 2.5 and 4.0 returned identical
> results, so that filter never engaged — M1 gold ATR is always above 4 pips. It was not
> genuinely tested. The conclusion holds regardless, since a filter that only reduces
> trade count cannot lift a constant negative payoff above zero.

---

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
