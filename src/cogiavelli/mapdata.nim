## The Cogiavelli board: Renaissance Italy in 1499, compiled in.
##
## 42 areas — 36 land provinces (24 of them cities) and 6 seas. No split
## coasts anywhere: every province that touches two seas touches two
## ADJACENT seas, so `SPA/NC`-style coast notation does not exist.
##
## Two movement graphs are generated from one table and asserted symmetric
## by `tests/test_map.nim`:
##   armyAdj  — the land-neighbour column, land provinces only.
##   fleetAdj — sea<->sea, sea<->its coastal provinces, coast-hops (two
##              coastal provinces that are land-adjacent AND share a sea),
##              plus exactly one fleet-only edge, CAL–MES (the Strait of
##              Messina). An army reaches Sicily only by convoy.

import std/[algorithm, strutils, tables]

type
  ProvinceKind* = enum
    pkInland = "inland"
    pkCoastal = "coastal"
    pkSea = "sea"

  Province* = object
    code*: string
    name*: string
    kind*: ProvinceKind
    isCity*: bool
    homePower*: int   ## -1 for neutral cities, non-cities and seas
    seas*: seq[int]   ## province ids of the seas this coast touches

const
  PowerNames* = ["VENICE", "MILAN", "FLORENCE", "PAPACY", "NAPLES", "TURK"]
  PowerAdjectives* = ["Venetian", "Milanese", "Florentine", "Papal",
    "Neapolitan", "Turkish"]
  ## Display names with the article the feed wants ("the Papacy", "the Turk").
  PowerLongNames* = ["Venice", "Milan", "Florence", "the Papacy", "Naples",
    "the Turk"]
  ## How a prompt addresses the other five powers.
  PowerPromptNames* = ["VENICE", "MILAN", "FLORENCE", "the PAPACY", "NAPLES",
    "the TURK"]
  NumPowers* = 6

  ## Area ids are the index into this table and never change.
  TUR* = 0
  SAV* = 1
  COM* = 2
  MIL* = 3
  PAV* = 4
  GEN* = 5
  TRE* = 6
  MAN* = 7
  VER* = 8
  PAD* = 9
  VEN* = 10
  FRI* = 11
  TRI* = 12
  FER* = 13
  MOD* = 14
  BOL* = 15
  RMG* = 16
  PIS* = 17
  FLO* = 18
  SIE* = 19
  URB* = 20
  ANC* = 21
  PER* = 22
  ROM* = 23
  ABR* = 24
  NAP* = 25
  APU* = 26
  BAR* = 27
  CAL* = 28
  MES* = 29
  PAL* = 30
  BOS* = 31
  RAG* = 32
  ALB* = 33
  DUR* = 34
  AVL* = 35
  LIG* = 36
  UTS* = 37
  LTS* = 38
  ION* = 39
  LAD* = 40
  UAD* = 41

  NumAreas* = 42
  NumLand* = 36
  NumSeas* = 6

