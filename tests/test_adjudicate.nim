## The classic adjudication cases, one assertion each. Every case below is
## a fixed board plus a fixed order set; the resolver is pure and total, so
## these are exact.

import std/strutils, cogiavelli/[types, orders, adjudicate]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc board(units: varargs[tuple[power: int, kind: UnitKind, province: int]]):
    Board =
  var list: seq[Unit]
  for unit in units:
    list.add(Unit(power: unit.power, kind: unit.kind, province: unit.province))
  newBoard(list)

proc a(power, province: int): tuple[power: int, kind: UnitKind,
    province: int] =
  (power, ukArmy, province)

proc f(power, province: int): tuple[power: int, kind: UnitKind,
    province: int] =
  (power, ukFleet, province)

type Case = object
  outcomes: seq[OrderResult]
  adjudication: Adjudication
  illegal: seq[tuple[raw, why: string]]

proc run(b: Board, raws: varargs[tuple[power: int, text: string]]): Case =
  var list: seq[Order]
  for entry in raws:
    var order = parseOrder(b, entry.power, entry.text)
    checkLegality(b, order)
    if order.illegal:
      result.illegal.add((entry.text, order.why))
      order = blankOrder(entry.power, order.unit)
    list.add(order)
  result.adjudication = adjudicate(b, list)
  result.outcomes = result.adjudication.results

proc outcomeOf(c: Case, province: int): OrderOutcome =
  for entry in c.outcomes:
    if entry.unit == province:
      return entry.outcome
  raise newException(AssertionDefect,
    "no order for " & Provinces[province].code)

proc dislodgedAt(c: Case, province: int): bool =
  for hit in c.adjudication.dislodged:
    if hit.unit == province:
      return true
  false

proc standoffAt(c: Case, province: int): bool =
  province in c.adjudication.standoffs

# 1 — move to an empty province succeeds; to an occupied one at equal
#     strength it bounces.
block:
  let c1 = run(board(a(0, VER)), (0, "A VER - PAD"))
  check(c1.outcomeOf(VER) == ooSuccess, "1a: an empty province is taken")
  let c2 = run(board(a(0, VER), a(1, MAN)), (0, "A VER - MAN"), (1, "A MAN H"))
  check(c2.outcomeOf(VER) == ooBounce, "1b: equal strength bounces")
  check(not c2.dislodgedAt(MAN), "1b: the defender stays")

# 2 — standoff: two unsupported moves to the same province.
block:
  let c = run(board(a(0, VER), a(1, MOD)), (0, "A VER - MAN"),
    (1, "A MOD - MAN"))
  check(c.outcomeOf(VER) == ooBounce and c.outcomeOf(MOD) == ooBounce,
    "2: both bounce")
  check(c.standoffAt(MAN), "2: Mantua is a standoff province")

# 3 — a three-way standoff, and a standoff province is barred as a retreat
#     destination.
block:
  let c = run(board(a(0, VER), a(1, MOD), a(2, TRE)), (0, "A VER - MAN"),
    (1, "A MOD - MAN"), (2, "A TRE - MAN"))
  check(c.outcomeOf(VER) == ooBounce and c.outcomeOf(MOD) == ooBounce and
    c.outcomeOf(TRE) == ooBounce, "3: all three bounce")
  check(c.standoffAt(MAN), "3: Mantua is barred as a retreat destination")

# 4 — a supported attack dislodges.
block:
  let c = run(board(a(0, URB), a(0, PER), f(3, ANC)), (0, "A URB - ANC"),
    (0, "A PER S A URB - ANC"), (3, "F ANC H"))
  check(c.outcomeOf(URB) == ooSuccess, "4: the supported attack lands")
  check(c.dislodgedAt(ANC), "4: the fleet in Ancona is dislodged")

# 5 — cut support.
block:
  let c = run(board(a(1, MAN), a(0, VER), a(0, PAD), a(3, FER)),
    (1, "A MAN - VER"), (0, "A VER S A PAD - FER"), (0, "A PAD - FER"),
    (3, "A FER H"))
  check(c.outcomeOf(VER) == ooCut, "5: the support is cut")
  check(c.outcomeOf(PAD) == ooBounce, "5: so the attack on Ferrara fails")

# 6 — support is NOT cut by an attack out of the province it supports into.
block:
  let c = run(board(a(0, VER), a(0, PAD), a(3, FER)),
    (0, "A VER S A PAD - FER"), (0, "A PAD - FER"), (3, "A FER - VER"))
  check(c.outcomeOf(VER) == ooSuccess, "6: the support stands")
  check(c.dislodgedAt(FER), "6: Ferrara is dislodged")

