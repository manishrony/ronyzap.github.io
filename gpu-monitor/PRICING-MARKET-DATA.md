# Pricing engine targets the ask side of the market, not the rented side

## Finding (2026-10-22, zappa1)

`vastai_market_stats()` in `gpu_monitor.sh` builds every market stat the pricing
engine uses (`p25`/`median`/`p75`/`mean`) by querying Vast's `/api/v0/bundles`
endpoint with `rentable: true`:

```bash
q = {'gpu_name': {'eq': gpu_name}, 'rentable': {'eq': True}, 'datacenter': {'eq': False}}
```

That endpoint returns **currently-listed, unrented offers** -- other hosts'
*asking* prices. It is the same cohort Vast's own dashboard (Market Stats page,
`cloud.vast.ai`) labels **"Available"**. The pricing engine never samples the
**"Rented"** cohort -- what renters are actually, successfully paying -- because
no such endpoint is wired in.

Vast's dashboard shows both series side by side. Snapshot for RTX 5090,
2026-10-21/22:

| | Available (asks) | Rented (actually paid) |
|---|---|---|
| P10 | $0.450 | $0.410 |
| Median | $0.572 | **$0.500** |
| P90 | $1.490 | **$0.700** |

Over the same window, zappa1's pricing engine was computing targets of
**$0.60-0.74 median, $0.78-0.90 p75** -- above even the *Available* side's
official numbers, let alone the *Rented* side where deals actually clear.

## Why this matters

`min(mean,p75)` / `max(median,last_success)` (see `PRICE_TARGET_STAT` and the
target-selection logic around the main pricing loop) are both computed purely
from the Available-side sample. That sample's P90 ($1.49) is inflated by a
long tail of aspirational/overpriced listings that may never actually rent.
Blending that tail into `mean`/`p75` pulls the computed target up well above
what the Rented side shows people actually pay ($0.50 median, $0.70 P90) --
likely a real contributor to the chronic-vacancy issues chased earlier this
session (see the `RATCHET_UP_WHILE_PARTIAL` / step-down / floor-clamp work in
git history around 2026-10-04 through 2026-10-05).

Supply context from the same dashboard: RTX 5090 marketplace-wide was **90.5%
rented**, only ~85 verified units available globally at that snapshot --
demand is genuinely tight, which is a separate, real signal in favor of
pricing more aggressively. The ask-vs-rented gap above is a *calibration*
problem in the target formula, not evidence that demand is weak.

## Not yet done

- Did not find/confirm the API endpoint backing Vast dashboard's "Rented"
  series. The Market Stats page has a CSV export button (`Time range` ->
  `CSV`) that may be the fastest way to get the shape of that data without
  reverse-engineering the frontend's network calls.
- No code change made yet. Next step, if pursued: either (a) wire in a
  rented-side data source and change the target formula to weight toward it,
  or (b) as a cruder stopgap, tune `MARKET_PRICE_DISCOUNT` down further so the
  Available-side sample's result lands closer to where Rented actually sits.
