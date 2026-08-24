## Bounded-orders / legality assertion on the scripted baselines, and the
## reply-parsing contract. The baselines are what every failed decision
## falls back to, so "always legal, always affordable, always terminates"
## is load-bearing, not decoration.

import
  std/[json, strutils, times, unicode],
  cogiavelli/[sim, llm]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc newConfig(seed, years: int, press: bool): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.years = years
  result.press = press
  result.turnDelayMs = 0
  for index in 0 ..< 6:
    result.players.add(PlayerConfig(name: "P" & $index))
    result.tokens.add("t")
  result = sampleEpisode(result)

type Audit = object
  sim: Sim
  calls: int

proc play(config: GameConfig, kinds: seq[ScriptKind]): Audit =
  var sim = initSim(config)
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  var calls = 0
  var guard = 0
  while not sim.done and guard < 600:
    guard.inc
    let seats = sim.pendingSeats()
    let phase = sim.phase
    let decisions = decideAll(client, sim, phase, seats, prompts, kinds)
    calls.inc
    for index, seat in seats:
      if sim.done:
        break
      let decision = decisions[index]
      check(decision.scripted, "a disabled client always answers scripted")
      if phase == phOrders:
        check(decision.spend.len <= MaxSpendEntries,
          "no spend array exceeds six entries")
        var treasury = sim.treasury[sim.powerOf[seat]]
        for entry in decision.spend:
          check(entry.amount <= treasury,
            "every spend entry is affordable when it is written")
          treasury -= entry.amount
        sim.applyOrders(seat, decision.orders, decision.spend,
          decision.builds, decision.notes, true)
      else:
        sim.applyPress(seat, decision.broadcast, decision.letters,
          decision.pledges, decision.notes, true)
  Audit(sim: sim, calls: calls)

proc auditEpisode(audit: Audit) =
  let sim = audit.sim
  check(sim.done, "a scripted table always reaches an end condition")
  if sim.conqueror >= 0:
    ## The only other natural end: somebody actually took Italy. Assert the
    ## condition, not just the word.
    check(sim.reason == "conquest", "a named conqueror means a conquest")
    var holders = 0
    for power in 0 ..< Powers:
      if sim.citiesOf(power) > 0:
        holders.inc
    check(sim.citiesOf(sim.conqueror) >= VictoryCities or holders == 1,
      "a conquest is twelve cities or the last power owning any, got " &
        $sim.citiesOf(sim.conqueror) & " cities and " & $holders & " holders")
  else:
    check(sim.reason == "complete",
      "a scripted table with no conqueror plays every year out, got " &
        sim.reason)
    check(sim.yearsPlayed == sim.config.years,
      "and it played all of them, got " & $sim.yearsPlayed & "/" &
        $sim.config.years)
  for event in sim.events:
    case event.kind
    of evOrders:
      check(event.illegalRaw.len == 0,
        "every scripted order parses and is legal: " &
          event.illegalRaw.join(", "))
      var seen: seq[string]
      var destinations: seq[string]
      for order in event.orders:
        let parts = strutils.splitWhitespace(order)
        check(parts[1] notin seen, "every unit is ordered exactly once")
        seen.add(parts[1])
        if parts.len >= 4 and parts[2] == "-":
          check(parts[3] notin destinations,
            "no power ever stands itself off in " & Provinces[
              provinceByCode(parts[3])].code)
          destinations.add(parts[3])
    of evSpend:
      check(event.treasuryAfter >= 0, "no treasury ever goes negative")
    of evWinter:
      for build in event.builds:
        if build.applied:
          let parts = strutils.splitWhitespace(build.entry)
          check(parts.len == 2, "a build names a kind and a city")
          check(isCity(provinceByCode(parts[1])), "a build lands in a city")
          if parts[0] == "F":
            check(isCoastal(provinceByCode(parts[1])),
              "a fleet is only built in a coastal city")
      for treasury in event.treasury:
        check(treasury >= 0, "no treasury ever goes negative")
    else:
      discard
  for power in 0 ..< Powers:
    check(sim.treasury[power] >= 0, "no treasury ends negative")

block theCanonicalScriptedEpisodeCompletes:
  ## Checklist item 7, in the letter: an all-scripted episode runs to the
  ## natural end and `results.reason` is "complete". A single year puts
  ## conquest arithmetically out of reach — six powers start on three
  ## cities each and no power can reach twelve, or be the last holder, in
  ## three seasons — so this fixture can only end one way.
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skCondottiere)
  let audit = play(newConfig(3, 1, true), kinds)
  check(audit.sim.resultsJson()["reason"].getStr() == "complete",
    "the canonical scripted episode reports reason=complete, got " &
      audit.sim.resultsJson()["reason"].getStr())
  auditEpisode(audit)

