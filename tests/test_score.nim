## Scoring: city share plus a treasury term worth at most one city, over
## the constant 24 — and 1.0 / 0.0 on a conquest.

import std/json, cogiavelli/sim

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc fixture(cities: array[6, int], ducats: array[6, int]): Sim =
  var config = defaultGameConfig()
  config.seed = 7
  config.years = 4
  config.turnDelayMs = 0
  for index in 0 ..< 6:
    config.players.add(PlayerConfig(name: "P" & $index))
    config.tokens.add("t")
  result = initSim(sampleEpisode(config))
  for slot in 0 ..< TotalCities:
    result.owner[slot] = -1
  var slot = 0
  for seat in 0 ..< Seats:
    let power = result.powerOf[seat]
    result.treasury[power] = ducats[seat]
    for count in 0 ..< cities[seat]:
      result.owner[slot] = power
      slot.inc
  result.board = newBoard(@[])

block formula:
  ## Six powers, three cities each, six neutrals: an unclaimed neutral
  ## dilutes everybody equally.
  let sim = fixture([3, 3, 3, 3, 3, 3], [0, 0, 0, 0, 0, 0])
  for seat in 0 ..< Seats:
    check(abs(sim.score(seat) - 3.0 / 24.0) < 1e-12,
      "three of twenty-four is 0.125 regardless of the neutrals")

block treasuryTerm:
  let none = fixture([4, 4, 4, 4, 4, 4], [0, 0, 0, 0, 0, 0])
  let full = fixture([4, 4, 4, 4, 4, 4], [24, 24, 24, 24, 24, 24])
  let over = fixture([4, 4, 4, 4, 4, 4], [48, 48, 48, 48, 48, 48])
  check(abs(full.score(0) - none.score(0) - 1.0 / 24.0) < 1e-12,
    "24 ducats is worth exactly one city")
  check(abs(over.score(0) - full.score(0)) < 1e-12,
    "48 ducats is still worth exactly one city")
  check(none.score(0) < full.score(0), "money is worth something")

block conquest:
  var sim = fixture([12, 3, 3, 3, 2, 1], [30, 30, 30, 30, 30, 30])
  sim.conqueror = sim.powerOf[0]
  sim.reason = "conquest"
  sim.done = true
  check(sim.score(0) == 1.0, "conquest at exactly twelve scores 1.0")
  for seat in 1 ..< Seats:
    check(sim.score(seat) == 0.0, "and every other seat scores 0.0")

block eliminated:
  let sim = fixture([0, 5, 5, 5, 5, 4], [12, 0, 0, 0, 0, 0])
  check(abs(sim.score(0) - (12.0 / 24.0) / 24.0) < 1e-12,
    "an eliminated power scores its treasury term only")
  check(sim.score(0) > 0.0, "the vault still counts")

block deadlineInTheFirstSpring:
  var config = defaultGameConfig()
  config.seed = 7
  config.years = 4
  config.turnDelayMs = 0
  for index in 0 ..< 6:
    config.players.add(PlayerConfig(name: "P" & $index))
    config.tokens.add("t")
  var sim = initSim(sampleEpisode(config))
  sim.endEarly()
  let expected = (3.0 + 12.0 / 24.0) / 24.0
  for seat in 0 ..< Seats:
    check(abs(sim.score(seat) - expected) < 1e-12,
      "a first-Spring deadline scores three home cities and twelve ducats")
  check(sim.resultsJson()["reason"].getStr() == "deadline",
    "and it is a legitimate, scoreable episode")

block boundedRange:
  ## The conquest branch means a scored board never holds more than eleven
  ## cities, but the clamp holds for every value anyway.
  for cities in 0 .. 24:
    var counts: array[6, int]
    counts[0] = cities
    let sim = fixture(counts, [999, 0, 0, 0, 0, 0])
    let score = sim.score(0)
    check(score >= 0.0 and score <= 1.0,
      "every score is in [0, 1] at " & $cities & " cities")

echo "test_score: ok"
