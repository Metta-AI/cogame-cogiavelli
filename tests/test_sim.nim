## The episode: season sequencing, ownership, the end conditions, the reply
## caps (on rune boundaries), the two name spaces, event JSON round-trips
## and the replay.

import
  std/[json, strutils, unicode],
  cogiavelli/[sim, llm]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc newConfig(seed = 7, years = 2, press = true,
    names: seq[string] = @[]): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.years = years
  result.press = press
  result.turnDelayMs = 0
  let list =
    if names.len == 6: names
    else: @["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"]
  for name in list:
    result.players.add(PlayerConfig(name: name))
    result.tokens.add("t")
  result = sampleEpisode(result)

proc scriptedAll(): seq[ScriptKind] =
  for index in 0 ..< 6:
    result.add(skCondottiere)

proc playOut(config: GameConfig): Sim =
  var sim = initSim(config)
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  let kinds = scriptedAll()
  var guard = 0
  while not sim.done and guard < 400:
    guard.inc
    let seats = sim.pendingSeats()
    check(seats.len > 0, "some seat is always pending until the end")
    let phase = sim.phase
    let decisions = decideAll(client, sim, phase, seats, prompts, kinds)
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

block seasonSequencing:
  var sim = initSim(newConfig(press = true, years = 1))
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  let kinds = scriptedAll()
  var order: seq[string]
  var guard = 0
  while not sim.done and guard < 200:
    guard.inc
    order.add(seasonName(sim.season) & "/" & $sim.phase)
    let seats = sim.pendingSeats()
    let phase = sim.phase
    let decisions = decideAll(client, sim, phase, seats, prompts, kinds)
    for index, seat in seats:
      if sim.done:
        break
      if phase == phPress:
        sim.applyPress(seat, "", @[], @[], "", true)
      else:
        sim.applyOrders(seat, decisions[index].orders, decisions[index].spend,
          decisions[index].builds, "", true)
  check(order == @["SPRING/press", "SPRING/orders", "SUMMER/press",
    "SUMMER/orders", "AUTUMN/press", "AUTUMN/orders"],
    "press -> orders three times, then the year ends: " & order.join(" "))
  var winterDecisions = 0
  for step in order:
    if step.startsWith("WINTER"):
      winterDecisions.inc
  check(winterDecisions == 0, "Winter takes no decision from anybody")
  check(sim.reason == "complete", "a played-out episode is complete")

block gunboatSkipsPress:
  var sim = initSim(newConfig(press = false, years = 1))
  check(sim.phase == phOrders, "no press window in the gunboat variant")

block ownershipFlipsEverySeason:
  let sim = playOut(newConfig(seed = 3, years = 1))
  var flips = 0
  var seasons: seq[Season]
  for event in sim.events:
    if event.kind == evCities:
      var moved = false
      for row in event.gained:
        if row.len > 0:
          moved = true
      if moved:
        flips.inc
        seasons.add(event.season)
  check(flips > 0, "cities change hands")
  var beforeAutumn = false
  for season in seasons:
    if season != seAutumn:
      beforeAutumn = true
  check(beforeAutumn, "ownership flips outside Autumn too")

block conquestAtTwelve:
  var sim = initSim(newConfig(years = 4, press = false))
  ## Hand the first power twelve cities and step a season.
  let power = sim.powerOf[0]
  var taken = 0
  var units: seq[Unit]
  for slot, city in Cities:
    if taken < VictoryCities:
      sim.owner[slot] = power
      units.add(Unit(power: power, kind: ukArmy, province: city))
      taken.inc
    else:
      sim.owner[slot] = -1
  sim.board = newBoard(units)
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  let kinds = scriptedAll()
  let seats = sim.pendingSeats()
  let decisions = decideAll(client, sim, sim.phase, seats, prompts, kinds)
  for index, seat in seats:
    if sim.done:
      break
    sim.applyOrders(seat, decisions[index].orders, decisions[index].spend,
      decisions[index].builds, "", true)
  check(sim.reason == "conquest", "twelve cities ends the episode")
  check(sim.conqueror == power, "the conqueror is named")
  check(sim.score(0) == 1.0, "the conqueror scores 1.0")
  for seat in 1 ..< Seats:
    check(sim.score(seat) == 0.0, "everyone else scores 0.0")

