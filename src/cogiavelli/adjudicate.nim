## Cogiavelli's movement adjudicator — resolution step 8. Pure and total:
## no RNG, no IO, no exceptions on legal input.
##
## This is the Diplomacy core, unchanged: the recursive resolver of
## Kruijswijk's *The Math of Adjudication* (unresolved / guessing /
## resolved marks with cycle detection), the four standard strengths, and
## exactly two backup rules — circular movement and the Szykman rule for
## convoy paradoxes.

import types, orders

type
  Mark = enum
    mUnresolved, mGuessing, mResolved

  Adjudication* = object
    results*: seq[OrderResult]
    dislodged*: seq[Dislodgement]
    standoffs*: seq[int]
    moved*: seq[tuple[unit: int, dest: int]]

  Resolver = object
    board: Board
    orders: seq[Order]
    orderAt: array[NumAreas, int]  ## order index of the unit in each area
    matched: seq[bool]             ## support / convoy has a matching order
    state: seq[Mark]
    value: seq[bool]
    paradox: seq[bool]             ## Szykman: this convoyed move is void
    depList: seq[int]

proc adjudicateOrder(r: var Resolver, index: int): bool

proc requiresConvoy(r: Resolver, index: int): bool =
  let order = r.orders[index]
  if order.kind != okMove:
    return false
  let unitIndex = r.board.unitIndexAt(order.unit)
  if unitIndex < 0 or r.board.units[unitIndex].kind == ukFleet:
    return false
  order.viaConvoy or not isAdjacent(order.unit, order.target, false)

proc convoyPathOk(r: var Resolver, index: int): bool =
  ## A chain of seas whose fleets all issued a matching, undislodged
  ## convoy order, from a sea bordering the origin to one bordering the
  ## destination.
  let order = r.orders[index]
  if not isCoastal(order.unit) or not isCoastal(order.target):
    return false
  var usable: array[NumAreas, bool]
  for other in 0 ..< r.orders.len:
    let convoy = r.orders[other]
    if convoy.kind == okConvoy and r.matched[other] and
        convoy.auxFrom == order.unit and convoy.auxTo == order.target and
        isSea(convoy.unit):
      if r.adjudicateOrder(other):
        usable[convoy.unit] = true
  var seen: array[NumAreas, bool]
  var frontier: seq[int]
  for sea in Provinces[order.unit].seas:
    if usable[sea] and not seen[sea]:
      seen[sea] = true
      frontier.add(sea)
  while frontier.len > 0:
    var next: seq[int]
    for sea in frontier:
      if sea in Provinces[order.target].seas:
        return true
      for other in FleetAdj[sea]:
        if isSea(other) and usable[other] and not seen[other]:
          seen[other] = true
          next.add(other)
    frontier = next
  false

proc pathOk(r: var Resolver, index: int): bool =
  ## A move the Szykman rule has voided has no path at all, so it also
  ## stops cutting support — which is the whole point of the rule.
  if r.paradox[index]: return false
  if not r.requiresConvoy(index): true else: r.convoyPathOk(index)

proc headToHeadOpponent(r: var Resolver, index: int): int =
  ## The move ordered straight back at this one, when neither is convoyed.
  let order = r.orders[index]
  let otherIndex = r.orderAt[order.target]
  if otherIndex < 0:
    return -1
  let other = r.orders[otherIndex]
  if other.kind != okMove or other.target != order.unit:
    return -1
  if r.requiresConvoy(index) or r.requiresConvoy(otherIndex):
    return -1
  otherIndex

proc supportCount(r: var Resolver, index: int, excludePower: int): int =
  let order = r.orders[index]
  for other in 0 ..< r.orders.len:
    let support = r.orders[other]
    if support.kind != okSupportMove or not r.matched[other]:
      continue
    if support.auxFrom != order.unit or support.auxTo != order.target:
      continue
    if excludePower >= 0 and support.power == excludePower:
      continue
    if r.adjudicateOrder(other):
      result.inc

proc provinceDislodged(r: var Resolver, province: int): bool =
  for other in 0 ..< r.orders.len:
    let move = r.orders[other]
    if move.kind == okMove and move.target == province and
        r.adjudicateOrder(other):
      return true
  false

