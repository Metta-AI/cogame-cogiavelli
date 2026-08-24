## Map integrity. The board is compiled in, so every one of these is a
## statement about the design note's table, not about a data file.

import std/[strutils, tables], cogiavelli/[types, orders]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

block areaCounts:
  check(NumAreas == 42, "42 areas")
  var land = 0
  var seas = 0
  var cities = 0
  for index in 0 ..< NumAreas:
    if Provinces[index].kind == pkSea: seas.inc else: land.inc
    if Provinces[index].isCity: cities.inc
  check(land == 36, "36 land provinces, got " & $land)
  check(seas == 6, "6 seas, got " & $seas)
  check(cities == 24, "24 cities, got " & $cities)
  check(Cities.len == TotalCities, "Cities holds all 24")

block cityCodes:
  const expected = ("TUR COM MIL PAV GEN VER PAD VEN TRI FER BOL PIS FLO " &
    "SIE ANC PER ROM NAP BAR MES PAL RAG DUR AVL").splitWhitespace()
  var seen: seq[string]
  for city in Cities:
    seen.add(Provinces[city].code)
  for code in expected:
    check(code in seen, code & " is a city")
  check(seen.len == expected.len, "no city beyond the table")

block homesAndNeutrals:
  var homes = 0
  var neutrals = 0
  for city in Cities:
    if Provinces[city].homePower >= 0: homes.inc else: neutrals.inc
  check(homes == 18, "18 home cities, got " & $homes)
  check(neutrals == 6, "6 neutral cities, got " & $neutrals)
  for power in 0 ..< NumPowers:
    check(HomeCities[power].len == 3,
      PowerNames[power] & " has three home cities")
    for city in HomeCities[power]:
      check(Provinces[city].homePower == power, "home city maps back")
  for code in "TUR GEN TRI FER BOL MES".splitWhitespace():
    check(Provinces[provinceByCode(code)].homePower < 0,
      code & " starts neutral")

block symmetry:
  for a in 0 ..< NumAreas:
    for b in ArmyAdj[a]:
      check(a in ArmyAdj[b], "armyAdj symmetric at " & Provinces[a].code)
      check(not isSea(a) and not isSea(b),
        "an army adjacency never touches a sea: " & Provinces[a].code)
    for b in FleetAdj[a]:
      check(a in FleetAdj[b], "fleetAdj symmetric at " & Provinces[a].code)
      check(Provinces[a].kind != pkInland and Provinces[b].kind != pkInland,
        "a fleet adjacency never touches an inland province: " &
          Provinces[a].code & "-" & Provinces[b].code)

block coastHops:
  ## Two coastal provinces that are land-adjacent AND share a sea.
  for a in 0 ..< NumLand:
    if not isCoastal(a):
      continue
    for b in ArmyAdj[a]:
      if not isCoastal(b):
        continue
      var shared = false
      for sea in Provinces[a].seas:
        if sea in Provinces[b].seas:
          shared = true
      check(isAdjacent(a, b, true) == shared,
        "coast-hop " & Provinces[a].code & "-" & Provinces[b].code &
          " iff they share a sea")
  check(isAdjacent(GEN, PIS, true), "GEN-PIS hops on the Ligurian")
  check(isAdjacent(DUR, AVL, true), "DUR-AVL hops on the Lower Adriatic")
  check(not isAdjacent(BAR, CAL, true),
    "BAR-CAL is NOT a coast-hop: no shared sea")

block strait:
  check(isAdjacent(CAL, MES, true), "the Strait of Messina is a fleet edge")
  check(not isAdjacent(CAL, MES, false),
    "an army never crosses the Strait of Messina")
  check(MES in convoyReachable(CAL) or CAL in convoyReachable(MES),
    "an army reaches Sicily only by convoy")

block connectivity:
  ## The land graph is in exactly TWO pieces: the mainland and Sicily. That
  ## is the map table's own consequence — Messina and Palermo touch nothing
  ## but each other, which is why the Strait of Messina exists at all.
  var seen: array[NumAreas, bool]
  var components = 0
  for start in 0 ..< NumLand:
    if seen[start]:
      continue
    components.inc
    var stack = @[start]
    seen[start] = true
    var size = 0
    while stack.len > 0:
      let node = stack.pop()
      size.inc
      for other in ArmyAdj[node]:
        if not seen[other]:
          seen[other] = true
          stack.add(other)
    if components == 1:
      check(size == 34, "the mainland holds 34 provinces, got " & $size)
    else:
      check(size == 2, "Sicily holds 2 provinces, got " & $size)
  check(components == 2, "the land graph has two components, got " &
    $components)

block fleetConnectivity:
  var start = -1
  for index in 0 ..< NumAreas:
    if FleetAdj[index].len > 0:
      start = index
      break
  var seen: array[NumAreas, bool]
  var stack = @[start]
  seen[start] = true
  var size = 1
  while stack.len > 0:
    let node = stack.pop()
    for other in FleetAdj[node]:
      if not seen[other]:
        seen[other] = true
        size.inc
        stack.add(other)
  var reachable = 0
  for index in 0 ..< NumAreas:
    if FleetAdj[index].len > 0:
      reachable.inc
  check(size == reachable, "the fleet graph is connected")

block noSplitCoasts:
  for code in ["PIS", "ROM", "CAL", "MES", "AVL"]:
    let province = provinceByCode(code)
    let seas = Provinces[province].seas
    for a in seas:
      for b in seas:
        if a != b:
          check(isAdjacent(a, b, true),
            code & " touches only mutually adjacent seas")

block startUnits:
  check(StartUnits.len == 18, "18 starting units")
  var perPower: array[NumPowers, int]
  for unit in StartUnits:
    perPower[unit.power].inc
    check(isCity(unit.province), "every start unit stands in a city")
    check(Provinces[unit.province].homePower == unit.power,
      "every start unit stands in its own home city")
    if unit.fleet:
      check(isCoastal(unit.province), "a fleet starts in a coastal city")
  for power in 0 ..< NumPowers:
    check(perPower[power] == 3, "three units per power")

block distances:
  for province in 0 ..< NumLand:
    let hops = bfsDistance(province, false)
    var reached = false
    for city in Cities:
      if hops[city] >= 0:
        reached = true
    check(reached, "bfsDistance reaches a city from " &
      Provinces[province].code)

block boardHelpers:
  var units: seq[Unit]
  for start in StartUnits:
    units.add(Unit(power: start.power,
      kind: (if start.fleet: ukFleet else: ukArmy), province: start.province))
  let board = newBoard(units)
  check(board.hasUnit(VER), "Verona is occupied at the start")
  check(parseUnitRef(board, "A VER") == VER, "A VER resolves")
  check(parseUnitRef(board, "F VER") < 0, "there is no fleet in Verona")
  check(parseUnitRef(board, "A MAN") < 0, "Mantua is empty")

echo "test_map: ok"