## The land table, transcribed from the design note. Column order:
## code, display name, kind, city?, home power (-1 = neutral/none),
## land neighbours, seas.
const LandRows: array[NumLand, tuple[
    code, name: string, kind: ProvinceKind, city: bool, home: int,
    land: string, seas: string]] = [
  ("TUR", "Turin", pkInland, true, -1, "SAV PAV GEN MIL", ""),
  ("SAV", "Savoy", pkInland, false, -1, "TUR GEN PAV", ""),
  ("COM", "Como", pkInland, true, 1, "MIL TRE", ""),
  ("MIL", "Milan", pkInland, true, 1, "TUR COM PAV MAN", ""),
  ("PAV", "Pavia", pkInland, true, 1, "TUR SAV MIL GEN MAN MOD", ""),
  ("GEN", "Genoa", pkCoastal, true, -1, "TUR SAV PAV MOD PIS", "LIG"),
  ("TRE", "Trent", pkInland, false, -1, "COM VER MAN", ""),
  ("MAN", "Mantua", pkInland, false, -1, "MIL PAV TRE VER MOD FER", ""),
  ("VER", "Verona", pkInland, true, 0, "TRE MAN PAD FER", ""),
  ("PAD", "Padua", pkInland, true, 0, "VER VEN FER FRI", ""),
  ("VEN", "Venice", pkCoastal, true, 0, "PAD FRI FER", "UAD"),
  ("FRI", "Friuli", pkCoastal, false, -1, "PAD VEN TRI", "UAD"),
  ("TRI", "Trieste", pkCoastal, true, -1, "FRI BOS", "UAD"),
  ("FER", "Ferrara", pkCoastal, true, -1, "MAN VER PAD VEN BOL RMG", "UAD"),
  ("MOD", "Modena", pkInland, false, -1, "GEN PAV MAN BOL PIS", ""),
  ("BOL", "Bologna", pkInland, true, -1, "FER MOD RMG FLO", ""),
  ("RMG", "Romagna", pkCoastal, false, -1, "FER BOL FLO URB", "UAD"),
  ("PIS", "Pisa", pkCoastal, true, 2, "GEN MOD FLO SIE", "LIG UTS"),
  ("FLO", "Florence", pkInland, true, 2, "BOL RMG PIS SIE URB", ""),
  ("SIE", "Siena", pkInland, true, 2, "PIS FLO PER ROM", ""),
  ("URB", "Urbino", pkInland, false, -1, "RMG FLO PER ANC", ""),
  ("ANC", "Ancona", pkCoastal, true, 3, "URB PER ABR", "LAD"),
  ("PER", "Perugia", pkInland, true, 3, "SIE URB ANC ROM ABR", ""),
  ("ROM", "Rome", pkCoastal, true, 3, "SIE PER ABR NAP", "UTS LTS"),
  ("ABR", "Abruzzi", pkCoastal, false, -1, "ANC PER ROM NAP APU", "LAD"),
  ("NAP", "Naples", pkCoastal, true, 4, "ROM ABR APU CAL", "LTS"),
  ("APU", "Apulia", pkCoastal, false, -1, "ABR NAP BAR CAL", "LAD"),
  ("BAR", "Bari", pkCoastal, true, 4, "APU CAL", "LAD"),
  ("CAL", "Calabria", pkCoastal, false, -1, "NAP APU BAR", "LTS ION"),
  ("MES", "Messina", pkCoastal, true, -1, "PAL", "LTS ION"),
  ("PAL", "Palermo", pkCoastal, true, 4, "MES", "LTS"),
  ("BOS", "Bosnia", pkInland, false, -1, "TRI RAG ALB", ""),
  ("RAG", "Ragusa", pkCoastal, true, 5, "BOS ALB", "LAD"),
  ("ALB", "Albania", pkInland, false, -1, "BOS RAG DUR AVL", ""),
  ("DUR", "Durazzo", pkCoastal, true, 5, "ALB AVL", "LAD"),
  ("AVL", "Avlona", pkCoastal, true, 5, "ALB DUR", "LAD ION")
]

const SeaRows: array[NumSeas, tuple[code, name, neighbours: string]] = [
  ("LIG", "Ligurian Sea", "UTS"),
  ("UTS", "Upper Tyrrhenian Sea", "LIG LTS"),
  ("LTS", "Lower Tyrrhenian Sea", "UTS ION"),
  ("ION", "Ionian Sea", "LTS LAD"),
  ("LAD", "Lower Adriatic Sea", "ION UAD"),
  ("UAD", "Upper Adriatic Sea", "LAD")
]

## The one fleet-only edge on the board.
const StraitOfMessina* = (CAL, MES)

proc buildCodeIndex(): Table[string, int] =
  result = initTable[string, int]()
  for index, row in LandRows:
    result[row.code] = index
  for index, row in SeaRows:
    result[row.code] = NumLand + index

let codeIndex* = buildCodeIndex()

proc idOf(code: string): int =
  codeIndex[code]

proc buildProvinces(): array[NumAreas, Province] =
  for index, row in LandRows:
    var seas: seq[int]
    for code in row.seas.splitWhitespace():
      seas.add(idOf(code))
    result[index] = Province(code: row.code, name: row.name, kind: row.kind,
      isCity: row.city, homePower: row.home, seas: seas)
  for index, row in SeaRows:
    result[NumLand + index] = Province(code: row.code, name: row.name,
      kind: pkSea, isCity: false, homePower: -1, seas: @[])

let Provinces* = buildProvinces()

proc shareASea(a, b: int): bool =
  for sea in Provinces[a].seas:
    if sea in Provinces[b].seas:
      return true
  false

proc buildArmyAdj(): array[NumAreas, seq[int]] =
  for index, row in LandRows:
    var neighbours: seq[int]
    for code in row.land.splitWhitespace():
      neighbours.add(idOf(code))
    neighbours.sort()
    result[index] = neighbours

proc buildFleetAdj(): array[NumAreas, seq[int]] =
  var edges: array[NumAreas, seq[int]]
  proc link(a, b: int) =
    if b notin edges[a]:
      edges[a].add(b)
    if a notin edges[b]:
      edges[b].add(a)
  ## (a) sea <-> sea
  for index, row in SeaRows:
    for code in row.neighbours.splitWhitespace():
      link(NumLand + index, idOf(code))
  ## (b) sea <-> its coastal provinces
  for index, row in LandRows:
    for code in row.seas.splitWhitespace():
      link(index, idOf(code))
  ## (c) coast-hops: land-adjacent coastal provinces sharing a sea
  for index, row in LandRows:
    if row.kind != pkCoastal:
      continue
    for code in row.land.splitWhitespace():
      let other = idOf(code)
      if LandRows[other].kind == pkCoastal and shareASea(index, other):
        link(index, other)
  ## (d) the Strait of Messina, the one fleet-only edge
  link(StraitOfMessina[0], StraitOfMessina[1])
  for index in 0 ..< NumAreas:
    edges[index].sort()
  edges