block lastPowerStanding:
  var sim = initSim(newConfig(years = 4, press = false))
  let power = sim.powerOf[2]
  var units: seq[Unit]
  for slot in 0 ..< TotalCities:
    sim.owner[slot] = -1
  sim.owner[CityIndex[VEN]] = power
  units.add(Unit(power: power, kind: ukArmy, province: VEN))
  sim.board = newBoard(units)
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  let kinds = scriptedAll()
  let seats = sim.pendingSeats()
  let decisions = decideAll(client, sim, sim.phase, seats, prompts, kinds)
  for index, seat in seats:
    if sim.done:
      break
    sim.applyOrders(seat, decisions[index].orders, decisions[index].spend,
      decisions[index].builds, "", true)
  check(sim.reason == "conquest" and sim.conqueror == power,
    "the last power owning a city wins outright")

block deadlineScoresTheStandingBoard:
  var sim = initSim(newConfig(years = 4))
  sim.endEarly()
  check(sim.done and sim.reason == "deadline", "endEarly settles a deadline")
  let results = sim.resultsJson()
  check(results["reason"].getStr() == "deadline", "the reason is recorded")
  for seat in 0 ..< Seats:
    check(sim.cities(seat) == 3, "each power still holds its three homes")
    let expected = (3.0 + 12.0 / 24.0) / 24.0
    check(abs(sim.score(seat) - expected) < 1e-9,
      "the standing board is what is scored")

block resultsShape:
  let sim = playOut(newConfig(seed = 5, years = 1))
  let results = sim.resultsJson()
  for key in ["names", "powers", "scores", "cities", "ducats", "units",
      "spent", "received", "years", "maxYears", "conqueror", "reason"]:
    check(results.hasKey(key), "results carry " & key)
  for key in ["names", "powers", "scores", "cities", "ducats", "units",
      "spent", "received"]:
    check(results[key].len == 6, key & " has six entries")
  for score in results["scores"]:
    check(score.getFloat() >= 0.0 and score.getFloat() <= 1.0,
      "every score is in [0, 1]")
  check(results["reason"].getStr() in ["complete", "conquest", "deadline"],
    "the reason is one of the three legal values")
  var running = initSim(newConfig())
  check(running.resultsJson()["reason"].getStr() == "",
    "a running sim reports no reason yet")

block runeSafeCaps:
  var sim = initSim(newConfig())
  var long = ""
  for index in 0 ..< 900:
    long.add("\u00e9\u2014\U0001F600")
  var letters = @[Letter(fromPower: 0, toPower: 1, text: long)]
  let seat = sim.pendingSeats()[0]
  let mine = sim.powerOf[seat]
  letters[0].toPower = (mine + 1) mod Powers
  sim.applyPress(seat, long, letters, @[], long, false)
  var event: GameEvent
  for logged in sim.events:
    if logged.kind == evPress:
      event = logged
  check(event.broadcast.runeLen == MaxBroadcastLen,
    "the broadcast is cut to the cap in RUNES")
  check(validateUtf8(event.broadcast) == -1,
    "and the cut leaves valid UTF-8")
  check(event.letters[^1].text.runeLen == MaxLetterLen,
    "a letter is cut to the cap in runes")
  check(validateUtf8(event.letters[^1].text) == -1, "still valid UTF-8")
  check(event.text.runeLen == MaxNotesLen, "notes are cut to the cap")
  check(validateUtf8(event.text) == -1, "still valid UTF-8")
  check(validateUtf8($sim.tableStateJson()) == -1,
    "the whole frame is valid UTF-8")

