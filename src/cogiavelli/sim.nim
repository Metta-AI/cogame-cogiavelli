## Pure game rules for Cogiavelli. No IO, no networking, no LLM — the
## server, the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat->power permutation and cog
## aliases, the board, the six treasuries, the live season's press, orders
## and expenditure sheets, the whole-episode ledger, and the append-only
## event log. Everything random comes from ONE seeded shock stream whose
## every draw is written into the event that consumed it, so `replayMatch`
## re-derives the stream and raises if a recorded draw disagrees.

import
  std/[algorithm, json, math, random, sequtils, strutils, unicode],
  types, orders, adjudicate, money

export types, orders, adjudicate, money

const
  Seats* = 6
  Powers* = 6
  VictoryCities* = 12
  MinYears* = 1
  MaxYears* = 10
  StartYear* = 1499
  SeasonsPerYear* = 3
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  MaxBroadcastLen* = 400
  MaxLetterLen* = 400
  MaxLetters* = 5
  MaxPledges* = 4
  MaxNotesLen* = 800
  MaxOrderLen* = 40
  MaxOrders* = 24
  MaxSpendEntries* = 6
  MaxBuilds* = 6
  MaxBuildLen* = 24
  MaxTargetLen* = 24
  ## Anonymous table aliases, babel's pool kept verbatim.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  TurnRecord* = object
    year*: int
    season*: Season
    orders*: array[Powers, seq[string]]
    outcomes*: array[Powers, seq[OrderOutcome]]
    spends*: array[Powers, seq[SpendEntry]]

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous cog alias per seat
    powerOf*: array[Seats, int]      ## seat -> power index
    seatOf*: array[Powers, int]      ## power index -> seat
    board*: Board
    owner*: array[TotalCities, int]  ## city slot -> power, -1 neutral
    treasury*: Treasury
    year*: int
    season*: Season
    phase*: PhaseKind
    pending*: array[Seats, bool]
    famine*: seq[int]                ## this year's two famine provinces
    plagueCity*: int                 ## this year's plague province, -1 if none
    paralysed*: array[Powers, bool]  ## court frozen for this season's movement
    pressBlocked*: array[Powers, bool] ## silenced in the next press window
    press*: seq[Letter]              ## this window
    pressLast*: seq[Letter]          ## the previous window
    pledges*: seq[Pledge]            ## this season's pledges
    broadcasts*: array[Powers, string]
    rawOrders*: array[Powers, seq[string]]
    spends*: array[Powers, seq[SpendEntry]]
    builds*: array[Powers, seq[string]]
    lastAdjudication*: Adjudication
    lastBribes*: seq[BribeResult]
    lastDaggers*: seq[AssassinResult]
    lastRetreats*: seq[Retreat]
    lastStabs*: seq[Stab]
    lastRebellions*: seq[Rebellion]
    stabbedThisTurn*: array[Powers, bool]
    ledger*: seq[SpendEntry]         ## whole episode, for the endcard
    spent*: array[Powers, int]
    received*: array[Powers, int]
    history*: seq[TurnRecord]
    cityHistory*: seq[array[Powers, int]]
    treasuryHistory*: seq[array[Powers, int]]
    notes*: seq[string]
    eliminated*: array[Powers, bool]
    scripted*: array[Powers, bool]   ## the live phase's decision provenance
    shockRng*: Rand
    yearsPlayed*: int
    done*: bool
    reason*: string                  ## conquest | complete | deadline
    conqueror*: int                  ## power index, -1 when none
    events*: seq[GameEvent]

# ---- Small helpers ----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Every recorded string is cut at a RUNE boundary with the cut marked,
  ## so a byte slice can never leave invalid UTF-8 in the replay.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc powerIndex*(name: string): int =
  let key = name.strip().toUpperAscii()
  if key.len == 0:
    return -1
  if key == "ALL" or key == "EVERYONE":
    return -1
  for index, power in PowerNames:
    if key == power:
      return index
  ## "THE PAPACY", "THE TURK", adjectives.
  for index, power in PowerAdjectives:
    if key == power.toUpperAscii():
      return index
  for index, power in PowerNames:
    if key == "THE " & power:
      return index
  -1

proc seasonName*(season: Season): string =
  case season
  of seSpring: "SPRING"
  of seSummer: "SUMMER"
  of seAutumn: "AUTUMN"
  of seWinter: "WINTER"

proc seasonIndex*(year: int, season: Season): int =
  (year - StartYear) * 4 + ord(season)

proc cityCounts*(sim: Sim): array[Powers, int] =
  for slot in 0 ..< TotalCities:
    if sim.owner[slot] >= 0:
      result[sim.owner[slot]].inc

proc unitCounts*(sim: Sim): array[Powers, int] =
  for unit in sim.board.units:
    result[unit.power].inc

proc citiesOf*(sim: Sim, power: int): int =
  for slot in 0 ..< TotalCities:
    if sim.owner[slot] == power:
      result.inc

proc ownedCities*(sim: Sim, power: int): seq[int] =
  for slot, city in Cities:
    if sim.owner[slot] == power:
      result.add(city)

proc cities*(sim: Sim, seat: int): int =
  sim.citiesOf(sim.powerOf[seat])

proc score*(sim: Sim, seat: int): float =
  ## Conquest is 1.0 / 0.0; otherwise city share plus a treasury term worth
  ## at most one city, over the constant 24.
  let power = sim.powerOf[seat]
  if sim.reason == "conquest":
    return (if sim.conqueror == power: 1.0 else: 0.0)
  let ducats = min(sim.treasury[power], TotalCities)
  ## The conquest check fires at 12 cities, so the share term never gets
  ## past 11/24 without the branch above; the clamp is the belt that keeps
  ## `results.scores` inside the [0, 1] the results schema declares.
  min((sim.citiesOf(power).float + ducats.float / TotalCities.float) /
    TotalCities.float, 1.0)

proc livePowers*(sim: Sim): seq[int] =
  for power in 0 ..< Powers:
    if not sim.eliminated[power]:
      result.add(power)

