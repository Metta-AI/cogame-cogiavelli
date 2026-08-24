## The ducat layer: the expenditure sheet (steps 4–6) and Winter's
## accounts (W1–W5). Pure rules; every proc that draws takes the shock
## `Rand` by `var` and returns the drawn values so the caller can record
## them into the event that consumed them.

import std/[algorithm, random, strutils], types, orders

const
  BribeDisbandCost* = 9
  BribeBuyCost* = 15
  BuildCost* = 3
  UpkeepPerUnit* = 1
  CityIncome* = 3
  IncomeDrawMax* = 3
  AssassinMin* = 6
  AssassinMax* = 30
  AssassinFaces* = 36
  RebellionFace* = 1
  FamineProvinces* = 2
  StartTreasury* = 12

type
  Treasury* = array[NumPowers, int]

  AssassinResult* = object
    power*: int
    target*: int
    amount*: int
    d1*: int
    d2*: int
    roll*: int
    success*: bool

  BribeResult* = object
    power*: int
    targetProvince*: int
    targetPower*: int
    targetUnit*: string
    kind*: SpendKind
    amount*: int
    defence*: int
    outcome*: string   ## bought | disbanded | outbid | defended

proc bribeCost*(kind: SpendKind): int =
  case kind
  of spBribeDisband: BribeDisbandCost
  of spBribeBuy: BribeBuyCost
  else: 0

proc validateSpend*(board: Board, treasury: var Treasury, power: int,
    entries: var seq[SpendEntry]) =
  ## Step 4, for one power, in the order it listed its entries. Every
  ## surviving entry is paid immediately — the ducats leave the vault
  ## whether or not the entry works — and a gift credits the recipient at
  ## this moment, irrevocably.
  for entry in entries.mitems:
    entry.power = power
    entry.applied = false
    if entry.amount <= 0:
      entry.why = "illegal"
      continue
    case entry.kind
    of spGift, spAssassinate:
      if entry.targetPower < 0 or entry.targetPower >= NumPowers:
        entry.why = "notarget"
        continue
      if entry.targetPower == power:
        entry.why = "illegal"
        continue
      if entry.kind == spAssassinate:
        entry.amount = clamp(entry.amount, AssassinMin, AssassinMax)
    of spBribeDisband, spBribeBuy, spDefend:
      if entry.targetProvince < 0 or not board.hasUnit(entry.targetProvince):
        entry.why = "notarget"
        continue
      let owner = board.unitAt(entry.targetProvince).power
      entry.targetPower = owner
      entry.targetUnit = unitText(board.unitAt(entry.targetProvince))
      if entry.kind == spDefend and owner != power:
        entry.why = "illegal"
        continue
      if entry.kind != spDefend and owner == power:
        entry.why = "illegal"
        continue
    if treasury[power] < entry.amount:
      entry.why = "insufficient"
      continue
    treasury[power] -= entry.amount
    entry.applied = true
    entry.why = ""
    if entry.kind == spGift:
      treasury[entry.targetPower] += entry.amount

proc resolveAssassinations*(entries: seq[SpendEntry], rng: var Rand):
    seq[AssassinResult] =
  ## Step 5. `entries` must already be in ascending power index of the
  ## payer: that is the order the shock stream is advanced in.
  for entry in entries:
    if not entry.applied or entry.kind != spAssassinate:
      continue
    let d1 = rng.rand(1 .. 6)
    let d2 = rng.rand(1 .. 6)
    let roll = 6 * (d1 - 1) + d2
    result.add(AssassinResult(power: entry.power, target: entry.targetPower,
      amount: entry.amount, d1: d1, d2: d2, roll: roll,
      success: roll <= entry.amount))

proc resolveBribes*(board: Board, entries: seq[SpendEntry]): seq[BribeResult] =
  ## Step 6. Every bribe resolves at once against the amounts paid in step
  ## 4. A bribe takes effect iff `amount >= Cost(kind) + defence`; the
  ## strictly largest qualifying amount wins and an exact tie means all of
  ## them fail — rival paymasters cancel, and none of the money comes back.
  var defence: array[NumAreas, int]
  for entry in entries:
    if entry.applied and entry.kind == spDefend:
      defence[entry.targetProvince] += entry.amount
  var attempts: seq[SpendEntry]
  var targets: seq[int]
  for entry in entries:
    if not entry.applied:
      continue
    if entry.kind notin {spBribeDisband, spBribeBuy}:
      continue
    attempts.add(entry)
    if entry.targetProvince notin targets:
      targets.add(entry.targetProvince)
  targets.sortByCode()
  for province in targets:
    var best = 0
    var bestCount = 0
    for entry in attempts:
      if entry.targetProvince != province:
        continue
      if entry.amount < bribeCost(entry.kind) + defence[province]:
        continue
      if entry.amount > best:
        best = entry.amount
        bestCount = 1
      elif entry.amount == best:
        bestCount.inc
    for entry in attempts:
      if entry.targetProvince != province:
        continue
      var outcome = "defended"
      if entry.amount >= bribeCost(entry.kind) + defence[province]:
        if entry.amount == best and bestCount == 1:
          outcome = (if entry.kind == spBribeBuy: "bought" else: "disbanded")
        else:
          outcome = "outbid"
      result.add(BribeResult(power: entry.power, targetProvince: province,
        targetPower: entry.targetPower, targetUnit: entry.targetUnit,
        kind: entry.kind, amount: entry.amount, defence: defence[province],
        outcome: outcome))