block overLongArraysAreTruncated:
  var sim = initSim(newConfig())
  let seat = sim.pendingSeats()[0]
  let mine = sim.powerOf[seat]
  var letters: seq[Letter]
  for power in 0 ..< Powers:
    if power != mine:
      letters.add(Letter(fromPower: mine, toPower: power, text: "hello"))
  letters.add(Letter(fromPower: mine, toPower: (mine + 1) mod Powers,
    text: "again"))
  letters.add(Letter(fromPower: mine, toPower: 99, text: "nowhere"))
  var pledges: seq[Pledge]
  for index in 0 ..< 5:
    pledges.add(Pledge(fromPower: mine, toPower: (mine + 1) mod Powers,
      kind: plPeace, province: -1))
  sim.applyPress(seat, "", letters, pledges, "", false)
  var event: GameEvent
  for logged in sim.events:
    if logged.kind == evPress:
      event = logged
  var private = 0
  for letter in event.letters:
    if not letter.public:
      private.inc
  check(private == MaxLetters, "a sixth letter is dropped, got " & $private)
  check(event.pledges.len == MaxPledges, "a fifth pledge is dropped")
  var seen: seq[int]
  for letter in event.letters:
    check(letter.toPower notin seen, "a second letter to the same power goes")
    check(letter.toPower < Powers, "a letter to an unknown power goes")
    seen.add(letter.toPower)

block spendCapAndOrderCap:
  var sim = initSim(newConfig(press = false))
  let seat = sim.pendingSeats()[0]
  let mine = sim.powerOf[seat]
  var sheet: seq[SpendEntry]
  for index in 0 ..< 7:
    sheet.add(SpendEntry(power: mine, kind: spGift,
      targetPower: (mine + 1) mod Powers, targetProvince: -1, amount: 1))
  var orders: seq[string]
  for index in 0 ..< 30:
    orders.add("A VER H")
  sim.applyOrders(seat, orders, sheet, @[], "", false)
  check(sim.spends[mine].len == MaxSpendEntries,
    "a seventh spend entry is dropped")
  check(sim.rawOrders[mine].len == MaxOrders,
    "a twenty-fifth order string is dropped")

block policyNamesNeverReachAPrompt:
  let names = @["Zephyrine", "Quillbottom", "Marchbanks", "Voltaix",
    "Underhill", "Nightjar"]
  var sim = initSim(newConfig(names = names))
  for seat in 0 ..< Seats:
    let prompts = @[systemPrompt(sim, seat), pressPrompt(sim, seat, ""),
      ordersPrompt(sim, seat, "")]
    for prompt in prompts:
      for name in names:
        check(name notin prompt,
          "a policy name reached a prompt: " & name)

block eventRoundTrip:
  let sim = playOut(newConfig(seed = 9, years = 1))
  var byKind: array[EventKind, GameEvent]
  var seen: set[EventKind]
  for event in sim.events:
    if event.kind notin seen:
      seen.incl(event.kind)
      byKind[event.kind] = event
  ## The condottiere never buys a dagger, so build one by hand.
  if evAssassin notin seen:
    seen.incl(evAssassin)
    byKind[evAssassin] = GameEvent(kind: evAssassin, year: 1500,
      season: seSummer, phaseKind: phResolve, seat: -1, power: 0, target: 3,
      amount: 18, d1: 3, d2: 5, roll: 17, success: true, province: -1,
      targetPower: -1)
  for kind in EventKind:
    check(kind in seen, "the log covers " & $kind)
    let event = byKind[kind]
    let round = eventFromJson(eventToJson(event))
    check(round == event, "round trip for " & $kind)

block replayFrames:
  let sim = playOut(newConfig(seed = 11, years = 1))
  let frames = replayMatch(sim.config, sim.events)
  check(frames.len == sim.events.len + 1,
    "one frame per event prefix, got " & $frames.len)
  check($frames[^1].tableStateJson() == $sim.tableStateJson(),
    "the final frame equals the live table state")