# 7 — dislodging a supporter always cuts its support, even from the
#     supported direction.
block:
  let c = run(board(a(0, VER), a(0, PAD), a(3, FER), a(3, MAN), a(3, TRE)),
    (0, "A VER S A PAD - FER"), (0, "A PAD - FER"), (3, "A FER - VER"),
    (3, "A MAN S A FER - VER"), (3, "A TRE S A FER - VER"))
  check(c.dislodgedAt(VER), "7: the supporter is dislodged")
  check(c.outcomeOf(FER) == ooSuccess, "7: the attack on Verona lands")

# 8 — the self-dislodgement ban.
block:
  let c = run(board(a(0, VER), a(0, MAN), a(0, FER)), (0, "A VER - MAN"),
    (0, "A MAN H"), (0, "A FER S A VER - MAN"))
  check(c.outcomeOf(VER) == ooBounce, "8: you may not dislodge your own unit")
  check(not c.dislodgedAt(MAN), "8: the own unit stays")

# 9 — a power may not support a foreign attack that dislodges its own unit.
block:
  let c = run(board(a(1, MOD), a(0, PAV), a(0, MAN)), (1, "A MOD - MAN"),
    (0, "A PAV S A MOD - MAN"), (0, "A MAN H"))
  check(c.outcomeOf(MOD) == ooBounce, "9: the support does not count")
  check(not c.dislodgedAt(MAN), "9: the own unit is not dislodged")

# 10 — beleaguered garrison: two equal supported attacks.
block:
  let c = run(board(a(0, VER), a(0, FER), a(1, MOD), a(1, PAV), a(3, MAN)),
    (0, "A VER - MAN"), (0, "A FER S A VER - MAN"), (1, "A MOD - MAN"),
    (1, "A PAV S A MOD - MAN"), (3, "A MAN H"))
  check(c.outcomeOf(VER) == ooBounce and c.outcomeOf(MOD) == ooBounce,
    "10: both attacks bounce")
  check(not c.dislodgedAt(MAN), "10: the beleaguered garrison survives")

# 11 — circular movement, and a ring disrupted from outside.
block:
  let c = run(board(a(0, MAN), a(1, VER), a(2, FER)), (0, "A MAN - VER"),
    (1, "A VER - FER"), (2, "A FER - MAN"))
  check(c.outcomeOf(MAN) == ooSuccess and c.outcomeOf(VER) == ooSuccess and
    c.outcomeOf(FER) == ooSuccess, "11a: the whole ring moves")
  let d = run(board(a(0, MAN), a(1, VER), a(2, FER), a(3, PAD)),
    (0, "A MAN - VER"), (1, "A VER - FER"), (2, "A FER - MAN"),
    (3, "A PAD - VER"))
  check(d.outcomeOf(MAN) == ooBounce and d.outcomeOf(VER) == ooBounce and
    d.outcomeOf(FER) == ooBounce,
    "11b: an external attack that beats one link fails the whole ring")

# 12 — convoy, one fleet and a three-fleet chain.
block:
  let one = run(board(a(4, BAR), f(4, LAD)), (4, "A BAR - AVL VIA CONVOY"),
    (4, "F LAD C A BAR - AVL"))
  check(one.outcomeOf(BAR) == ooSuccess, "12a: one fleet carries the army")
  let chain = run(board(a(4, BAR), f(4, LAD), f(4, ION), f(4, LTS)),
    (4, "A BAR - PAL VIA CONVOY"), (4, "F LAD C A BAR - PAL"),
    (4, "F ION C A BAR - PAL"), (4, "F LTS C A BAR - PAL"))
  check(chain.outcomeOf(BAR) == ooSuccess, "12b: a three-fleet chain carries")

# 13 — convoy disruption: the convoying fleet is dislodged.
block:
  let c = run(board(a(4, BAR), f(4, LAD), f(5, UAD), f(5, AVL)),
    (4, "A BAR - RAG VIA CONVOY"), (4, "F LAD C A BAR - RAG"),
    (5, "F UAD - LAD"), (5, "F AVL S F UAD - LAD"))
  check(c.outcomeOf(BAR) == ooNoConvoy, "13: the army holds in Bari")
  check(c.dislodgedAt(LAD), "13: the convoying fleet is dislodged")
  var vacated = false
  for move in c.adjudication.moved:
    if move.unit == BAR:
      vacated = true
  check(not vacated, "13: Bari is not vacated")

