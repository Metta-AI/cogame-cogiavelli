## Grid harness for the scripted baselines' tunable constants.
##
## The baselines are not decoration: `condottiere` is what EVERY failed
## decision falls back to, and `banker` is the wall the league fields as a
## filler. Their constants are therefore fitted here, on seeded self-play,
## rather than guessed — acceptance checklist item 7, "the baseline's
## parameters were tuned with a grid harness".
##
##   nim r --path:src tools/tune_baseline.nim            # print both grids
##   nim r --path:src tools/tune_baseline.nim --check    # fail if the
##                                                       # shipped point is
##                                                       # not the argmax
##
## `docs/tuning.md` records the run this repo shipped from, and
## `tests/test_tuning.nim` re-runs both sweeps in CI and asserts the
## shipped constants are still the fitted ones — so the record cannot rot.

import
  std/[algorithm, os, strutils],
  cogiavelli/[sim, llm]

const
  ## The grid. Small on purpose: it runs inside the test job, and a
  ## baseline with a knife-edge optimum would be a bad baseline anyway.
  BribeGrid* = [8, 12, 16]
  BuyGrid* = [16, 20, 24]
  VacateGrid* = [1, 2]
  DefendTreasuryGrid* = [10, 15, 20]
  DefendAmountGrid* = [2, 4, 6]
  SweepSeeds* = [1, 2, 3, 4]
  SweepYears* = 3

const
  ## The fixed field every candidate is measured against: the baselines as
  ## they stood before the sweep (the design note's stated constants). It
  ## is deliberately NOT `ShippedBaseline` — pinning the opponents makes
  ## the grid a fixed target, so adopting a fitted point cannot move the
  ## post it was fitted to.
  ReferenceBaseline* = BaselineParams(
    bribeTreasury: 12,
    buyTreasury: 20,
    vacatePenalty: 1,
    autumnVacatePenalty: 2,
    defendTreasury: 15,
    defendAmount: 4,
    buildTreasury: 30
  )

type
  SweepPoint* = object
    params*: BaselineParams
    fitness*: float