block replayRaisesOnAnAlteredDraw:
  let sim = playOut(newConfig(seed = 13, years = 1))
  var tampered = sim.events
  for index in 0 ..< tampered.len:
    if tampered[index].kind == evFamine:
      tampered[index].provinces = @[TUR, SAV]
      break
  var raised = false
  try:
    discard replayMatch(sim.config, tampered)
  except CogiavelliError:
    raised = true
  check(raised, "replayMatch raises when a recorded draw is altered")

block replayChecksEveryRecordedBoardSnapshot:
  ## Item 2 of the acceptance checklist: the recorded per-tick state is
  ## compared with the re-derivation frame by frame, not just the dice. A
  ## tampered board snapshot must raise exactly as a tampered draw does.
  let sim = playOut(newConfig(seed = 15, years = 1))
  proc raisesWith(config: GameConfig, events: seq[GameEvent]): bool =
    try:
      discard replayMatch(config, events)
      return false
    except CogiavelliError:
      return true
  check(not raisesWith(sim.config, sim.events),
    "the untampered log replays clean")

  var movedUnit = sim.events
  var touched = false
  for index in 0 ..< movedUnit.len:
    if movedUnit[index].kind == evSeason and movedUnit[index].units.len > 0:
      movedUnit[index].units[0].province = ABR
      touched = true
      break
  check(touched, "the log carries a season board to tamper with")
  check(raisesWith(sim.config, movedUnit),
    "a moved unit in a season snapshot raises")

  var richer = sim.events
  touched = false
  for index in 0 ..< richer.len:
    if richer[index].kind == evSeason and richer[index].treasury.len > 0:
      richer[index].treasury[0] += 5
      touched = true
      break
  check(touched, "the log carries a treasury to tamper with")
  check(raisesWith(sim.config, richer),
    "an invented ducat in a season snapshot raises")

  var stolenCity = sim.events
  touched = false
  for index in 0 ..< stolenCity.len:
    if stolenCity[index].kind == evCities and stolenCity[index].owners.len > 0:
      stolenCity[index].owners[0] = (stolenCity[index].owners[0] + 1) mod Powers
      stolenCity[index].cityCounts[0] += 1
      touched = true
      break
  check(touched, "the log carries a city table to tamper with")
  check(raisesWith(sim.config, stolenCity),
    "a stolen city in a cities snapshot raises")

  var winterBoard = sim.events
  touched = false
  for index in 0 ..< winterBoard.len:
    if winterBoard[index].kind == evWinter and
        winterBoard[index].units.len > 0:
      winterBoard[index].units.delete(0)
      touched = true
      break
  check(touched, "the log carries a Winter board to tamper with")
  check(raisesWith(sim.config, winterBoard),
    "a vanished unit in a Winter snapshot raises")

  var shortRebellions = sim.events
  touched = false
  for index in 0 ..< shortRebellions.len:
    if shortRebellions[index].kind == evWinter:
      if shortRebellions[index].rebellions.len > 0:
        shortRebellions[index].rebellions.delete(0)
      else:
        shortRebellions[index].rebellions.add(
          Rebellion(city: Cities[0], power: 0, roll: RebellionFace))
      touched = true
      break
  check(touched, "the log carries a Winter event to tamper with")
  check(raisesWith(sim.config, shortRebellions),
    "a rebellion-roll list of a different length raises too")

block seedDeterminism:
  let one = initSim(newConfig(seed = 21))
  let two = initSim(newConfig(seed = 21))
  check(one.powerOf == two.powerOf, "the same seed gives the same powers")
  check(one.names == two.names, "and the same aliases")
  let a = playOut(newConfig(seed = 21, years = 1))
  let b = playOut(newConfig(seed = 21, years = 1))
  check(a.events.len == b.events.len, "the same seed gives the same log")
  for index in 0 ..< a.events.len:
    check($a.events[index].eventToJson() == $b.events[index].eventToJson(),
      "byte-identical event logs")