# 14 — a convoy with an alternative path survives one fleet's dislodgement.
#      BAR-AVL can run through LAD alone or LAD then ION; losing ION leaves
#      the shorter chain intact, losing LAD leaves no path at all.
block:
  let c = run(board(a(4, BAR), f(4, LAD), f(4, ION), f(5, LTS), f(5, MES)),
    (4, "A BAR - AVL VIA CONVOY"), (4, "F LAD C A BAR - AVL"),
    (4, "F ION C A BAR - AVL"), (5, "F LTS - ION"),
    (5, "F MES S F LTS - ION"))
  check(c.dislodgedAt(ION), "14: the Ionian fleet is dislodged")
  check(c.outcomeOf(BAR) == ooSuccess, "14: the army crosses anyway")
  let d = run(board(a(4, BAR), f(4, LAD), f(4, ION), f(5, UAD), f(5, RAG)),
    (4, "A BAR - AVL VIA CONVOY"), (4, "F LAD C A BAR - AVL"),
    (4, "F ION C A BAR - AVL"), (5, "F UAD - LAD"),
    (5, "F RAG S F UAD - LAD"))
  check(d.dislodgedAt(LAD) and d.outcomeOf(BAR) == ooNoConvoy,
    "14: losing the only usable link stops the army")

# 15 — the Szykman paradox.
block:
  let c = run(board(a(0, BAR), f(0, LAD), f(1, AVL), f(1, ION)),
    (0, "A BAR - AVL VIA CONVOY"), (0, "F LAD C A BAR - AVL"),
    (1, "F AVL S F ION - LAD"), (1, "F ION - LAD"))
  check(c.outcomeOf(BAR) == ooNoConvoy,
    "15: the paradoxical convoyed move fails and its army holds")
  check(c.dislodgedAt(LAD),
    "15: the convoying fleet's dislodgement stands")

# 16 — support matching: a support of a move that was not ordered is void.
block:
  let c = run(board(f(0, VEN), a(0, PAD)), (0, "F VEN S A PAD - FER"),
    (0, "A PAD - FRI"))
  check(c.outcomeOf(VEN) == ooVoid, "16: the unmatched support is void")
  check(c.outcomeOf(PAD) == ooSuccess, "16: the army goes where it was sent")

# 17 — illegal-order repair, one documented reason each.
block:
  let b = board(f(0, VEN), a(0, PAD), a(4, CAL), f(3, ANC), a(3, PER))
  let c = run(b, (0, "F VEN - PAD"), (0, "A PAD - UAD"),
    (3, "F ANC S A PER - MAN"), (3, "A PER C A PAD - FER"),
    (4, "A CAL - MES"))
  var why: seq[string]
  for entry in c.illegal:
    why.add(entry.raw & "=" & entry.why)
  check("F VEN - PAD=wrongunit" in why, "17: a fleet ordered inland")
  check("A PAD - UAD=wrongunit" in why, "17: an army ordered to sea")
  check("F ANC S A PER - MAN=nonadjacent" in why,
    "17: a support of a non-adjacent destination")
  check("A PER C A PAD - FER=wrongunit" in why, "17: an army ordering a convoy")
  check(c.outcomeOf(VEN) == ooHeld and c.outcomeOf(PAD) == ooHeld and
    c.outcomeOf(ANC) == ooHeld and c.outcomeOf(PER) == ooHeld,
    "17: every illegal order became a hold")
  ## CAL - MES has a POSSIBLE convoy path (both coasts touch the Ionian),
  ## so step 7 lets it through and step 8 fails it for want of a fleet.
  check(c.outcomeOf(CAL) == ooNoConvoy,
    "17: an army ordered across the Strait without a convoy holds")

# 18 — head to head.
block:
  let c = run(board(a(0, VER), a(1, MAN)), (0, "A VER - MAN"),
    (1, "A MAN - VER"))
  check(c.outcomeOf(VER) == ooBounce and c.outcomeOf(MAN) == ooBounce,
    "18: an even head-to-head bounces")
  let d = run(board(a(0, VER), a(0, FER), a(1, MAN)), (0, "A VER - MAN"),
    (0, "A FER S A VER - MAN"), (1, "A MAN - VER"))
  check(d.outcomeOf(VER) == ooSuccess and d.dislodgedAt(MAN),
    "18: with one support the stronger dislodges")

# 19 — retreat rules (the sim decides retreats; the adjudication supplies
#      the attacker's origin and the standoff list they are decided from).
block:
  let c = run(board(a(0, URB), a(0, PER), f(3, ANC)), (0, "A URB - ANC"),
    (0, "A PER S A URB - ANC"), (3, "F ANC H"))
  var attacker = -1
  for hit in c.adjudication.dislodged:
    if hit.unit == ANC:
      attacker = hit.attackerFrom
  check(attacker == URB, "19: the attacker's origin is recorded for retreats")

echo "test_adjudicate: ok"