proc sweepConfig(seed, years: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.years = years
  result.press = false        ## gunboat: the baselines never write anyway
  result.turnDelayMs = 0
  for index in 0 ..< 6:
    result.players.add(PlayerConfig(name: "P" & $index))
    result.tokens.add("t")
  result = sampleEpisode(result)

proc playScripted(config: GameConfig, kinds: seq[ScriptKind],
    params: seq[BaselineParams]): Sim =
  ## One whole episode of scripted self-play. Every seat's decision is
  ## computed before any of them is applied, exactly as the simultaneous
  ## batch does it.
  var sim = initSim(config)
  var guard = 0
  while not sim.done and guard < 600:
    guard.inc
    let seats = sim.pendingSeats()
    let phase = sim.phase
    var decisions: seq[Decision]
    for seat in seats:
      decisions.add(scriptedAction(sim, seat, kinds[seat], phase,
        params[seat]))
    for index, seat in seats:
      if sim.done:
        break
      let decision = decisions[index]
      if phase == phPress:
        sim.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
      else:
        sim.applyOrders(seat, decision.orders, decision.spend,
          decision.builds, decision.notes, true)
  sim

proc tableOf(candidateSeat: int, candidate: ScriptKind,
    opponent: ScriptKind, params: BaselineParams):
    tuple[kinds: seq[ScriptKind], params: seq[BaselineParams]] =
  for seat in 0 ..< 6:
    result.kinds.add(if seat == candidateSeat: candidate else: opponent)
    result.params.add(if seat == candidateSeat: params
                      else: ReferenceBaseline)

proc condottiereFitness*(params: BaselineParams): float =
  ## Seat 5 plays the candidate expander; the other five play the
  ## REFERENCE baselines. Two tables per seed — against the wall it has to
  ## break, and against its own kind — scored by the game's own score,
  ## which is what the league ranks by.
  var total = 0.0
  for seed in SweepSeeds:
    for opponent in [skBanker, skCondottiere]:
      let table = tableOf(5, skCondottiere, opponent, params)
      let sim = playScripted(sweepConfig(seed, SweepYears), table.kinds,
        table.params)
      total += sim.score(5)
  total / float(SweepSeeds.len * 2)

proc bankerFitness*(params: BaselineParams): float =
  ## Seat 0 plays the candidate wall against five reference condottieri: the
  ## wall is judged on how much of Italy and how many ducats it still has
  ## when the expanders are done with it.
  var total = 0.0
  for seed in SweepSeeds:
    let table = tableOf(0, skBanker, skCondottiere, params)
    let sim = playScripted(sweepConfig(seed, SweepYears), table.kinds,
      table.params)
    total += sim.score(0)
  total / float(SweepSeeds.len)

proc condottiereGrid*(): seq[SweepPoint] =
  for bribe in BribeGrid:
    for buy in BuyGrid:
      for vacate in VacateGrid:
        var params = ShippedBaseline
        params.bribeTreasury = bribe
        params.buyTreasury = buy
        params.vacatePenalty = vacate
        params.autumnVacatePenalty = vacate + 1
        result.add(SweepPoint(params: params,
          fitness: condottiereFitness(params)))

proc bankerGrid*(): seq[SweepPoint] =
  for treasury in DefendTreasuryGrid:
    for amount in DefendAmountGrid:
      var params = ShippedBaseline
      params.defendTreasury = treasury
      params.defendAmount = amount
      result.add(SweepPoint(params: params, fitness: bankerFitness(params)))

proc bestFitness*(points: seq[SweepPoint]): float =
  result = low(float)
  for point in points:
    if point.fitness > result:
      result = point.fitness

proc fitnessAt*(points: seq[SweepPoint], params: BaselineParams): float =
  ## The grid must contain the shipped point; that is the whole claim.
  for point in points:
    if point.params == params:
      return point.fitness
  raise newException(ValueError, "the shipped configuration is not on the grid")

proc condottiereLabel(params: BaselineParams): string =
  "bribe>=" & $params.bribeTreasury & " buy>=" & $params.buyTreasury &
    " vacate=" & $params.vacatePenalty & "/" & $params.autumnVacatePenalty

proc bankerLabel(params: BaselineParams): string =
  "defend>=" & $params.defendTreasury & " pay=" & $params.defendAmount

proc report(title: string, points: seq[SweepPoint],
    label: proc (params: BaselineParams): string {.nimcall.},
    shipped: BaselineParams): bool =
  ## Prints the whole grid, best first, and says whether the shipped point
  ## is one of the winners.
  var ranked = points
  ranked.sort(proc (a, b: SweepPoint): int = cmp(b.fitness, a.fitness))
  let best = bestFitness(points)
  let mine = fitnessAt(points, shipped)
  echo "## ", title, " (", SweepSeeds.len, " seeds x ", SweepYears,
    " years, gunboat)"
  echo "| configuration | mean score |"
  echo "|---|---|"
  for point in ranked:
    echo "| ", label(point.params),
      (if point.params == shipped: " **(shipped)**" else: ""), " | ",
      formatFloat(point.fitness, ffDecimal, 4), " |"
  echo "best ", formatFloat(best, ffDecimal, 4), ", shipped ",
    formatFloat(mine, ffDecimal, 4)
  mine >= best

when isMainModule:
  let check = "--check" in commandLineParams()
  let condottiere = report("condottiere", condottiereGrid(),
    condottiereLabel, ShippedBaseline)
  echo ""
  let banker = report("banker", bankerGrid(), bankerLabel, ShippedBaseline)
  echo ""
  if condottiere and banker:
    echo "tune_baseline: the shipped constants are the fitted ones"
  else:
    echo "tune_baseline: the shipped constants are NOT the grid optimum"
    if check:
      quit(1)