block condottiereSeeds:
  for seed in 1 .. 8:
    var kinds: seq[ScriptKind]
    for index in 0 ..< 6:
      kinds.add(skCondottiere)
    auditEpisode(play(newConfig(seed, 2, true), kinds))

block bankerSeeds:
  for seed in 1 .. 8:
    var kinds: seq[ScriptKind]
    for index in 0 ..< 6:
      kinds.add(skBanker)
    auditEpisode(play(newConfig(seed, 2, true), kinds))

block mixedTable:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(if index < 3: skCondottiere else: skBanker)
  auditEpisode(play(newConfig(4, 2, true), kinds))

block aBaselineThatCannotBeatAWallIsNoBaseline:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(if index == 5: skCondottiere else: skBanker)
  let audit = play(newConfig(5, 3, false), kinds)
  let sim = audit.sim
  let expander = sim.citiesOf(sim.powerOf[5])
  for seat in 0 ..< 5:
    check(expander > sim.cities(seat),
      "the condottiere must end with more cities than every banker: " &
        $expander & " vs " & $sim.cities(seat))

block noNetworkWithoutCredentials:
  let config = newConfig(2, 1, false)
  var sim = initSim(config)
  ## A client with no transport at all: any network call would crash on the
  ## nil Curly handle, so reaching the end proves none was made.
  var client = LlmClient(disabled: true)
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skNone)
  let decisions = decideAll(client, sim, sim.phase, sim.pendingSeats(),
    newSeq[string](6), kinds)
  check(decisions.len == 6, "six decisions come back")
  for decision in decisions:
    check(decision.scripted, "every one of them is scripted")
    check(decision.orders.len > 0, "and carries real orders")

block finishesFast:
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skCondottiere)
  let years = 4
  let started = epochTime()
  let audit = play(newConfig(6, years, true), kinds)
  let elapsed = (epochTime() - started) * 1000.0
  check(elapsed < float(years * 3 * 1000),
    "six scripted seats finish in under years x 3 x 1000 ms, took " &
      $elapsed.int & "ms")
  check(audit.calls > 0, "the batch loop ran")

# ---- reply parsing ----------------------------------------------------------

block replyParsing:
  var sim = initSim(newConfig(7, 2, true))
  let seat = 0

  let fenced = "```json\n{\"broadcast\": \"peace\", \"notes\": \"x\"}\n```"
  let press = parsePress(sim, seat, extractJsonObject(fenced))
  check(press.broadcast == "peace", "fenced JSON is accepted")

  let prose = "Here is my move.\n{\"orders\": [\"A VER H\"]}\nThat is all."
  var orders = parseOrdersReply(sim, seat, extractJsonObject(prose))
  check(orders.orders == @["A VER H"], "prose-wrapped JSON is accepted")

  var raised = false
  try:
    discard parseOrdersReply(sim, seat, parseJson("""{"spend": []}"""))
  except CogiavelliError:
    raised = true
  check(raised, "a missing orders key is an INVALID reply, so it is retried")

  raised = false
  try:
    discard parsePress(sim, seat, parseJson("""{"notes": "hi"}"""))
  except CogiavelliError:
    raised = true
  check(raised, "press with neither broadcast nor letters is invalid")

  var long = "A VER - "
  for index in 0 ..< 80:
    long.add("X")
  orders = parseOrdersReply(sim, seat,
    parseJson("""{"orders": ["""" & long & """"]}"""))
  check(orders.orders[0].runeLen == MaxOrderLen,
    "an oversize order string is truncated, not rejected")

  orders = parseOrdersReply(sim, seat, parseJson(
    """{"orders": [], "spend": [{"action":"gift","target":"MILAN",
       "amount":"lots"}]}"""))
  check(orders.spend.len == 0, "a non-integer amount drops the entry")

  orders = parseOrdersReply(sim, seat, parseJson(
    """{"orders": [], "spend": [{"action":"burn","target":"MILAN",
       "amount":5}]}"""))
  check(orders.spend.len == 0, "an unknown spend action drops the entry")

  orders = parseOrdersReply(sim, seat, parseJson(
    """{"orders": [], "spend": [{"action":"gift","target":"MILAN",
       "amount":5},{"action":"gift","target":"NOWHERE","amount":5}]}"""))
  check(orders.spend.len == 2, "an unresolvable target is kept and dropped " &
    "later with a reason")
  check(orders.spend[1].why == "notarget", "and the reason is notarget")

  raised = false
  try:
    discard extractJsonObject("no json here at all")
  except CogiavelliError:
    raised = true
  check(raised, "a reply with no object at all is invalid")

echo "test_bot: ok"
