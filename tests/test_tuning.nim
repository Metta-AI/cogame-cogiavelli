## The scripted baselines' constants are the grid's, not somebody's taste.
##
## Acceptance checklist item 7: "the baseline's parameters were tuned with a
## grid harness, not guessed". This test re-runs both sweeps in CI and fails
## unless `ShippedBaseline` is still the argmax of both, and unless
## `docs/tuning.md` still records the same point — so neither the constants
## nor the record can drift without the other.

import
  std/[os, strutils],
  cogiavelli/[sim, llm],
  ../tools/tune_baseline

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc repoDir(): string =
  currentSourcePath().parentDir().parentDir()

block theShippedCondottiereIsTheFittedOne:
  let grid = condottiereGrid()
  check(grid.len == BribeGrid.len * BuyGrid.len * VacateGrid.len,
    "the whole grid was swept, got " & $grid.len & " points")
  let best = bestFitness(grid)
  let shipped = grid.fitnessAt(ShippedBaseline)
  check(shipped >= best,
    "the shipped condottiere is not the fitted one: shipped " &
      formatFloat(shipped, ffDecimal, 4) & " vs best " &
      formatFloat(best, ffDecimal, 4) &
      " (re-run tools/tune_baseline.nim and update docs/tuning.md)")

block theShippedBankerIsTheFittedOne:
  let grid = bankerGrid()
  check(grid.len == DefendTreasuryGrid.len * DefendAmountGrid.len,
    "the whole grid was swept, got " & $grid.len & " points")
  let best = bestFitness(grid)
  let shipped = grid.fitnessAt(ShippedBaseline)
  check(shipped >= best,
    "the shipped banker is not the fitted one: shipped " &
      formatFloat(shipped, ffDecimal, 4) & " vs best " &
      formatFloat(best, ffDecimal, 4) &
      " (re-run tools/tune_baseline.nim and update docs/tuning.md)")

block theRecordMatchesTheConstants:
  let record = readFile(repoDir() / "docs" / "tuning.md")
  let condottiere = "bribe>=" & $ShippedBaseline.bribeTreasury & " buy>=" &
    $ShippedBaseline.buyTreasury & " vacate=" &
    $ShippedBaseline.vacatePenalty & "/" &
    $ShippedBaseline.autumnVacatePenalty & " **(shipped)**"
  let banker = "defend>=" & $ShippedBaseline.defendTreasury & " pay=" &
    $ShippedBaseline.defendAmount & " **(shipped)**"
  check(condottiere in record,
    "docs/tuning.md does not record the shipped condottiere: " & condottiere)
  check(banker in record,
    "docs/tuning.md does not record the shipped banker: " & banker)

echo "test_tuning: ok"
