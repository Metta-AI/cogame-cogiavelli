# Baseline tuning — the grid that chose the scripted constants

The two scripted baselines are load-bearing: `condottiere` is what **every** failed decision
falls back to (a bad reply, a transport error, no credentials at all), and both are fielded by
the league as fillers. Their constants are fitted here, not guessed — acceptance checklist
item 7.

## The harness

`tools/tune_baseline.nim`. Run it with

```bash
nim r --hints:off -d:release --path:src tools/tune_baseline.nim          # print both grids
nim r --hints:off -d:release --path:src tools/tune_baseline.nim --check  # non-zero unless the
                                                                        # shipped point is the argmax
```

- **Episodes**: seeded gunboat self-play, `SweepSeeds = [1, 2, 3, 4]` × `SweepYears = 3`,
  `turnDelayMs = 0`. Deterministic end to end: the same grid gives the same table on every run.
- **Fitness**: the game's own score for the candidate's seat — `(cities + min(ducats, 24) / 24) / 24`,
  or 1.0 / 0.0 on a conquest — which is exactly what the league ranks by.
- **Opponents are pinned** to `ReferenceBaseline` (`tools/tune_baseline.nim:39`), the baselines as
  the design note first stated them. They are deliberately *not* `ShippedBaseline`: pinning the
  field makes the grid a fixed target, so adopting a fitted point cannot move the post it was
  fitted to, and the tables below stay reproducible.
- **condottiere**: seat 5 plays the candidate, twice per seed — once against five reference
  bankers (the wall it has to break) and once against five reference condottieri (its own kind).
- **banker**: seat 0 plays the candidate wall against five reference condottieri.

`tests/test_tuning.nim` re-runs both sweeps in CI (debug and release) and fails unless the
constants in `src/cogiavelli/llm.nim` are still the argmax of both grids, and unless this file
still records them. `.github/workflows/ci.yml` runs the harness itself with `--check`.

## condottiere — 4 seeds × 3 years, gunboat

Swept: the treasury gate for `bribe_disband` (`BribeGrid = [9, 12, 16]`), the gate for
`bribe_buy` (`BuyGrid = [15, 20, 24]`), and the rank penalty for vacating an owned city
(`VacateGrid = [1, 2]`, Autumn always one higher).

| configuration | mean score |
|---|---|
| bribe>=9 buy>=15 vacate=1/2 **(shipped)** | 0.1816 |
| bribe>=9 buy>=20 vacate=1/2 | 0.1808 |
| bribe>=12 buy>=20 vacate=1/2 | 0.1806 |
| bribe>=12 buy>=15 vacate=1/2 | 0.1788 |
| bribe>=9 buy>=24 vacate=1/2 | 0.1782 |
| bribe>=12 buy>=24 vacate=1/2 | 0.1780 |
| bribe>=16 buy>=20 vacate=1/2 | 0.1638 |
| bribe>=16 buy>=24 vacate=1/2 | 0.1628 |
| bribe>=16 buy>=15 vacate=1/2 | 0.1610 |
| bribe>=9 buy>=15 vacate=2/3 | 0.1556 |
| bribe>=9 buy>=20 vacate=2/3 | 0.1547 |
| bribe>=12 buy>=20 vacate=2/3 | 0.1532 |
| bribe>=16 buy>=20 vacate=2/3 | 0.1528 |
| bribe>=16 buy>=15 vacate=2/3 | 0.1526 |
| bribe>=9 buy>=24 vacate=2/3 | 0.1521 |
| bribe>=16 buy>=24 vacate=2/3 | 0.1517 |
| bribe>=12 buy>=15 vacate=2/3 | 0.1515 |
| bribe>=12 buy>=24 vacate=2/3 | 0.1506 |

**Fitted: `bribeTreasury = 9`, `buyTreasury = 15`, `vacatePenalty = 1` (2 in Autumn).**

Reading: the vacate penalty is the parameter that matters — every `vacate=1/2` row beats every
`vacate=2/3` row, because a penalty of two in Autumn pins units inside cities they already own
and stops the expansion the baseline exists for. Within that, the money gates want to be as low
as the price allows: `bribe>=9` and `buy>=15` mean "buy the disband, or buy the unit, the season
you can afford it" — the gates sit exactly on the prices — and waiting costs a season of board.
A gate below the price is the same baseline, because `condottiereSpend` never writes an entry it
cannot pay for (`src/cogiavelli/llm.nim:335,357`), which is why the grid starts at 9 and 15.

## banker — 4 seeds × 3 years, gunboat

Swept: the treasury floor the wall keeps defending down to (`DefendTreasuryGrid = [10, 15, 20]`)
and the ducats per `defend` entry (`DefendAmountGrid = [2, 4, 6]`).

| configuration | mean score |
|---|---|
| defend>=10 pay=2 **(shipped)** | 0.1063 |
| defend>=15 pay=2 | 0.0916 |
| defend>=20 pay=2 | 0.0911 |
| defend>=20 pay=4 | 0.0903 |
| defend>=20 pay=6 | 0.0794 |
| defend>=15 pay=4 | 0.0786 |
| defend>=10 pay=4 | 0.0716 |
| defend>=10 pay=6 | 0.0690 |
| defend>=15 pay=6 | 0.0690 |

**Fitted: `defendTreasury = 10`, `defendAmount = 2`.**

Reading: one ducat of defence already beats a 9-ducat `bribe_disband`, so every ducat past the
first is dead money against anything that bids the list price — `pay=2` is un-bribable by the
same opponents `pay=6` is, and keeps the difference, which the score counts. Defending down to a
floor of 10 rather than 15 covers more garrisons in the seasons that decide the episode.

## The run this table came from

CI run **32731425708**, job `test`, step "Sweep the scripted baselines' parameter grid", at
`nim 2.2.4 -d:release`. `--check` in that step compares the shipped point against the grid on
every push, so this record is re-verified rather than trusted.

## What this changed

| constant | design note | fitted |
|---|---|---|
| condottiere `bribe_disband` gate | treasury ≥ 12 | treasury ≥ 9 |
| condottiere `bribe_buy` gate | treasury ≥ 20 | treasury ≥ 15 |
| condottiere vacate penalty | 1, 2 in Autumn | unchanged |
| banker `defend` floor | treasury ≥ 15 | treasury ≥ 10 |
| banker `defend` amount | 4 ducats | 2 ducats |
| banker build floor | treasury ≥ 30 | unchanged |

The prose the design note writes about both baselines — what they do, in what order, and why —
is unchanged; only these four numbers moved, and they moved because the grid said so.
`docs/plans/2026-08-24-cogiavelli-design.md` still records the figures the sweep started from.
