## One grammar for parsing and printing Cogiavelli orders, plus the legal
## order set a seat is handed in its prompt.
##
##   A VER H              A VER - MAN            A BAR - PAL VIA CONVOY
##   F VEN S A PAD - FER  F VEN S A PAD          F LAD C A BAR - RAG
##
## Parsing is whitespace- and case-tolerant and accepts `-`, `–`, `—` and
## `->` for a move, `S`/`SUPPORT`, `C`/`CONVOY`, `H`/`HOLD`/`HOLDS`.
## Nothing else. An order that does not fit comes back `illegal` with a
## one-word `why`; it never invalidates the rest of a reply.

import std/strutils, types

type
  Board* = object
    units*: seq[Unit]
    at*: array[NumAreas, int]   ## unit index standing in each area, -1 empty

const MaxLegalOrders* = 64

proc newBoard*(units: seq[Unit]): Board =
  result.units = units
  for index in 0 ..< NumAreas:
    result.at[index] = -1
  for index, unit in units:
    result.at[unit.province] = index

proc unitIndexAt*(board: Board, province: int): int =
  if province < 0 or province >= NumAreas: -1 else: board.at[province]

proc hasUnit*(board: Board, province: int): bool =
  board.unitIndexAt(province) >= 0

proc unitAt*(board: Board, province: int): Unit =
  board.units[board.at[province]]

proc kindLetter*(kind: UnitKind): string =
  if kind == ukFleet: "F" else: "A"

proc unitText*(unit: Unit): string =
  kindLetter(unit.kind) & " " & Provinces[unit.province].code

proc blankOrder*(power, province: int): Order =
  Order(power: power, unit: province, kind: okHold, target: -1, auxFrom: -1,
    auxTo: -1)

proc formatOrder*(order: Order, kind: UnitKind,
    auxKind: UnitKind = ukArmy): string =
  ## Canonical notation for one order.
  let head = kindLetter(kind) & " " & Provinces[order.unit].code
  let aux = kindLetter(auxKind) & " "
  case order.kind
  of okHold:
    head & " H"
  of okMove:
    head & " - " & Provinces[order.target].code &
      (if order.viaConvoy: " VIA CONVOY" else: "")
  of okSupportHold:
    head & " S " & aux & Provinces[order.auxFrom].code
  of okSupportMove:
    head & " S " & aux & Provinces[order.auxFrom].code & " - " &
      Provinces[order.auxTo].code
  of okConvoy:
    head & " C " & aux & Provinces[order.auxFrom].code & " - " &
      Provinces[order.auxTo].code

proc formatOrder*(board: Board, order: Order): string =
  let index = board.unitIndexAt(order.unit)
  let kind = if index >= 0: board.units[index].kind else: ukArmy
  var auxKind = ukArmy
  let auxIndex = board.unitIndexAt(order.auxFrom)
  if auxIndex >= 0:
    auxKind = board.units[auxIndex].kind
  formatOrder(order, kind, auxKind)

proc normalise(raw: string): seq[string] =
  var text = raw.toUpperAscii()
  text = text.replace("\u2013", "-").replace("\u2014", "-")
    .replace("\u2212", "-")
  text = text.replace("->", "-").replace("=>", "-")
  var spaced = ""
  for ch in text:
    if ch == '-':
      spaced.add(' ')
      spaced.add('-')
      spaced.add(' ')
    elif ch in {'.', ',', ';', ':', '(', ')', '"', '\'', '*'}:
      spaced.add(' ')
    else:
      spaced.add(ch)
  spaced.splitWhitespace()

proc kindFromToken(token: string): int =
  ## 0 = army, 1 = fleet, -1 = not a unit token.
  case token
  of "A", "ARMY": 0
  of "F", "FLEET": 1
  else: -1