proc pendingSeats*(sim: Sim): seq[int] =
  for seat in 0 ..< Seats:
    if sim.pending[seat]:
      result.add(seat)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the year count into the episode budget and divides the pacing
  ## delay into `PacingBudgetMs`. Idempotent: a config that already carries
  ## the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.years = clamp(config.years, MinYears, MaxYears)
  result.turnDelayMs = min(config.turnDelayMs,
    PacingBudgetMs div max(result.years * SeasonsPerYear * 3, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(sim: Sim, kind: EventKind): GameEvent =
  GameEvent(kind: kind, year: sim.year, season: sim.season,
    phaseKind: sim.phase, seat: -1, power: -1, province: -1, target: -1,
    targetPower: -1)

proc boardUnits(sim: Sim): seq[Unit] =
  sim.board.units

proc ownerList(sim: Sim): seq[int] =
  for slot in 0 ..< TotalCities:
    result.add(sim.owner[slot])

proc treasuryList(sim: Sim): seq[int] =
  for power in 0 ..< Powers:
    result.add(sim.treasury[power])

proc countList(sim: Sim): seq[int] =
  let counts = sim.cityCounts()
  for power in 0 ..< Powers:
    result.add(counts[power])

proc beginSeason*(sim: var Sim)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(CogiavelliError,
      "cogiavelli needs exactly " & $Seats & " players")
  if config.years < MinYears:
    raise newException(CogiavelliError,
      "years must be at least " & $MinYears)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for what the seed decides at setup: the seat->power
  ## permutation and the aliases. The shock stream is separate.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var permutation = toSeq(0 ..< Powers)
  rng.shuffle(permutation)
  for seat in 0 ..< Seats:
    result.powerOf[seat] = permutation[seat]
    result.seatOf[permutation[seat]] = seat
  result.shockRng = initRand(int64(config.seed) * 104729 + 7)
  var units: seq[Unit]
  for start in StartUnits:
    units.add(Unit(power: start.power,
      kind: (if start.fleet: ukFleet else: ukArmy), province: start.province))
  result.board = newBoard(units)
  for slot, city in Cities:
    result.owner[slot] = Provinces[city].homePower
  for power in 0 ..< Powers:
    result.treasury[power] = StartTreasury
  result.year = StartYear
  result.season = seSpring
  result.phase = phPress
  result.plagueCity = -1
  result.conqueror = -1
  result.notes = newSeq[string](Seats)
  var event = result.blankEvent(evStart)
  event.units = result.boardUnits()
  event.owners = result.ownerList()
  event.treasury = result.treasuryList()
  event.seed = config.seed
  for seat in 0 ..< Seats:
    event.orders.add(PowerNames[result.powerOf[seat]])
  result.addEvent(event)
  ## The first season opens immediately: the start event is followed by
  ## the Spring famine draw and the season frame, exactly as a replay
  ## re-derives them.
  result.beginSeason()

# ---- Season machinery -------------------------------------------------------

proc emitSeasonEvent(sim: var Sim) =
  var event = sim.blankEvent(evSeason)
  event.units = sim.boardUnits()
  event.owners = sim.ownerList()
  event.treasury = sim.treasuryList()
  event.cityCounts = sim.countList()
  sim.addEvent(event)

proc openOrdersPhase(sim: var Sim) =
  sim.phase = phOrders
  for seat in 0 ..< Seats:
    sim.pending[seat] = not sim.eliminated[sim.powerOf[seat]]
  sim.emitSeasonEvent()

proc beginSeason*(sim: var Sim) =
  ## Step 1 (Spring famine) then step 2's window, or straight to step 3
  ## when the variant plays gunboat.
  if sim.done:
    return
  sim.pressLast = sim.press
  sim.press = @[]
  sim.pledges = @[]
  for power in 0 ..< Powers:
    sim.broadcasts[power] = ""
    sim.rawOrders[power] = @[]
    sim.spends[power] = @[]
    sim.stabbedThisTurn[power] = false
    sim.paralysed[power] = false
  if sim.season == seSpring:
    sim.famine = @[]
    sim.plagueCity = -1
    var land: seq[int]
    for province in 0 ..< NumLand:
      land.add(province)
    ## EXACTLY FamineProvinces draws, as design.md:294-296 specifies the
    ## shock stream: draw without replacement instead of rejecting
    ## collisions, so the stream advances by a fixed, auditable count.
    for _ in 0 ..< FamineProvinces:
      let index = sim.shockRng.rand(land.high)
      sim.famine.add(land[index])
      land.delete(index)
    var event = sim.blankEvent(evFamine)
    event.phaseKind = phPress
    event.provinces = sim.famine
    sim.addEvent(event)
  if sim.config.press:
    sim.phase = phPress
    for seat in 0 ..< Seats:
      let power = sim.powerOf[seat]
      sim.pending[seat] = not sim.eliminated[power] and
        not sim.pressBlocked[power]
    for power in 0 ..< Powers:
      sim.pressBlocked[power] = false
    if sim.pendingSeats().len > 0:
      sim.emitSeasonEvent()
      return
    sim.openOrdersPhase()
  else:
    for power in 0 ..< Powers:
      sim.pressBlocked[power] = false
    sim.openOrdersPhase()

proc settle(sim: var Sim, reason: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  for seat in 0 ..< Seats:
    sim.pending[seat] = false
  var event = sim.blankEvent(evEnd)
  event.text = reason
  event.cities = sim.countList()
  event.treasury = sim.treasuryList()
  event.conqueror = (if sim.conqueror >= 0: PowerNames[sim.conqueror] else: "")
  sim.addEvent(event)

proc endEarly*(sim: var Sim) =
  ## Stop now. The platform keeps NOTHING from an episode that overruns, so
  ## a short honest episode always beats a long one that never lands.
  sim.settle("deadline")

# ---- Press ------------------------------------------------------------------

proc pledgeVisible*(sim: Sim, pledge: Pledge, power: int): bool =
  pledge.toPower < 0 or pledge.toPower == power or pledge.fromPower == power

proc applyPress*(sim: var Sim, seat: int, broadcast: string,
    letters: seq[Letter], pledges: seq[Pledge], notes: string,
    scripted: bool) =
  if sim.done:
    raise newException(CogiavelliError, "the episode is over")
  if sim.phase != phPress:
    raise newException(CogiavelliError, "no press window is open")
  if seat < 0 or seat >= Seats or not sim.pending[seat]:
    raise newException(CogiavelliError, "seat " & $seat & " is not pending")
  let power = sim.powerOf[seat]
  var event = sim.blankEvent(evPress)
  event.seat = seat
  event.power = power
  event.scripted = scripted
  event.broadcast = cleanText(broadcast, MaxBroadcastLen)
  sim.broadcasts[power] = event.broadcast
  if event.broadcast.len > 0:
    sim.press.add(Letter(fromPower: power, toPower: -1,
      text: event.broadcast, public: true))
    event.letters.add(Letter(fromPower: power, toPower: -1,
      text: event.broadcast, public: true))
  var written: seq[int]
  for letter in letters:
    if event.letters.len >= MaxLetters + 1:
      break
    if letter.toPower < 0 or letter.toPower >= Powers or
        letter.toPower == power:
      continue
    if letter.toPower in written:
      continue
    written.add(letter.toPower)
    let record = Letter(fromPower: power, toPower: letter.toPower,
      text: cleanText(letter.text, MaxLetterLen), public: false)
    sim.press.add(record)
    event.letters.add(record)
  for pledge in pledges:
    if event.pledges.len >= MaxPledges:
      break
    if pledge.kind == plKeepout:
      if pledge.province < 0 or pledge.province >= NumLand:
        continue
    elif pledge.toPower < 0 or pledge.toPower >= Powers or
        pledge.toPower == power:
      continue
    let record = Pledge(fromPower: power, toPower: pledge.toPower,
      kind: pledge.kind, province: pledge.province)
    sim.pledges.add(record)
    event.pledges.add(record)
  let cleaned = cleanText(notes, MaxNotesLen)
  if cleaned.len > 0:
    sim.notes[seat] = cleaned
  event.text = sim.notes[seat]
  sim.addEvent(event)
  sim.pending[seat] = false
  if sim.pendingSeats().len == 0:
    sim.openOrdersPhase()

# ---- Orders -----------------------------------------------------------------

proc normaliseOrders(sim: Sim, power: int, raws: seq[string]):
    tuple[good: seq[Order], illegalRaw, illegalWhy: seq[string]] =
  ## Parse + legality against the live board, with one order per unit and
  ## a hold for anything illegal or missing.
  var claimed: array[NumAreas, bool]
  for raw in raws:
    var order = parseOrder(sim.board, power, raw)
    checkLegality(sim.board, order)
    if not order.illegal and order.unit >= 0 and claimed[order.unit]:
      order.illegal = true
      order.why = "notowned"
    if order.illegal:
      result.illegalRaw.add(cleanText(raw, MaxOrderLen))
      result.illegalWhy.add(order.why)
      continue
    claimed[order.unit] = true
    result.good.add(order)
  for unit in sim.board.units:
    if unit.power == power and not claimed[unit.province]:
      result.good.add(blankOrder(power, unit.province))

proc conquestCheck(sim: var Sim) =
  let counts = sim.cityCounts()
  var leader = -1
  var holders = 0
  for power in 0 ..< Powers:
    if counts[power] >= VictoryCities:
      leader = power
    if counts[power] > 0:
      holders.inc
  if leader < 0 and holders == 1:
    for power in 0 ..< Powers:
      if counts[power] > 0:
        leader = power
  if leader >= 0:
    sim.conqueror = leader
    sim.settle("conquest")

proc updateCities(sim: var Sim) =
  ## Step 10: whoever occupies a city owns it, immediately, every season.
  var gained: seq[seq[int]]
  var lost: seq[seq[int]]
  for power in 0 ..< Powers:
    gained.add(@[])
    lost.add(@[])
  for slot, city in Cities:
    if not sim.board.hasUnit(city):
      continue
    let taker = sim.board.unitAt(city).power
    if sim.owner[slot] == taker:
      continue
    if sim.owner[slot] >= 0:
      lost[sim.owner[slot]].add(city)
    gained[taker].add(city)
    sim.owner[slot] = taker
  var event = sim.blankEvent(evCities)
  event.phaseKind = phResolve
  event.owners = sim.ownerList()
  event.cityCounts = sim.countList()
  event.gained = gained
  event.lost = lost
  sim.addEvent(event)
  sim.conquestCheck()

proc runRetreats(sim: var Sim) =
  ## Applies the successful moves, then step 9: retreats are decided by
  ## rule, never by a decision call.
  sim.lastRetreats = @[]
  var barred: array[NumAreas, bool]
  for province in sim.lastAdjudication.standoffs:
    barred[province] = true
  var units = sim.board.units
  ## Apply successful moves first so "empty after movement" is true.
  var moving: array[NumAreas, int]
  for index in 0 ..< NumAreas:
    moving[index] = -1
  for move in sim.lastAdjudication.moved:
    moving[move.unit] = move.dest
  var survivors: seq[Unit]
  var dislodgedUnits: seq[Unit]
  var attackers: array[NumAreas, int]
  for index in 0 ..< NumAreas:
    attackers[index] = -1
  for hit in sim.lastAdjudication.dislodged:
    attackers[hit.unit] = hit.attackerFrom
  for unit in units:
    if moving[unit.province] >= 0:
      var moved = unit
      moved.province = moving[unit.province]
      survivors.add(moved)
    elif attackers[unit.province] >= 0:
      dislodgedUnits.add(unit)
    else:
      survivors.add(unit)
  var occupied: array[NumAreas, bool]
  for unit in survivors:
    occupied[unit.province] = true
  dislodgedUnits.sort(proc (a, b: Unit): int =
    cmp(Provinces[a.province].code, Provinces[b.province].code))
  for unit in dislodgedUnits:
    let ownCities = sim.ownedCities(unit.power)
    var options: seq[int]
    let graph = if unit.kind == ukFleet: FleetAdj[unit.province]
                else: ArmyAdj[unit.province]
    for dest in graph:
      if occupied[dest] or barred[dest]:
        continue
      if dest == attackers[unit.province]:
        continue
      options.add(dest)
    options.sortByCode()
    var best = -1
    var bestDistance = high(int)
    for dest in options:
      var probe = unit
      probe.province = dest
      let distance = distanceToOwnCity(sim.board, probe, ownCities)
      if distance < bestDistance:
        bestDistance = distance
        best = dest
    if best < 0:
      sim.lastRetreats.add(Retreat(unit: unit.province, to: -1))
    else:
      sim.lastRetreats.add(Retreat(unit: unit.province, to: best))
      occupied[best] = true
      var moved = unit
      moved.province = best
      survivors.add(moved)
  sim.board = newBoard(survivors)

proc pledgeStabs(sim: var Sim, board: Board): seq[Stab] =
  ## A pledge is the only promise spectators can watch you break. It is
  ## judged on the orders as they were WRITTEN, against the board they were
  ## written on — the pre-movement board — so a stab that succeeds is
  ## stamped exactly like one that bounces.
  for pledge in sim.pledges:
    var offence = ""
    case pledge.kind
    of plPeace:
      let victim = pledge.toPower
      for entry in sim.spends[pledge.fromPower]:
        if not entry.applied:
          continue
        if entry.kind in {spBribeDisband, spBribeBuy} and
            entry.targetPower == victim:
          offence = "pays " & $entry.amount & " against " &
            PowerLongNames[victim]
        elif entry.kind == spAssassinate and entry.targetPower == victim:
          offence = "sends a dagger at " & PowerLongNames[victim]
      for order in sim.lastAdjudication.results:
        if order.power != pledge.fromPower:
          continue
        var into = -1
        if order.kind == okMove: into = order.target
        elif order.kind == okSupportMove: into = order.auxTo
        if into < 0:
          continue
        let hostile =
          (board.hasUnit(into) and board.unitAt(into).power == victim) or
          (isCity(into) and sim.owner[CityIndex[into]] == victim)
        if hostile:
          offence = order.text
    of plKeepout:
      for order in sim.lastAdjudication.results:
        if order.power != pledge.fromPower:
          continue
        if (order.kind == okMove and order.target == pledge.province) or
            (order.kind == okSupportMove and order.auxTo == pledge.province):
          offence = order.text
    of plSupport:
      var supported = false
      for order in sim.lastAdjudication.results:
        if order.power != pledge.fromPower:
          continue
        if order.kind notin {okSupportHold, okSupportMove}:
          continue
        if order.auxFrom >= 0 and board.hasUnit(order.auxFrom) and
            board.unitAt(order.auxFrom).power == pledge.toPower:
          supported = true
      if not supported:
        offence = "supported no " & PowerAdjectives[max(pledge.toPower, 0)] &
          " unit"
    if offence.len > 0:
      sim.stabbedThisTurn[pledge.fromPower] = true
      result.add(Stab(power: pledge.fromPower, pledgeTo: pledge.toPower,
        kind: pledge.kind, province: pledge.province, order: offence))

proc runWinter(sim: var Sim) =
  ## W1..W5, one event carrying every roll, casualty, ducat and build.
  var event = sim.blankEvent(evWinter)
  event.season = seWinter
  event.phaseKind = phWinter
  event.rebellions = runRebellions(sim.owner, sim.board, sim.shockRng)
  sim.lastRebellions = event.rebellions
  event.famineKills = strikeFamine(sim.board, sim.famine)
  var barren = sim.famine
  if sim.plagueCity >= 0:
    barren.add(sim.plagueCity)
  let collected = collectIncome(sim.owner, barren, sim.treasury, sim.shockRng)
  for power in 0 ..< Powers:
    event.income.add(collected.income[power])
    event.incomeDraws.add(collected.draws[power])
  let upkeep = payUpkeep(sim.board, sim.owner, sim.treasury)
  for power in 0 ..< Powers:
    event.upkeep.add(upkeep.paid[power])
  event.upkeepDisbands = upkeep.disbanded
  for power in 0 ..< Powers:
    if sim.eliminated[power]:
      continue
    for record in runBuilds(sim.board, sim.owner, sim.treasury, power,
        sim.builds[power]):
      event.builds.add(record)
  event.units = sim.boardUnits()
  event.owners = sim.ownerList()
  event.treasury = sim.treasuryList()
  event.cityCounts = sim.countList()
  sim.addEvent(event)
  for power in 0 ..< Powers:
    sim.builds[power] = @[]
  let counts = sim.cityCounts()
  let units = sim.unitCounts()
  for power in 0 ..< Powers:
    if counts[power] == 0 and units[power] == 0:
      sim.eliminated[power] = true

proc advanceSeason(sim: var Sim) =
  ## Step 12, plus Winter once per year after Autumn.
  case sim.season
  of seSpring:
    sim.season = seSummer
  of seSummer:
    sim.season = seAutumn
  of seAutumn, seWinter:
    sim.runWinter()
    if sim.done:
      return
    sim.yearsPlayed.inc
    sim.conquestCheck()
    if sim.done:
      return
    if sim.yearsPlayed >= sim.config.years:
      sim.settle("complete")
      return
    sim.year.inc
    sim.season = seSpring
  sim.beginSeason()

proc resolveSeason(sim: var Sim) =
  ## Steps 4 through 12.
  sim.phase = phResolve

  ## Step 4 — payment, in power-index order, entries in the order written.
  for power in 0 ..< Powers:
    if sim.spends[power].len == 0:
      continue
    validateSpend(sim.board, sim.treasury, power, sim.spends[power])
    var event = sim.blankEvent(evSpend)
    event.seat = sim.seatOf[power]
    event.power = power
    event.entries = sim.spends[power]
    event.treasuryAfter = sim.treasury[power]
    sim.addEvent(event)
    for entry in sim.spends[power]:
      if not entry.applied:
        continue
      sim.spent[power] += entry.amount
      if entry.kind == spGift:
        sim.received[entry.targetPower] += entry.amount
      sim.ledger.add(entry)

  ## Step 5 — assassination, ascending power index of the payer.
  var attempts: seq[SpendEntry]
  for power in 0 ..< Powers:
    for entry in sim.spends[power]:
      if entry.applied and entry.kind == spAssassinate:
        attempts.add(entry)
  sim.lastDaggers = resolveAssassinations(attempts, sim.shockRng)
  for dagger in sim.lastDaggers:
    var event = sim.blankEvent(evAssassin)
    event.power = dagger.power
    event.target = dagger.target
    event.amount = dagger.amount
    event.d1 = dagger.d1
    event.d2 = dagger.d2
    event.roll = dagger.roll
    event.success = dagger.success
    sim.addEvent(event)
    if dagger.success:
      sim.paralysed[dagger.target] = true
      sim.pressBlocked[dagger.target] = true

  ## Step 6 — bribes, all at once against the amounts paid in step 4.
  var allEntries: seq[SpendEntry]
  for power in 0 ..< Powers:
    allEntries.add(sim.spends[power])
  sim.lastBribes = resolveBribes(sim.board, allEntries)
  var forcedHold: array[NumAreas, bool]
  var removed: seq[int]
  for bribe in sim.lastBribes:
    var event = sim.blankEvent(evBribe)
    event.power = bribe.power
    event.targetPower = bribe.targetPower
    event.targetUnit = bribe.targetUnit
    event.province = bribe.targetProvince
    event.bribeKind = bribe.kind
    event.amount = bribe.amount
    event.defence = bribe.defence
    event.outcome = bribe.outcome
    sim.addEvent(event)
    case bribe.outcome
    of "disbanded":
      removed.add(bribe.targetProvince)
    of "bought":
      let index = sim.board.unitIndexAt(bribe.targetProvince)
      if index >= 0:
        var units = sim.board.units
        units[index].power = bribe.power
        sim.board = newBoard(units)
        forcedHold[bribe.targetProvince] = true
    else:
      discard
  if removed.len > 0:
    var survivors: seq[Unit]
    for unit in sim.board.units:
      if unit.province notin removed:
        survivors.add(unit)
    sim.board = newBoard(survivors)

  ## Step 7 — order repair, after step 6's transfers.
  var battle = sim.blankEvent(evBattle)
  battle.phaseKind = phResolve
  var allOrders: seq[Order]
  var record = TurnRecord(year: sim.year, season: sim.season)
  for power in 0 ..< Powers:
    let normalised = sim.normaliseOrders(power, sim.rawOrders[power])
    for order in normalised.good:
      var repaired = order
      if sim.paralysed[power] or forcedHold[order.unit]:
        repaired = blankOrder(power, order.unit)
      allOrders.add(repaired)
      record.orders[power].add(formatOrder(sim.board, repaired))

  ## Step 8 — movement adjudication.
  sim.lastAdjudication = adjudicate(sim.board, allOrders)
  battle.results = sim.lastAdjudication.results
  battle.dislodged = sim.lastAdjudication.dislodged
  battle.standoffs = sim.lastAdjudication.standoffs
  for order in sim.lastAdjudication.results:
    record.outcomes[order.power].add(order.outcome)
  for power in 0 ..< Powers:
    record.spends[power] = sim.spends[power]

  ## Step 9 — retreats, decided by rule. The pledges are read off the board
  ## the orders were written against, so take it before movement is applied.
  let preMovement = sim.board
  sim.lastStabs = sim.pledgeStabs(preMovement)
  sim.runRetreats()
  battle.retreats = sim.lastRetreats
  battle.stabs = sim.lastStabs
  sim.addEvent(battle)
  sim.history.add(record)

  ## Step 10 — city ownership, immediately, every season.
  sim.updateCities()
  if sim.done:
    return

  ## Step 11 — plague, Summer only.
  if sim.season == seSummer:
    let city = Cities[sim.shockRng.rand(TotalCities - 1)]
    sim.plagueCity = city
    var event = sim.blankEvent(evPlague)
    event.phaseKind = phResolve
    event.province = city
    var survivors: seq[Unit]
    for unit in sim.board.units:
      if unit.province == city:
        event.killed.add(unit)
      else:
        survivors.add(unit)
    sim.board = newBoard(survivors)
    sim.addEvent(event)

  var counts: array[Powers, int] = sim.cityCounts()
  sim.cityHistory.add(counts)
  var vaults: array[Powers, int]
  for power in 0 ..< Powers:
    vaults[power] = sim.treasury[power]
  sim.treasuryHistory.add(vaults)

  ## Step 12 — season advance.
  sim.advanceSeason()

proc applyOrders*(sim: var Sim, seat: int, orderTexts: seq[string],
    spend: seq[SpendEntry], builds: seq[string], notes: string,
    scripted: bool) =
  if sim.done:
    raise newException(CogiavelliError, "the episode is over")
  if sim.phase != phOrders:
    raise newException(CogiavelliError, "no orders phase is open")
  if seat < 0 or seat >= Seats or not sim.pending[seat]:
    raise newException(CogiavelliError, "seat " & $seat & " is not pending")
  let power = sim.powerOf[seat]
  var raws: seq[string]
  for text in orderTexts:
    if raws.len >= MaxOrders:
      break
    raws.add(cleanText(text, MaxOrderLen))
  sim.rawOrders[power] = raws
  var sheet: seq[SpendEntry]
  for entry in spend:
    if sheet.len >= MaxSpendEntries:
      break
    var copied = entry
    copied.power = power
    copied.targetUnit = cleanText(copied.targetUnit, MaxTargetLen)
    sheet.add(copied)
  sim.spends[power] = sheet
  var buildList: seq[string]
  if sim.season == seAutumn:
    for entry in builds:
      if buildList.len >= MaxBuilds:
        break
      buildList.add(cleanText(entry, MaxBuildLen))
  sim.builds[power] = buildList
  let normalised = sim.normaliseOrders(power, raws)
  var event = sim.blankEvent(evOrders)
  event.seat = seat
  event.power = power
  event.scripted = scripted
  for order in normalised.good:
    event.orders.add(formatOrder(sim.board, order))
  event.illegalRaw = normalised.illegalRaw
  event.illegalWhy = normalised.illegalWhy
  event.entries = sheet
  event.buildTexts = buildList
  let cleaned = cleanText(notes, MaxNotesLen)
  if cleaned.len > 0:
    sim.notes[seat] = cleaned
  event.text = sim.notes[seat]
  sim.addEvent(event)
  sim.pending[seat] = false
  if sim.pendingSeats().len == 0:
    sim.resolveSeason()

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var powers = newJArray()
  var scores = newJArray()
  var cityNode = newJArray()
  var ducats = newJArray()
  var unitNode = newJArray()
  var spentNode = newJArray()
  var receivedNode = newJArray()
  let units = sim.unitCounts()
  for seat in 0 ..< Seats:
    let power = sim.powerOf[seat]
    ## Results are platform-facing: the league attributes by POLICY name,
    ## never by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    powers.add(%PowerNames[power])
    scores.add(%sim.score(seat))
    cityNode.add(%sim.citiesOf(power))
    ducats.add(%sim.treasury[power])
    unitNode.add(%units[power])
    spentNode.add(%sim.spent[power])
    receivedNode.add(%sim.received[power])
  %*{
    "names": names,
    "powers": powers,
    "scores": scores,
    "cities": cityNode,
    "ducats": ducats,
    "units": unitNode,
    "spent": spentNode,
    "received": receivedNode,
    "years": sim.yearsPlayed,
    "maxYears": sim.config.years,
    "conqueror": (if sim.conqueror >= 0: PowerNames[sim.conqueror] else: ""),
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc letterJson(letter: Letter): JsonNode =
  %*{
    "from": PowerNames[letter.fromPower],
    "to": (if letter.toPower < 0: "ALL" else: PowerNames[letter.toPower]),
    "text": letter.text,
    "public": letter.public
  }

proc pledgeJson(pledge: Pledge): JsonNode =
  %*{
    "to": (if pledge.toPower < 0: "ALL" else: PowerNames[pledge.toPower]),
    "kind": $pledge.kind,
    "province": (if pledge.province >= 0: Provinces[pledge.province].code
                 else: ""),
    "broken": pledge.broken
  }

proc tableStateJson*(sim: Sim): JsonNode =
  let counts = sim.cityCounts()
  let units = sim.unitCounts()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let power = sim.powerOf[seat]
    var lettersOut = newJArray()
    var myPledges = newJArray()
    for letter in sim.press:
      if letter.fromPower == power and not letter.public:
        lettersOut.add(%*{"to": PowerNames[letter.toPower],
          "text": letter.text})
    for pledge in sim.pledges:
      if pledge.fromPower == power:
        myPledges.add(pledgeJson(pledge))
    seats.add(%*{
      "power": PowerNames[power],
      "name": sim.names[seat],
      "cities": counts[power],
      "units": units[power],
      "ducats": sim.treasury[power],
      "score": sim.score(seat),
      "pending": sim.pending[seat],
      "eliminated": sim.eliminated[power],
      "paralysed": sim.paralysed[power],
      "stabbedThisTurn": sim.stabbedThisTurn[power],
      "spentTotal": sim.spent[power],
      "receivedTotal": sim.received[power],
      "broadcast": sim.broadcasts[power],
      "lettersOut": lettersOut,
      "pledges": myPledges,
      "notes": sim.notes[seat]
    })
  var seatOfPower = newJArray()
  for power in 0 ..< Powers:
    seatOfPower.add(%sim.seatOf[power])
  var unitNode = newJArray()
  var bought: array[NumAreas, bool]
  for bribe in sim.lastBribes:
    if bribe.outcome == "bought":
      bought[bribe.targetProvince] = true
  var dislodgedAt: array[NumAreas, bool]
  for hit in sim.lastAdjudication.dislodged:
    dislodgedAt[hit.unit] = true
  for unit in sim.board.units:
    unitNode.add(%*{
      "power": unit.power,
      "kind": kindLetter(unit.kind),
      "province": Provinces[unit.province].code,
      "dislodged": dislodgedAt[unit.province],
      "bought": bought[unit.province]
    })
  var ownersNode = newJArray()
  for slot, city in Cities:
    ownersNode.add(%*{"city": Provinces[city].code, "power": sim.owner[slot]})
  var arrows = newJArray()
  for order in sim.lastAdjudication.results:
    if order.kind == okHold:
      continue
    let kindText =
      case order.kind
      of okMove: "move"
      of okSupportHold, okSupportMove: "support"
      of okConvoy: "convoy"
      else: "move"
    let toProvince =
      if order.kind == okMove: order.target
      elif order.kind == okSupportHold: order.auxFrom
      else: order.auxTo
    arrows.add(%*{
      "kind": kindText,
      "from": Provinces[order.unit].code,
      "to": (if toProvince >= 0: Provinces[toProvince].code else: ""),
      "aux": (if order.auxFrom >= 0: Provinces[order.auxFrom].code else: ""),
      "power": order.power,
      "outcome": $order.outcome
    })
  var purses = newJArray()
  var gifts = newJArray()
  for bribe in sim.lastBribes:
    purses.add(%*{
      "from": bribe.power,
      "to": bribe.targetUnit,
      "kind": $bribe.kind,
      "amount": bribe.amount,
      "outcome": bribe.outcome
    })
  for power in 0 ..< Powers:
    for entry in sim.spends[power]:
      if entry.applied and entry.kind == spGift:
        gifts.add(%*{"from": power, "to": entry.targetPower,
          "amount": entry.amount})
  var daggers = newJArray()
  for dagger in sim.lastDaggers:
    daggers.add(%*{
      "from": dagger.power, "target": dagger.target, "amount": dagger.amount,
      "d1": dagger.d1, "d2": dagger.d2, "roll": dagger.roll,
      "success": dagger.success
    })
  var famineNode = newJArray()
  for province in sim.famine:
    famineNode.add(%Provinces[province].code)
  var rebellions = newJArray()
  for rebellion in sim.lastRebellions:
    if rebellion.roll == RebellionFace:
      rebellions.add(%*{"city": Provinces[rebellion.city].code,
        "power": rebellion.power, "roll": rebellion.roll})
  var stabs = newJArray()
  for stab in sim.lastStabs:
    stabs.add(%*{
      "power": stab.power,
      "pledgeTo": (if stab.pledgeTo < 0: "ALL" else: PowerNames[stab.pledgeTo]),
      "kind": $stab.kind,
      "order": stab.order
    })
  var standoffs = newJArray()
  for province in sim.lastAdjudication.standoffs:
    standoffs.add(%Provinces[province].code)
  var countsNode = newJArray()
  for row in sim.cityHistory:
    var line = newJArray()
    for power in 0 ..< Powers:
      line.add(%row[power])
    countsNode.add(line)
  var treasuriesNode = newJArray()
  for row in sim.treasuryHistory:
    var line = newJArray()
    for power in 0 ..< Powers:
      line.add(%row[power])
    treasuriesNode.add(line)
  var pressNode = newJArray()
  for letter in (if sim.press.len > 0: sim.press else: sim.pressLast):
    pressNode.add(letterJson(letter))
  %*{
    "seats": seats,
    "seatOfPower": seatOfPower,
    "units": unitNode,
    "owners": ownersNode,
    "arrows": arrows,
    "purses": purses,
    "daggers": daggers,
    "gifts": gifts,
    "famine": famineNode,
    "plague": (if sim.plagueCity >= 0: Provinces[sim.plagueCity].code else: ""),
    "rebellions": rebellions,
    "stabs": stabs,
    "standoffs": standoffs,
    "year": sim.year,
    "season": $sim.season,
    "phase": $sim.phase,
    "years": sim.config.years,
    "yearsPlayed": sim.yearsPlayed,
    "counts": countsNode,
    "treasuries": treasuriesNode,
    "press": pressNode,
    "gameDone": sim.done,
    "reason": sim.reason,
    "conqueror": (if sim.conqueror >= 0: PowerNames[sim.conqueror] else: "")
  }

# ---- Event JSON -------------------------------------------------------------

proc unitJson(unit: Unit): JsonNode =
  %*{"power": unit.power, "kind": kindLetter(unit.kind),
     "province": Provinces[unit.province].code}

proc unitFromJson(node: JsonNode): Unit =
  Unit(power: node["power"].getInt(),
    kind: (if node["kind"].getStr() == "F": ukFleet else: ukArmy),
    province: provinceByCode(node["province"].getStr()))

proc intArray(values: seq[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc intSeq(node: JsonNode): seq[int] =
  if node.isNil:
    return
  for value in node:
    result.add(value.getInt())

proc codeArray(values: seq[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%Provinces[value].code)

proc codeSeq(node: JsonNode): seq[int] =
  if node.isNil:
    return
  for value in node:
    result.add(provinceByCode(value.getStr()))

proc spendJson(entry: SpendEntry): JsonNode =
  %*{
    "power": entry.power, "kind": $entry.kind,
    "targetPower": entry.targetPower,
    "targetProvince": (if entry.targetProvince >= 0:
      Provinces[entry.targetProvince].code else: ""),
    "targetUnit": entry.targetUnit, "amount": entry.amount,
    "applied": entry.applied, "why": entry.why
  }

proc spendFromJson(node: JsonNode): SpendEntry =
  SpendEntry(
    power: node["power"].getInt(),
    kind: parseEnum[SpendKind](node["kind"].getStr()),
    targetPower: node["targetPower"].getInt(),
    targetProvince: provinceByCode(node{"targetProvince"}.getStr()),
    targetUnit: node{"targetUnit"}.getStr(),
    amount: node["amount"].getInt(),
    applied: node["applied"].getBool(),
    why: node{"why"}.getStr()
  )

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{
    "kind": $event.kind,
    "year": event.year,
    "season": $event.season,
    "phase": $event.phaseKind,
    "round": seasonIndex(event.year, event.season)
  }
  if event.seat >= 0:
    result["seat"] = %event.seat
  if event.power >= 0:
    result["power"] = %event.power
  if event.scripted:
    result["scripted"] = %true
  if event.text.len > 0:
    result["text"] = %event.text
  case event.kind
  of evStart:
    result["seed"] = %event.seed
    result["powers"] = %event.orders
    result["units"] = newJArray()
    for unit in event.units:
      result["units"].add(unitJson(unit))
    result["owners"] = intArray(event.owners)
    result["treasury"] = intArray(event.treasury)
  of evSeason:
    result["units"] = newJArray()
    for unit in event.units:
      result["units"].add(unitJson(unit))
    result["owners"] = intArray(event.owners)
    result["treasury"] = intArray(event.treasury)
    result["cityCounts"] = intArray(event.cityCounts)
  of evFamine:
    result["provinces"] = codeArray(event.provinces)
  of evPress:
    result["broadcast"] = %event.broadcast
    var letters = newJArray()
    for letter in event.letters:
      letters.add(%*{"to": (if letter.toPower < 0: "ALL"
                            else: PowerNames[letter.toPower]),
        "text": letter.text, "public": letter.public})
    result["letters"] = letters
    var pledges = newJArray()
    for pledge in event.pledges:
      pledges.add(%*{"to": (if pledge.toPower < 0: "ALL"
                            else: PowerNames[pledge.toPower]),
        "kind": $pledge.kind,
        "province": (if pledge.province >= 0:
          Provinces[pledge.province].code else: "")})
    result["pledges"] = pledges
  of evOrders:
    var list = newJArray()
    for order in event.orders:
      list.add(%order)
    result["orders"] = list
    var illegal = newJArray()
    for index in 0 ..< event.illegalRaw.len:
      illegal.add(%*{"raw": event.illegalRaw[index],
        "why": event.illegalWhy[index]})
    result["illegal"] = illegal
    var sheet = newJArray()
    for entry in event.entries:
      sheet.add(spendJson(entry))
    result["spend"] = sheet
    var buildList = newJArray()
    for entry in event.buildTexts:
      buildList.add(%entry)
    result["builds"] = buildList
  of evSpend:
    var entries = newJArray()
    for entry in event.entries:
      entries.add(spendJson(entry))
    result["entries"] = entries
    result["treasuryAfter"] = %event.treasuryAfter
  of evAssassin:
    result["target"] = %event.target
    result["amount"] = %event.amount
    result["d1"] = %event.d1
    result["d2"] = %event.d2
    result["roll"] = %event.roll
    result["success"] = %event.success
  of evBribe:
    result["targetPower"] = %event.targetPower
    result["targetUnit"] = %event.targetUnit
    result["province"] = %(if event.province >= 0:
      Provinces[event.province].code else: "")
    result["bribeKind"] = %($event.bribeKind)
    result["amount"] = %event.amount
    result["defence"] = %event.defence
    result["outcome"] = %event.outcome
  of evBattle:
    var results = newJArray()
    for order in event.results:
      results.add(%*{"power": order.power, "text": order.text,
        "outcome": $order.outcome, "type": $order.kind,
        "from": Provinces[order.unit].code,
        "to": (if order.kind == okMove and order.target >= 0:
          Provinces[order.target].code else: ""),
        "aux": (if order.auxFrom >= 0: Provinces[order.auxFrom].code else: ""),
        "auxTo": (if order.auxTo >= 0: Provinces[order.auxTo].code else: "")})
    result["results"] = results
    var dislodged = newJArray()
    for hit in event.dislodged:
      dislodged.add(%*{"unit": Provinces[hit.unit].code,
        "attackerFrom": Provinces[hit.attackerFrom].code})
    result["dislodged"] = dislodged
    var retreats = newJArray()
    for retreat in event.retreats:
      retreats.add(%*{"unit": Provinces[retreat.unit].code,
        "to": (if retreat.to >= 0: Provinces[retreat.to].code else: "D")})
    result["retreats"] = retreats
    result["standoffs"] = codeArray(event.standoffs)
    var stabs = newJArray()
    for stab in event.stabs:
      stabs.add(%*{"power": stab.power,
        "pledgeTo": (if stab.pledgeTo < 0: "ALL"
                     else: PowerNames[stab.pledgeTo]),
        "kind": $stab.kind,
        "province": (if stab.province >= 0: Provinces[stab.province].code
                     else: ""),
        "order": stab.order})
    result["stabs"] = stabs
  of evCities:
    result["owners"] = intArray(event.owners)
    result["counts"] = intArray(event.cityCounts)
    var gained = newJArray()
    var lost = newJArray()
    for power in 0 ..< event.gained.len:
      gained.add(codeArray(event.gained[power]))
    for power in 0 ..< event.lost.len:
      lost.add(codeArray(event.lost[power]))
    result["gained"] = gained
    result["lost"] = lost
  of evPlague:
    result["province"] = %(if event.province >= 0:
      Provinces[event.province].code else: "")
    var killed = newJArray()
    for unit in event.killed:
      killed.add(unitJson(unit))
    result["killed"] = killed
  of evWinter:
    var rebellions = newJArray()
    for rebellion in event.rebellions:
      rebellions.add(%*{"city": Provinces[rebellion.city].code,
        "power": rebellion.power, "roll": rebellion.roll})
    result["rebellions"] = rebellions
    var famineKills = newJArray()
    for unit in event.famineKills:
      famineKills.add(unitJson(unit))
    result["famineKills"] = famineKills
    result["income"] = intArray(event.income)
    result["incomeDraws"] = intArray(event.incomeDraws)
    result["upkeep"] = intArray(event.upkeep)
    var disbands = newJArray()
    for unit in event.upkeepDisbands:
      disbands.add(unitJson(unit))
    result["upkeepDisbands"] = disbands
    var builds = newJArray()
    for build in event.builds:
      builds.add(%*{"power": build.power, "entry": build.entry,
        "applied": build.applied, "why": build.why})
    result["builds"] = builds
    result["units"] = newJArray()
    for unit in event.units:
      result["units"].add(unitJson(unit))
    result["owners"] = intArray(event.owners)
    result["treasury"] = intArray(event.treasury)
    result["cityCounts"] = intArray(event.cityCounts)
  of evEnd:
    result["cities"] = intArray(event.cities)
    result["treasury"] = intArray(event.treasury)
    result["conqueror"] = %event.conqueror

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    year: node{"year"}.getInt(StartYear),
    season: parseEnum[Season](node{"season"}.getStr("spring")),
    phaseKind: parseEnum[PhaseKind](node{"phase"}.getStr("press")),
    seat: node{"seat"}.getInt(-1),
    power: node{"power"}.getInt(-1),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    province: -1,
    target: -1,
    targetPower: -1
  )
  case result.kind
  of evStart:
    result.seed = node{"seed"}.getInt()
    for name in node{"powers"}:
      result.orders.add(name.getStr())
    for unit in node{"units"}:
      result.units.add(unitFromJson(unit))
    result.owners = intSeq(node{"owners"})
    result.treasury = intSeq(node{"treasury"})
  of evSeason:
    for unit in node{"units"}:
      result.units.add(unitFromJson(unit))
    result.owners = intSeq(node{"owners"})
    result.treasury = intSeq(node{"treasury"})
    result.cityCounts = intSeq(node{"cityCounts"})
  of evFamine:
    result.provinces = codeSeq(node{"provinces"})
  of evPress:
    result.broadcast = node{"broadcast"}.getStr()
    for letter in node{"letters"}:
      result.letters.add(Letter(fromPower: result.power,
        toPower: powerIndex(letter["to"].getStr()),
        text: letter["text"].getStr(), public: letter["public"].getBool()))
    for pledge in node{"pledges"}:
      result.pledges.add(Pledge(fromPower: result.power,
        toPower: powerIndex(pledge["to"].getStr()),
        kind: parseEnum[PledgeKind](pledge["kind"].getStr()),
        province: provinceByCode(pledge{"province"}.getStr())))
  of evOrders:
    for order in node{"orders"}:
      result.orders.add(order.getStr())
    for illegal in node{"illegal"}:
      result.illegalRaw.add(illegal["raw"].getStr())
      result.illegalWhy.add(illegal["why"].getStr())
    for entry in node{"spend"}:
      result.entries.add(spendFromJson(entry))
    for entry in node{"builds"}:
      result.buildTexts.add(entry.getStr())
  of evSpend:
    for entry in node{"entries"}:
      result.entries.add(spendFromJson(entry))
    result.treasuryAfter = node{"treasuryAfter"}.getInt()
  of evAssassin:
    result.target = node{"target"}.getInt(-1)
    result.amount = node{"amount"}.getInt()
    result.d1 = node{"d1"}.getInt()
    result.d2 = node{"d2"}.getInt()
    result.roll = node{"roll"}.getInt()
    result.success = node{"success"}.getBool()
  of evBribe:
    result.targetPower = node{"targetPower"}.getInt(-1)
    result.targetUnit = node{"targetUnit"}.getStr()
    result.province = provinceByCode(node{"province"}.getStr())
    result.bribeKind = parseEnum[SpendKind](node{"bribeKind"}.getStr("gift"))
    result.amount = node{"amount"}.getInt()
    result.defence = node{"defence"}.getInt()
    result.outcome = node{"outcome"}.getStr()
  of evBattle:
    for order in node{"results"}:
      result.results.add(OrderResult(power: order["power"].getInt(),
        unit: provinceByCode(order["from"].getStr()),
        kind: parseEnum[OrderKind](order{"type"}.getStr("hold")),
        target: provinceByCode(order{"to"}.getStr()),
        auxFrom: provinceByCode(order{"aux"}.getStr()),
        auxTo: provinceByCode(order{"auxTo"}.getStr()),
        text: order["text"].getStr(),
        outcome: parseEnum[OrderOutcome](order["outcome"].getStr())))
    for hit in node{"dislodged"}:
      result.dislodged.add(Dislodgement(
        unit: provinceByCode(hit["unit"].getStr()),
        attackerFrom: provinceByCode(hit["attackerFrom"].getStr())))
    for retreat in node{"retreats"}:
      result.retreats.add(Retreat(
        unit: provinceByCode(retreat["unit"].getStr()),
        to: provinceByCode(retreat["to"].getStr())))
    result.standoffs = codeSeq(node{"standoffs"})
    for stab in node{"stabs"}:
      result.stabs.add(Stab(power: stab["power"].getInt(),
        pledgeTo: powerIndex(stab["pledgeTo"].getStr()),
        kind: parseEnum[PledgeKind](stab["kind"].getStr()),
        province: provinceByCode(stab{"province"}.getStr()),
        order: stab["order"].getStr()))
  of evCities:
    result.owners = intSeq(node{"owners"})
    result.cityCounts = intSeq(node{"counts"})
    for row in node{"gained"}:
      result.gained.add(codeSeq(row))
    for row in node{"lost"}:
      result.lost.add(codeSeq(row))
  of evPlague:
    result.province = provinceByCode(node{"province"}.getStr())
    for unit in node{"killed"}:
      result.killed.add(unitFromJson(unit))
  of evWinter:
    for rebellion in node{"rebellions"}:
      result.rebellions.add(Rebellion(
        city: provinceByCode(rebellion["city"].getStr()),
        power: rebellion["power"].getInt(),
        roll: rebellion["roll"].getInt()))
    for unit in node{"famineKills"}:
      result.famineKills.add(unitFromJson(unit))
    result.income = intSeq(node{"income"})
    result.incomeDraws = intSeq(node{"incomeDraws"})
    result.upkeep = intSeq(node{"upkeep"})
    for unit in node{"upkeepDisbands"}:
      result.upkeepDisbands.add(unitFromJson(unit))
    for build in node{"builds"}:
      result.builds.add(BuildRecord(power: build["power"].getInt(),
        entry: build["entry"].getStr(), applied: build["applied"].getBool(),
        why: build{"why"}.getStr()))
    for unit in node{"units"}:
      result.units.add(unitFromJson(unit))
    result.owners = intSeq(node{"owners"})
    result.treasury = intSeq(node{"treasury"})
    result.cityCounts = intSeq(node{"cityCounts"})
  of evEnd:
    result.cities = intSeq(node{"cities"})
    result.treasury = intSeq(node{"treasury"})
    result.conqueror = node{"conqueror"}.getStr()

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log: the press and
  ## orders events are replayed through the rules, and every derived event
  ## is checked against the seeded re-derivation — every shock draw AND
  ## every recorded board snapshot (the `start`, `season`, `cities`,
  ## `winter` and `end` events carry the units, the city owners, the city
  ## counts and the treasuries), so a tampered board is caught as surely as
  ## a tampered die. frames[i] = state after events[0 ..< i].
  var sim = initSim(config)
  var base = sim
  base.events = @[]
  result.add(base)
  var consumed = 0
  for event in events:
    case event.kind
    of evPress:
      sim.applyPress(event.seat, event.broadcast, event.letters,
        event.pledges, event.text, event.scripted)
    of evOrders:
      sim.applyOrders(event.seat, event.orders, event.entries,
        event.buildTexts, event.text, event.scripted)
    of evEnd:
      if not sim.done:
        sim.settle(event.text)
    else:
      discard
    if consumed >= sim.events.len:
      raise newException(CogiavelliError,
        "replay diverges: no derived " & $event.kind & " event")
    let logged = sim.events[consumed]
    if logged.kind != event.kind:
      raise newException(CogiavelliError,
        "replay diverges at event " & $consumed & ": expected " &
          $logged.kind & ", log has " & $event.kind)
    case event.kind
    of evStart:
      if logged.units != event.units or logged.owners != event.owners or
          logged.treasury != event.treasury:
        raise newException(CogiavelliError,
          "recorded opening board disagrees with the re-derivation")
    of evSeason:
      if logged.units != event.units or logged.owners != event.owners or
          logged.treasury != event.treasury or
          logged.cityCounts != event.cityCounts:
        raise newException(CogiavelliError,
          "recorded season board disagrees with the re-derivation")
    of evCities:
      if logged.owners != event.owners or
          logged.cityCounts != event.cityCounts or
          logged.gained != event.gained or logged.lost != event.lost:
        raise newException(CogiavelliError,
          "recorded city table disagrees with the re-derivation")
    of evFamine:
      if logged.provinces != event.provinces:
        raise newException(CogiavelliError,
          "recorded famine draw disagrees with the seeded stream")
    of evPlague:
      if logged.province != event.province:
        raise newException(CogiavelliError,
          "recorded plague draw disagrees with the seeded stream")
    of evAssassin:
      if logged.d1 != event.d1 or logged.d2 != event.d2 or
          logged.roll != event.roll:
        raise newException(CogiavelliError,
          "recorded dagger roll disagrees with the seeded stream")
    of evWinter:
      if logged.incomeDraws != event.incomeDraws:
        raise newException(CogiavelliError,
          "recorded income draws disagree with the seeded stream")
      if logged.rebellions.len != event.rebellions.len:
        raise newException(CogiavelliError,
          "recorded rebellion count disagrees with the seeded stream")
      for index in 0 ..< event.rebellions.len:
        if logged.rebellions[index].roll != event.rebellions[index].roll or
            logged.rebellions[index].city != event.rebellions[index].city:
          raise newException(CogiavelliError,
            "recorded rebellion roll disagrees with the seeded stream")
      if logged.units != event.units or logged.owners != event.owners or
          logged.treasury != event.treasury or
          logged.cityCounts != event.cityCounts:
        raise newException(CogiavelliError,
          "recorded Winter board disagrees with the re-derivation")
    of evEnd:
      if logged.cities != event.cities or
          logged.treasury != event.treasury or
          logged.conqueror != event.conqueror:
        raise newException(CogiavelliError,
          "recorded final table disagrees with the re-derivation")
    else:
      discard
    consumed.inc
    var frame = sim
    result.add(frame)

proc statesFromEvents*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())
