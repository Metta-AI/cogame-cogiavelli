## The ducat layer: payment order, gifts, bribes, daggers, and Winter's
## accounts. Every draw comes from one seeded stream, so a fixed seed pins
## every outcome exactly.

import std/random, cogiavelli/[types, orders, money]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc board(units: varargs[tuple[power: int, kind: UnitKind, province: int]]):
    Board =
  var list: seq[Unit]
  for unit in units:
    list.add(Unit(power: unit.power, kind: unit.kind, province: unit.province))
  newBoard(list)

proc entry(power: int, kind: SpendKind, amount: int, targetPower = -1,
    targetProvince = -1): SpendEntry =
  SpendEntry(power: power, kind: kind, amount: amount,
    targetPower: targetPower, targetProvince: targetProvince)

block paymentOrder:
  ## Entries are validated in the order written; the third of three
  ## unaffordable entries is the one dropped.
  var treasury: Treasury
  treasury[0] = 20
  let b = board((0, ukArmy, VER))
  var sheet = @[
    entry(0, spGift, 8, targetPower = 1),
    entry(0, spGift, 9, targetPower = 2),
    entry(0, spGift, 9, targetPower = 3)
  ]
  validateSpend(b, treasury, 0, sheet)
  check(sheet[0].applied and sheet[1].applied, "the first two are paid")
  check(not sheet[2].applied and sheet[2].why == "insufficient",
    "the third is dropped as unaffordable")
  check(treasury[0] == 3, "17 ducats left the vault")
  check(treasury[1] == 8 and treasury[2] == 9,
    "a gift credits the recipient in the same step")
  check(treasury[3] == 0, "the dropped gift never arrives")

block giftIsBinding:
  var treasury: Treasury
  treasury[0] = 10
  let b = board((0, ukArmy, VER))
  var sheet = @[entry(0, spGift, 10, targetPower = 4)]
  validateSpend(b, treasury, 0, sheet)
  check(treasury[0] == 0 and treasury[4] == 10, "the money has moved")
  ## Nothing in the API can put it back: the entry carries no reversal.
  check(sheet[0].applied and sheet[0].why == "", "the gift stands")

block illegalTargets:
  var treasury: Treasury
  treasury[0] = 60
  let b = board((0, ukArmy, VER), (1, ukArmy, MAN))
  var sheet = @[
    entry(0, spBribeDisband, 9, targetProvince = VER),
    entry(0, spAssassinate, 10, targetPower = 0),
    entry(0, spBribeBuy, 15, targetProvince = FER),
    entry(0, spDefend, 4, targetProvince = MAN)
  ]
  validateSpend(b, treasury, 0, sheet)
  check(sheet[0].why == "illegal", "a bribe on one's own unit is illegal")
  check(sheet[1].why == "illegal", "an assassination on oneself is illegal")
  check(sheet[2].why == "notarget", "there is no unit in Ferrara")
  check(sheet[3].why == "illegal", "you may not defend someone else's unit")
  check(treasury[0] == 60, "nothing was paid")

block bribeThresholds:
  let b = board((0, ukArmy, VER), (1, ukArmy, MAN))
  var noDefence = @[entry(1, spBribeDisband, 9, targetProvince = VER)]
  noDefence[0].applied = true
  noDefence[0].targetPower = 0
  var results = resolveBribes(b, noDefence)
  check(results.len == 1 and results[0].outcome == "disbanded",
    "9 exactly buys a disband against no defence")
  var withDefence = noDefence
  var guard = entry(0, spDefend, 1, targetProvince = VER)
  guard.applied = true
  guard.targetPower = 0
  withDefence.add(guard)
  results = resolveBribes(b, withDefence)
  check(results[0].outcome == "defended", "one ducat of loyalty beats it")

block bribeBuyTransfers:
  let b = board((0, ukArmy, VER), (1, ukArmy, MAN))
  var sheet = @[entry(1, spBribeBuy, 15, targetProvince = VER)]
  sheet[0].applied = true
  sheet[0].targetPower = 0
  let results = resolveBribes(b, sheet)
  check(results[0].outcome == "bought", "15 buys a unit against no defence")
  check(results[0].targetProvince == VER, "the unit is named by its province")

block equalBribesCancel:
  let b = board((0, ukArmy, VER))
  var sheet: seq[SpendEntry]
  for power in [1, 2]:
    var bid = entry(power, spBribeDisband, 12, targetProvince = VER)
    bid.applied = true
    bid.targetPower = 0
    sheet.add(bid)
  var results = resolveBribes(b, sheet)
  check(results.len == 2, "both attempts are recorded")
  for entry in results:
    check(entry.outcome == "outbid",
      "equal competing bribes both fail — and neither payer is refunded")
  ## The larger of two qualifying bribes wins.
  sheet[1].amount = 13
  results = resolveBribes(b, sheet)
  var wins = 0
  for entry in results:
    if entry.outcome == "disbanded":
      wins.inc
      check(entry.amount == 13, "the strictly larger amount wins")
  check(wins == 1, "exactly one bribe takes effect")

block assassinClamp:
  var rng = initRand(11)
  var sheet: seq[SpendEntry]
  var low = entry(0, spAssassinate, 2, targetPower = 1)
  var high = entry(0, spAssassinate, 400, targetPower = 2)
  var treasury: Treasury
  treasury[0] = 500
  let b = board((0, ukArmy, VER))
  sheet = @[low, high]
  validateSpend(b, treasury, 0, sheet)
  check(sheet[0].amount == AssassinMin, "the floor is 6")
  check(sheet[1].amount == AssassinMax, "the ceiling is 30")
  let results = resolveAssassinations(sheet, rng)
  for result in results:
    check(result.roll == 6 * (result.d1 - 1) + result.d2,
      "the roll is two dice")
    check(result.roll >= 1 and result.roll <= AssassinFaces,
      "the roll is 1..36")
    check(result.success == (result.roll <= result.amount),
      "success is roll <= amount")

