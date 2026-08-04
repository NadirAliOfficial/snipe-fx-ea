# Which settings file to use

The EA ships with two tested configurations. Same `.mq5`, different inputs.

## Snipe_FX_Pro_scalper.set — your original style

Keeps the fast tick execution you built: virtual buy and sell stops 2 pips from
price, re-armed every 5 seconds, break even and trailing active. What changed is
only the parts that were broken.

- stop and target sized so the target is not a fifth of the stop
- trailing distance now smaller than the trailing trigger, so a trailed winner
  banks profit instead of closing at exactly zero
- a cooldown after a loss, and a halt after six losses in a row, which stops the
  EA re-buying every bounce in a falling market
- magic number isolation, so it only manages its own trades

## Snipe_FX_Pro_recommended.set — best measured result

Same EA, different settings. Waits for a pullback rather than entering the moment
price moves, uses a wide stop and a target twice its size, and trades roughly 120
times a month instead of 35,000.

Four months XAUUSD, April to July 2026, 100% real tick data:

| | your original EA | recommended |
|---|---|---|
| Win rate | 72.63% | 37.16% |
| Net profit | −9 961 (2 months) | **+774.00** |
| Profit factor | 0.61 | 1.14 |
| Max drawdown | 99.61% | 4.20% |

## On win rate

A high win rate is easy to produce and means nothing on its own. Tuned for win
rate, this same EA wins 75.88% of its trades and still loses 597 over those four
months, because each loss is worth three wins. Your original wins 72.63% and
loses almost the whole account. The recommended settings win far less often and
finish ahead, because the average win is about twice the average loss.

## Before live

Forward test on demo first. The recommended settings are profitable across the
four months and in three of the four individually, which is encouraging but not
proof. No result here is a guarantee of future performance.