block retreatRules:
  ## Never to the attacker's origin, a standoff province, or an occupied
  ## one; two dislodged units contesting one destination are settled by
  ## ascending province code.
  var sim = initSim(newConfig(press = false, years = 4))
  var units = @[
    Unit(power: sim.powerOf[0], kind: ukArmy, province: ANC),
    Unit(power: sim.powerOf[1], kind: ukArmy, province: URB),
    Unit(power: sim.powerOf[1], kind: ukArmy, province: PER),
    Unit(power: sim.powerOf[2], kind: ukArmy, province: SIE),
    Unit(power: sim.powerOf[3], kind: ukArmy, province: FLO)
  ]
  sim.board = newBoard(units)
  var byPower: array[Powers, seq[string]]
  byPower[sim.powerOf[1]] = @["A URB - ANC", "A PER S A URB - ANC"]
  byPower[sim.powerOf[0]] = @["A ANC H"]
  byPower[sim.powerOf[2]] = @["A SIE H"]
  byPower[sim.powerOf[3]] = @["A FLO H"]
  let seats = sim.pendingSeats()
  for seat in seats:
    if sim.done:
      break
    sim.applyOrders(seat, byPower[sim.powerOf[seat]], @[], @[], "", true)
  var retreat = Retreat(unit: -1, to: -1)
  for event in sim.events:
    if event.kind == evBattle and event.retreats.len > 0:
      retreat = event.retreats[0]
  check(retreat.unit == ANC, "the dislodged unit is the one in Ancona")
  check(retreat.to != URB, "a retreat never goes to the attacker's origin")
  check(retreat.to != PER, "nor to an occupied province")
  check(retreat.to == ABR, "it takes the legal destination nearest home")

block pledgeStabsAreJudgedOnTheBoardTheOrdersWereWrittenOn:
  ## design.md:388 — peace is broken when the orders MOVE a unit into a
  ## province occupied by the pledgee's unit. A stab that succeeds emptied
  ## that province by the time the movement is applied, so judging it on
  ## the post-movement board would stamp only the ones that bounced.
  var sim = initSim(newConfig(press = true, years = 4))
  let pledger = sim.powerOf[0]
  let victim = sim.powerOf[1]
  sim.board = newBoard(@[
    Unit(power: pledger, kind: ukArmy, province: VER),
    Unit(power: pledger, kind: ukArmy, province: MOD),
    Unit(power: victim, kind: ukArmy, province: MAN)
  ])
  check(not isCity(MAN), "Mantua is not a city, so only the unit can be seen")
  for seat in sim.pendingSeats():
    if seat == 0:
      sim.applyPress(seat, "", @[],
        @[Pledge(fromPower: pledger, toPower: victim, kind: plPeace,
          province: -1)], "", true)
    else:
      sim.applyPress(seat, "", @[], @[], "", true)
  check(sim.phase == phOrders, "the press window closed")
  for seat in sim.pendingSeats():
    if sim.done:
      break
    case seat
    of 0:
      sim.applyOrders(seat, @["A VER - MAN", "A MOD S A VER - MAN"], @[], @[],
        "", true)
    of 1:
      sim.applyOrders(seat, @["A MAN H"], @[], @[], "", true)
    else:
      sim.applyOrders(seat, @[], @[], @[], "", true)
  var battle: GameEvent
  for event in sim.events:
    if event.kind == evBattle:
      battle = event
  check(battle.dislodged.len == 1 and battle.dislodged[0].unit == MAN,
    "the supported move dislodged the pledgee's army in Mantua")
  check(battle.stabs.len == 1, "the broken peace is stamped exactly once, got " &
    $battle.stabs.len)
  check(battle.stabs[0].power == pledger and battle.stabs[0].kind == plPeace,
    "and it names the pledger and the pledge it broke")
  check(battle.stabs[0].pledgeTo == victim, "and who was stabbed")

echo "test_sim: ok"