proc distanceToOwnCity*(board: Board, unit: Unit, ownedCities: seq[int]): int =
  ## Hops on the unit's own movement graph to the nearest city its owner
  ## holds; `high(int)` when there is none.
  if ownedCities.len == 0:
    return high(int)
  let hops = bfsDistance(unit.province, unit.kind == ukFleet)
  result = high(int)
  for city in ownedCities:
    if hops[city] >= 0 and hops[city] < result:
      result = hops[city]

proc runRebellions*(owners: var array[TotalCities, int], board: Board,
    rng: var Rand): seq[Rebellion] =
  ## W1. Ascending power index, then ascending province code. A non-home
  ## city with no unit standing in it reverts to unowned on a d6 of 1.
  for power in 0 ..< NumPowers:
    var candidates: seq[int]
    for slot, city in Cities:
      if owners[slot] != power:
        continue
      if Provinces[city].homePower == power:
        continue
      if board.hasUnit(city):
        continue
      candidates.add(city)
    candidates.sortByCode()
    for city in candidates:
      let roll = rng.rand(1 .. 6)
      result.add(Rebellion(city: city, power: power, roll: roll))
      if roll == RebellionFace:
        owners[CityIndex[city]] = -1

proc strikeFamine*(board: var Board, famine: seq[int]): seq[Unit] =
  ## W2. Every unit standing in one of this year's famine provinces
  ## disbands.
  var survivors: seq[Unit]
  for unit in board.units:
    if unit.province in famine:
      result.add(unit)
    else:
      survivors.add(unit)
  board = newBoard(survivors)

proc collectIncome*(owners: array[TotalCities, int], barren: seq[int],
    treasury: var Treasury, rng: var Rand):
    tuple[income, draws: array[NumPowers, int]] =
  ## W3. Three ducats per owned city, skipping this year's famine and
  ## plague cities, plus one 0..3 draw per power in ascending power index.
  for slot, city in Cities:
    let owner = owners[slot]
    if owner < 0 or city in barren:
      continue
    result.income[owner] += CityIncome
  for power in 0 ..< NumPowers:
    let draw = rng.rand(0 .. IncomeDrawMax)
    result.draws[power] = draw
    result.income[power] += draw
    treasury[power] += result.income[power]

proc payUpkeep*(board: var Board, owners: array[TotalCities, int],
    treasury: var Treasury):
    tuple[paid: array[NumPowers, int], disbanded: seq[Unit]] =
  ## W4. One ducat per unit. A power that cannot pay for all of them
  ## disbands the unit furthest from the nearest city it owns first, ties
  ## by ascending province code, then pays for every survivor.
  for power in 0 ..< NumPowers:
    var ownedCities: seq[int]
    for slot, city in Cities:
      if owners[slot] == power:
        ownedCities.add(city)
    var mine: seq[Unit]
    for unit in board.units:
      if unit.power == power:
        mine.add(unit)
    ## Furthest from the nearest owned city first, ties by province code.
    var ranked: seq[tuple[distance: int, code: string, unit: Unit]]
    for unit in mine:
      ranked.add((distanceToOwnCity(board, unit, ownedCities),
        Provinces[unit.province].code, unit))
    ranked.sort(proc (a, b: tuple[distance: int, code: string, unit: Unit]): int =
      if a.distance != b.distance: return cmp(b.distance, a.distance)
      cmp(a.code, b.code))
    var count = mine.len
    var index = 0
    while count * UpkeepPerUnit > treasury[power] and index < ranked.len:
      result.disbanded.add(ranked[index].unit)
      index.inc
      count.dec
    result.paid[power] = count * UpkeepPerUnit
    treasury[power] -= result.paid[power]
  if result.disbanded.len > 0:
    var survivors: seq[Unit]
    for unit in board.units:
      if unit notin result.disbanded:
        survivors.add(unit)
    board = newBoard(survivors)

proc runBuilds*(board: var Board, owners: array[TotalCities, int],
    treasury: var Treasury, power: int, entries: seq[string]):
    seq[BuildRecord] =
  ## W5. Each entry costs three ducats and places a unit in a vacant city
  ## the power owns — any owned city, not only a home city. A fleet may
  ## only be built in a coastal city.
  var used: seq[int]
  for entry in entries:
    var record = BuildRecord(power: power, entry: entry, applied: false)
    let tokens = entry.strip().toUpperAscii().splitWhitespace()
    if tokens.len != 2 or tokens[0] notin ["A", "F", "ARMY", "FLEET"]:
      record.why = "parse"
      result.add(record)
      continue
    let fleet = tokens[0] in ["F", "FLEET"]
    let province = provinceByCode(tokens[1])
    if province < 0 or not isCity(province):
      record.why = "notacity"
      result.add(record)
      continue
    if owners[CityIndex[province]] != power:
      record.why = "notowned"
      result.add(record)
      continue
    if board.hasUnit(province) or province in used:
      record.why = "occupied"
      result.add(record)
      continue
    if fleet and not isCoastal(province):
      record.why = "inland"
      result.add(record)
      continue
    if treasury[power] < BuildCost:
      record.why = "insufficient"
      result.add(record)
      continue
    treasury[power] -= BuildCost
    used.add(province)
    var units = board.units
    units.add(Unit(power: power, kind: (if fleet: ukFleet else: ukArmy),
      province: province))
    board = newBoard(units)
    record.applied = true
    result.add(record)