proc parseUnitRef*(board: Board, text: string): int =
  ## `"A ROM"` -> the province of the unit standing in Rome, or -1 when
  ## there is none, the kind letter disagrees, or the reference is not a
  ## unit reference at all. A bare province code also resolves.
  let tokens = normalise(text)
  if tokens.len == 0 or tokens.len > 2:
    return -1
  var wanted = -1
  var codeToken = tokens[0]
  if tokens.len == 2:
    wanted = kindFromToken(tokens[0])
    if wanted < 0:
      return -1
    codeToken = tokens[1]
  let province = provinceByCode(codeToken)
  if province < 0 or not board.hasUnit(province):
    return -1
  if wanted >= 0:
    let kind = board.unitAt(province).kind
    if (wanted == 1) != (kind == ukFleet):
      return -1
  province

proc parseOrder*(board: Board, power: int, raw: string): Order =
  ## Grammar only: the result carries `illegal` with `why` for anything
  ## that does not parse or names a unit this power does not own. Rule
  ## legality (adjacency, convoy paths, unit kinds) is checked in step 7.
  result = blankOrder(power, -1)
  result.raw = raw.strip()
  proc bad(why: string): Order =
    var order = blankOrder(power, -1)
    order.raw = raw.strip()
    order.illegal = true
    order.why = why
    order
  let tokens = normalise(raw)
  if tokens.len < 2:
    return bad("parse")
  if kindFromToken(tokens[0]) < 0:
    return bad("parse")
  let wantFleet = kindFromToken(tokens[0]) == 1
  let origin = provinceByCode(tokens[1])
  if origin < 0:
    return bad("parse")
  result.unit = origin
  let index = board.unitIndexAt(origin)
  if index < 0 or board.units[index].power != power:
    var order = bad("notowned")
    order.unit = origin
    return order
  if (board.units[index].kind == ukFleet) != wantFleet:
    var order = bad("wrongunit")
    order.unit = origin
    return order

  proc badAt(why: string): Order =
    var order = blankOrder(power, origin)
    order.raw = raw.strip()
    order.illegal = true
    order.why = why
    order

  if tokens.len == 2:
    result.kind = okHold
    return
  case tokens[2]
  of "H", "HOLD", "HOLDS", "STAND", "STANDS":
    if tokens.len != 3:
      return badAt("parse")
    result.kind = okHold
  of "-":
    if tokens.len < 4:
      return badAt("parse")
    let dest = provinceByCode(tokens[3])
    if dest < 0:
      return badAt("parse")
    result.kind = okMove
    result.target = dest
    if tokens.len > 4:
      let tail = tokens[4 .. ^1].join(" ")
      if tail == "VIA CONVOY" or tail == "VIA" or tail == "BY CONVOY" or
          tail == "CONVOY":
        result.viaConvoy = true
      else:
        return badAt("parse")
  of "S", "SUPPORT", "SUPPORTS":
    var pos = 3
    if pos < tokens.len and kindFromToken(tokens[pos]) >= 0:
      pos.inc
    if pos >= tokens.len:
      return badAt("parse")
    let from0 = provinceByCode(tokens[pos])
    if from0 < 0:
      return badAt("parse")
    pos.inc
    result.auxFrom = from0
    if pos >= tokens.len:
      result.kind = okSupportHold
      return
    if tokens[pos] != "-":
      return badAt("parse")
    pos.inc
    if pos >= tokens.len:
      return badAt("parse")
    let to0 = provinceByCode(tokens[pos])
    if to0 < 0:
      return badAt("parse")
    pos.inc
    if pos != tokens.len:
      return badAt("parse")
    result.kind = okSupportMove
    result.auxTo = to0
  of "C", "CONVOY", "CONVOYS":
    var pos = 3
    if pos < tokens.len and kindFromToken(tokens[pos]) >= 0:
      pos.inc
    if pos >= tokens.len:
      return badAt("parse")
    let from0 = provinceByCode(tokens[pos])
    if from0 < 0:
      return badAt("parse")
    pos.inc
    if pos >= tokens.len or tokens[pos] != "-":
      return badAt("parse")
    pos.inc
    if pos >= tokens.len:
      return badAt("parse")
    let to0 = provinceByCode(tokens[pos])
    if to0 < 0:
      return badAt("parse")
    pos.inc
    if pos != tokens.len:
      return badAt("parse")
    result.kind = okConvoy
    result.auxFrom = from0
    result.auxTo = to0
  else:
    return badAt("parse")