proc supportGiven(r: var Resolver, index: int): bool =
  let order = r.orders[index]
  if not r.matched[index]:
    return false
  ## A support is cut by any attack from a province other than the one it
  ## is directed into, by a unit of a different power.
  let shielded = if order.kind == okSupportMove: order.auxTo else: -1
  for other in 0 ..< r.orders.len:
    let move = r.orders[other]
    if move.kind != okMove or move.target != order.unit:
      continue
    if move.power == order.power:
      continue
    if move.unit == shielded:
      continue
    if r.pathOk(other):
      return false
  ## A dislodged supporter's support is cut unconditionally — including
  ## from the direction it was supporting into.
  not r.provinceDislodged(order.unit)

proc holdStrength(r: var Resolver, province: int): int =
  let index = r.orderAt[province]
  if index < 0:
    return 0
  if r.orders[index].kind == okMove:
    return (if r.adjudicateOrder(index): 0 else: 1)
  result = 1
  for other in 0 ..< r.orders.len:
    let support = r.orders[other]
    if support.kind == okSupportHold and r.matched[other] and
        support.auxFrom == province and r.adjudicateOrder(other):
      result.inc

proc attackStrength(r: var Resolver, index: int): int =
  let order = r.orders[index]
  if not r.pathOk(index):
    return 0
  let destIndex = r.orderAt[order.target]
  if destIndex < 0:
    return 1 + r.supportCount(index, -1)
  var vacating = false
  if r.orders[destIndex].kind == okMove and
      r.headToHeadOpponent(index) != destIndex:
    vacating = r.adjudicateOrder(destIndex)
  if vacating:
    return 1 + r.supportCount(index, -1)
  let occupant = r.board.unitAt(order.target)
  ## Self-dislodgement is banned outright.
  if occupant.power == order.power:
    return 0
  1 + r.supportCount(index, occupant.power)

proc defendStrength(r: var Resolver, index: int): int =
  1 + r.supportCount(index, -1)

proc preventStrength(r: var Resolver, index: int): int =
  if not r.pathOk(index):
    return 0
  let opponent = r.headToHeadOpponent(index)
  if opponent >= 0 and r.adjudicateOrder(opponent):
    return 0
  1 + r.supportCount(index, -1)

proc resolveMove(r: var Resolver, index: int): bool =
  let order = r.orders[index]
  if not r.pathOk(index):
    return false
  let attack = r.attackStrength(index)
  if attack == 0:
    return false
  for other in 0 ..< r.orders.len:
    if other == index:
      continue
    let rival = r.orders[other]
    if rival.kind != okMove or rival.target != order.target:
      continue
    if r.preventStrength(other) >= attack:
      return false
  let opponent = r.headToHeadOpponent(index)
  if opponent >= 0:
    if attack <= r.defendStrength(opponent):
      return false
  elif attack <= r.holdStrength(order.target):
    return false
  true

proc resolveOne(r: var Resolver, index: int): bool =
  case r.orders[index].kind
  of okHold: true
  of okMove: r.resolveMove(index)
  of okSupportHold, okSupportMove: r.supportGiven(index)
  of okConvoy:
    if not r.matched[index]: false
    else: not r.provinceDislodged(r.orders[index].unit)

proc backupRule(r: var Resolver, oldLen: int) =
  ## Exactly two rules. A cycle made only of moves is circular movement:
  ## every move in it succeeds. Anything else is a convoy paradox, and the
  ## Szykman rule fails the paradoxical convoyed move.
  var cycle: seq[int]
  while r.depList.len > oldLen:
    cycle.add(r.depList.pop())
  var allMoves = true
  for index in cycle:
    if r.orders[index].kind != okMove:
      allMoves = false
      break
  if allMoves:
    for index in cycle:
      r.state[index] = mResolved
      r.value[index] = true
    return
  ## Szykman: void every convoyed move implicated in the cycle, whether
  ## the move itself or the fleet carrying it is the cycle member.
  var voided: seq[int]
  for index in cycle:
    var move = -1
    if r.orders[index].kind == okMove and r.requiresConvoy(index):
      move = index
    elif r.orders[index].kind == okConvoy:
      let carried = r.orderAt[r.orders[index].auxFrom]
      if carried >= 0 and r.orders[carried].kind == okMove and
          r.orders[carried].target == r.orders[index].auxTo and
          r.requiresConvoy(carried):
        move = carried
    if move >= 0 and not r.paradox[move]:
      r.paradox[move] = true
      voided.add(move)
  for index in cycle:
    r.state[index] = mUnresolved
  for move in voided:
    r.state[move] = mResolved
    r.value[move] = false
  if voided.len == 0:
    ## Nothing convoyed to void: break the cycle on its first member so
    ## the resolver always terminates.
    r.state[cycle[0]] = mResolved
    r.value[cycle[0]] = false