block assassinTable:
  ## Ten outcomes pinned to a fixed seed.
  var rng = initRand(int64(7) * 104729 + 7)
  var sheet: seq[SpendEntry]
  for index in 0 ..< 10:
    var attempt = entry(0, spAssassinate, 18, targetPower = 1)
    attempt.applied = true
    sheet.add(attempt)
  let results = resolveAssassinations(sheet, rng)
  var rolls: seq[int]
  for result in results:
    rolls.add(result.roll)
  var again = initRand(int64(7) * 104729 + 7)
  let repeat = resolveAssassinations(sheet, again)
  for index in 0 ..< 10:
    check(repeat[index].roll == rolls[index],
      "the same seed reproduces every dagger roll")
    check(repeat[index].success == (rolls[index] <= 18),
      "18 ducats is an even chance")

block income:
  var owners: array[TotalCities, int]
  for slot in 0 ..< TotalCities:
    owners[slot] = -1
  owners[CityIndex[VEN]] = 0
  owners[CityIndex[PAD]] = 0
  owners[CityIndex[VER]] = 0
  var treasury: Treasury
  var rng = initRand(3)
  let collected = collectIncome(owners, @[VER], treasury, rng)
  check(collected.income[0] == 2 * CityIncome + collected.draws[0],
    "a famine city pays nothing and the draw is added")
  check(collected.draws[0] >= 0 and collected.draws[0] <= IncomeDrawMax,
    "the draw is 0..3")
  check(treasury[0] == collected.income[0], "the income lands in the vault")

block upkeep:
  var owners: array[TotalCities, int]
  for slot in 0 ..< TotalCities:
    owners[slot] = -1
  owners[CityIndex[VEN]] = 0
  var b = board((0, ukArmy, VEN), (0, ukArmy, PAV), (0, ukArmy, ROM))
  var treasury: Treasury
  treasury[0] = 2
  let paid = payUpkeep(b, owners, treasury)
  check(paid.disbanded.len == 1, "one unit is disbanded to make the payroll")
  check(paid.disbanded[0].province == PAV or paid.disbanded[0].province == ROM,
    "the furthest unit from an owned city goes first")
  check(paid.paid[0] == 2 and treasury[0] == 0, "the survivors are paid for")
  check(b.units.len == 2, "the disbanded unit leaves the board")

block rebellions:
  var owners: array[TotalCities, int]
  for slot in 0 ..< TotalCities:
    owners[slot] = -1
  owners[CityIndex[VEN]] = 0    ## a Venetian home city, garrisoned
  owners[CityIndex[TUR]] = 0    ## a non-home city, empty
  owners[CityIndex[BOL]] = 0    ## a non-home city, garrisoned
  let b = board((0, ukArmy, VEN), (0, ukArmy, BOL))
  var rng = initRand(5)
  let rolls = runRebellions(owners, b, rng)
  check(rolls.len == 1, "only the empty non-home city is even rolled for")
  check(rolls[0].city == TUR, "Turin is the one at risk")
  check(rolls[0].roll >= 1 and rolls[0].roll <= 6, "a d6")
  check((owners[CityIndex[TUR]] < 0) == (rolls[0].roll == RebellionFace),
    "the city is lost only on a 1")
  check(owners[CityIndex[VEN]] == 0 and owners[CityIndex[BOL]] == 0,
    "a home city and a garrisoned city never rebel")

block famineKills:
  var b = board((0, ukArmy, MOD), (1, ukArmy, APU), (2, ukArmy, VEN))
  let killed = strikeFamine(b, @[MOD, APU])
  check(killed.len == 2, "both famine provinces starve their garrison")
  check(b.units.len == 1, "the survivor stands")

block builds:
  var owners: array[TotalCities, int]
  for slot in 0 ..< TotalCities:
    owners[slot] = -1
  owners[CityIndex[VEN]] = 0
  owners[CityIndex[VER]] = 0
  owners[CityIndex[BOL]] = 0
  owners[CityIndex[PAD]] = 1
  var b = board((0, ukArmy, VER))
  var treasury: Treasury
  treasury[0] = 7
  let records = runBuilds(b, owners, treasury, 0,
    @["F VEN", "F BOL", "A PAD", "A VER", "A VEN"])
  check(records[0].applied, "a fleet in a vacant coastal city we own")
  check(records[1].why == "inland", "a fleet may not be built inland")
  check(records[2].why == "notowned", "nor in someone else's city")
  check(records[3].why == "occupied", "nor where a unit already stands")
  check(records[4].why == "occupied", "nor twice in the same city")
  check(treasury[0] == 7 - BuildCost, "a build costs three ducats")
  check(b.units.len == 2, "one unit was added")

block reproducibility:
  var first: seq[int]
  var second: seq[int]
  for pass in 0 .. 1:
    var rng = initRand(int64(42) * 104729 + 7)
    var owners: array[TotalCities, int]
    for slot in 0 ..< TotalCities:
      owners[slot] = -1
    owners[CityIndex[TUR]] = 0
    let b = board()
    var treasury: Treasury
    let rebels = runRebellions(owners, b, rng)
    let income = collectIncome(owners, @[], treasury, rng)
    var run: seq[int]
    for entry in rebels:
      run.add(entry.roll)
    for power in 0 ..< NumPowers:
      run.add(income.draws[power])
    if pass == 0: first = run else: second = run
  check(first == second, "the same seed reproduces every draw byte for byte")

echo "test_money: ok"