let
  ArmyAdj* = buildArmyAdj()
  FleetAdj* = buildFleetAdj()

proc buildCities(): seq[int] =
  for index, row in LandRows:
    if row.city:
      result.add(index)

let Cities* = buildCities()

const TotalCities* = 24

proc buildCityIndex(): array[NumAreas, int] =
  for index in 0 ..< NumAreas:
    result[index] = -1
  for slot, province in buildCities():
    result[province] = slot

let CityIndex* = buildCityIndex()
  ## CityIndex[province] = its slot in `Cities`, or -1.

proc buildHomeCities(): array[NumPowers, seq[int]] =
  for index, row in LandRows:
    if row.city and row.home >= 0:
      result[row.home].add(index)

let HomeCities* = buildHomeCities()

type StartUnit* = tuple[power: int, fleet: bool, province: int]

const StartUnits*: array[18, StartUnit] = [
  (0, false, VER), (0, false, PAD), (0, true, VEN),
  (1, false, MIL), (1, false, PAV), (1, false, COM),
  (2, false, FLO), (2, false, SIE), (2, true, PIS),
  (3, false, ROM), (3, false, PER), (3, true, ANC),
  (4, false, NAP), (4, false, BAR), (4, true, PAL),
  (5, false, DUR), (5, false, AVL), (5, true, RAG)
]

proc provinceByCode*(code: string): int =
  ## The area id of a three-letter code, or -1.
  let key = code.strip().toUpperAscii()
  if key.len == 0:
    return -1
  codeIndex.getOrDefault(key, -1)

proc isSea*(province: int): bool =
  province >= 0 and province < NumAreas and Provinces[province].kind == pkSea

proc isCoastal*(province: int): bool =
  province >= 0 and province < NumAreas and
    Provinces[province].kind == pkCoastal

proc isLand*(province: int): bool =
  province >= 0 and province < NumAreas and Provinces[province].kind != pkSea

proc isCity*(province: int): bool =
  province >= 0 and province < NumAreas and Provinces[province].isCity

proc isAdjacent*(a, b: int; fleet: bool): bool =
  ## Adjacency on the mover's own graph.
  if a < 0 or b < 0 or a >= NumAreas or b >= NumAreas:
    return false
  if fleet: b in FleetAdj[a] else: b in ArmyAdj[a]

proc bfsDistance*(source: int, fleet: bool): array[NumAreas, int] =
  ## Hop distance from `source` on one movement graph; -1 where unreachable.
  for index in 0 ..< NumAreas:
    result[index] = -1
  if source < 0 or source >= NumAreas:
    return
  result[source] = 0
  var frontier = @[source]
  while frontier.len > 0:
    var next: seq[int]
    for node in frontier:
      let neighbours = if fleet: FleetAdj[node] else: ArmyAdj[node]
      for other in neighbours:
        if result[other] < 0:
          result[other] = result[node] + 1
          next.add(other)
    frontier = next

proc convoyReachable*(source: int): seq[int] =
  ## Every coastal province an army in `source` could in principle be
  ## convoyed to, ignoring whether fleets are actually there: the legality
  ## predicate step 7 applies to "a move to a non-adjacent area with no
  ## POSSIBLE convoy path".
  if not isCoastal(source):
    return
  var seen: array[NumAreas, bool]
  var frontier: seq[int]
  for sea in Provinces[source].seas:
    if not seen[sea]:
      seen[sea] = true
      frontier.add(sea)
  var reached: array[NumAreas, bool]
  while frontier.len > 0:
    var next: seq[int]
    for sea in frontier:
      for other in FleetAdj[sea]:
        if isSea(other):
          if not seen[other]:
            seen[other] = true
            next.add(other)
        elif isCoastal(other):
          reached[other] = true
    frontier = next
  for index in 0 ..< NumLand:
    if reached[index] and index != source:
      result.add(index)

proc codeLess*(a, b: int): bool =
  ## "Ascending province code" — the tie-break the rules name, taken
  ## literally: the three-letter codes in lexicographic order.
  Provinces[a].code < Provinces[b].code

proc sortByCode*(provinces: var seq[int]) =
  provinces.sort(proc (a, b: int): int = cmp(Provinces[a].code,
    Provinces[b].code))