proc adjudicateOrder(r: var Resolver, index: int): bool =
  case r.state[index]
  of mResolved:
    return r.value[index]
  of mGuessing:
    if index notin r.depList:
      r.depList.add(index)
    return r.value[index]
  of mUnresolved:
    discard
  let oldLen = r.depList.len
  r.state[index] = mGuessing
  r.value[index] = false
  let firstResult = r.resolveOne(index)
  if r.depList.len == oldLen:
    if r.state[index] != mResolved:
      r.state[index] = mResolved
      r.value[index] = firstResult
    return r.value[index]
  if r.depList[oldLen] != index:
    r.depList.add(index)
    r.value[index] = firstResult
    return firstResult
  while r.depList.len > oldLen:
    r.state[r.depList.pop()] = mUnresolved
  r.state[index] = mGuessing
  r.value[index] = true
  let secondResult = r.resolveOne(index)
  if firstResult == secondResult:
    while r.depList.len > oldLen:
      r.state[r.depList.pop()] = mUnresolved
    r.state[index] = mResolved
    r.value[index] = firstResult
    return firstResult
  r.backupRule(oldLen)
  r.adjudicateOrder(index)

proc computeMatched(r: var Resolver) =
  r.matched = newSeq[bool](r.orders.len)
  for index, order in r.orders:
    case order.kind
    of okSupportHold:
      let aux = r.orderAt[order.auxFrom]
      r.matched[index] = r.board.hasUnit(order.auxFrom) and
        (aux < 0 or r.orders[aux].kind != okMove)
    of okSupportMove, okConvoy:
      let aux = r.orderAt[order.auxFrom]
      r.matched[index] = aux >= 0 and r.orders[aux].kind == okMove and
        r.orders[aux].target == order.auxTo
    else:
      r.matched[index] = true

proc adjudicate*(board: Board, orders: seq[Order]): Adjudication =
  ## Step 8. `orders` must hold exactly one legal order per unit on the
  ## board; the sim's order repair guarantees that.
  var r = Resolver(board: board, orders: orders)
  for index in 0 ..< NumAreas:
    r.orderAt[index] = -1
  for index, order in orders:
    if order.unit >= 0 and order.unit < NumAreas:
      r.orderAt[order.unit] = index
  r.computeMatched()
  r.state = newSeq[Mark](orders.len)
  r.value = newSeq[bool](orders.len)
  r.paradox = newSeq[bool](orders.len)
  var succeeded = newSeq[bool](orders.len)
  for index in 0 ..< orders.len:
    succeeded[index] = r.adjudicateOrder(index)

  ## Outcomes, in order.
  for index, order in orders:
    var outcome: OrderOutcome
    case order.kind
    of okHold:
      outcome = ooHeld
    of okMove:
      if succeeded[index]:
        outcome = ooSuccess
      elif not r.pathOk(index):
        outcome = ooNoConvoy
      else:
        outcome = ooBounce
    of okSupportHold, okSupportMove:
      if not r.matched[index]: outcome = ooVoid
      elif succeeded[index]: outcome = ooSuccess
      else: outcome = ooCut
    of okConvoy:
      if not r.matched[index]: outcome = ooVoid
      elif succeeded[index]: outcome = ooSuccess
      else: outcome = ooDislodged
    result.results.add(OrderResult(power: order.power, unit: order.unit,
      kind: order.kind, target: order.target, auxFrom: order.auxFrom,
      auxTo: order.auxTo, text: formatOrder(board, order),
      outcome: outcome))

  ## Successful moves, dislodgements, standoffs.
  var movedAway: array[NumAreas, bool]
  for index, order in orders:
    if order.kind == okMove and succeeded[index]:
      movedAway[order.unit] = true
      result.moved.add((order.unit, order.target))
  var entered: array[NumAreas, int]
  var bounced: array[NumAreas, int]
  for index in 0 ..< NumAreas:
    entered[index] = -1
  for index, order in orders:
    if order.kind != okMove:
      continue
    if succeeded[index]:
      entered[order.target] = order.unit
    elif r.pathOk(index):
      bounced[order.target].inc
  for province in 0 ..< NumAreas:
    if entered[province] >= 0 and board.hasUnit(province) and
        not movedAway[province]:
      result.dislodged.add(Dislodgement(unit: province,
        attackerFrom: entered[province]))
      let ordered = r.orderAt[province]
      if ordered >= 0:
        result.results[ordered].outcome = ooDislodged
    if entered[province] < 0 and bounced[province] >= 2:
      result.standoffs.add(province)