proc checkLegality*(board: Board, order: var Order) =
  ## Step 7's rule check. Anything illegal becomes a hold for that unit,
  ## with the reason recorded.
  if order.illegal:
    return
  let index = board.unitIndexAt(order.unit)
  if index < 0 or board.units[index].power != order.power:
    order.illegal = true
    order.why = "notowned"
    return
  let unit = board.units[index]
  let fleet = unit.kind == ukFleet
  case order.kind
  of okHold:
    discard
  of okMove:
    if order.target == order.unit:
      order.illegal = true
      order.why = "nonadjacent"
      return
    if fleet:
      if order.viaConvoy or not isCoastal(order.target) and
          not isSea(order.target):
        order.illegal = true
        order.why = "wrongunit"
        return
      if not isAdjacent(order.unit, order.target, true):
        order.illegal = true
        order.why = "nonadjacent"
      return
    ## An army never enters a sea.
    if isSea(order.target):
      order.illegal = true
      order.why = "wrongunit"
      return
    if order.viaConvoy or not isAdjacent(order.unit, order.target, false):
      if order.target notin convoyReachable(order.unit):
        order.illegal = true
        order.why = (if order.viaConvoy: "noconvoy" else: "nonadjacent")
  of okSupportHold:
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if not isAdjacent(order.unit, order.auxFrom, fleet):
      order.illegal = true
      order.why = "nonadjacent"
  of okSupportMove:
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if not isAdjacent(order.unit, order.auxTo, fleet):
      order.illegal = true
      order.why = "nonadjacent"
  of okConvoy:
    if not fleet:
      order.illegal = true
      order.why = "wrongunit"
      return
    if not isSea(order.unit):
      order.illegal = true
      order.why = "wrongunit"
      return
    if not board.hasUnit(order.auxFrom):
      order.illegal = true
      order.why = "notthere"
      return
    if board.unitAt(order.auxFrom).kind == ukFleet:
      order.illegal = true
      order.why = "wrongunit"
      return
    if not isCoastal(order.auxFrom) or not isCoastal(order.auxTo):
      order.illegal = true
      order.why = "nonadjacent"

proc legalOrders*(board: Board, province: int): seq[string] =
  ## Every order the unit in `province` may legally issue, in the exact
  ## notation a reply must use. Capped at `MaxLegalOrders`.
  let index = board.unitIndexAt(province)
  if index < 0:
    return
  let unit = board.units[index]
  let fleet = unit.kind == ukFleet
  let head = kindLetter(unit.kind) & " " & Provinces[province].code
  result.add(head & " H")
  let neighbours = if fleet: FleetAdj[province] else: ArmyAdj[province]
  for dest in neighbours:
    result.add(head & " - " & Provinces[dest].code)
  if not fleet and isCoastal(province):
    for dest in convoyReachable(province):
      if dest notin neighbours:
        result.add(head & " - " & Provinces[dest].code & " VIA CONVOY")
  for other in neighbours:
    if not board.hasUnit(other):
      continue
    let friend = board.unitAt(other)
    result.add(head & " S " & kindLetter(friend.kind) & " " &
      Provinces[other].code)
    let friendAdj =
      if friend.kind == ukFleet: FleetAdj[other] else: ArmyAdj[other]
    for dest in friendAdj:
      if dest != province and dest in neighbours:
        result.add(head & " S " & kindLetter(friend.kind) & " " &
          Provinces[other].code & " - " & Provinces[dest].code)
  if fleet and isSea(province):
    for other in FleetAdj[province]:
      if not isCoastal(other) or not board.hasUnit(other):
        continue
      if board.unitAt(other).kind == ukFleet:
        continue
      for dest in convoyReachable(other):
        if dest != other:
          result.add(head & " C A " & Provinces[other].code & " - " &
            Provinces[dest].code)
  if result.len > MaxLegalOrders:
    result.setLen(MaxLegalOrders)
