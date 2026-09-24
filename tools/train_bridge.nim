## Numeric baseline choices over the native six-power simulator.

import std/[hashes, json, os]
import cogiavelli/[llm, sim]

var
  game: Sim
  snapshot: Sim
  seats: seq[int]
  index: int
  decisionId: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let seat = seats[index]
  let system = systemPrompt(snapshot, seat)
  let user = if snapshot.phase == phPress:
    pressPrompt(snapshot, seat, "")
    else: ordersPrompt(snapshot, seat, "")
  %*{"kind": "decision", "game": "cogiavelli",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": (game.year - StartYear) * 6 + ord(game.season) * 2 + ord(game.phase),
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(int(hash(command["seed"].getStr()) mod 1_000_000_000))
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSim(sampleEpisode(config))
  snapshot = game
  seats = game.pendingSeats()
  index = 0
  decisionId = 0
  currentDecision()

proc encode(): JsonNode =
  let seat = seats[index]
  let power = snapshot.powerOf[seat]
  var values = newJArray()
  for name in ["standard", "gunboat"]:
    values.add(%(if variant == name: 1 else: 0))
  for season in [seSpring, seSummer, seAutumn, seWinter]:
    values.add(%(if snapshot.season == season: 1 else: 0))
  for phase in [phPress, phOrders]:
    values.add(%(if snapshot.phase == phase: 1 else: 0))
  for other in 0 ..< Powers:
    values.add(%(if power == other: 1 else: 0))
  values.add(%(float(snapshot.year - StartYear) /
    float(snapshot.config.years)))
  let cities = snapshot.cityCounts()
  for other in 0 ..< Powers:
    values.add(%(float(snapshot.treasury[other]) / 100.0))
    values.add(%(float(cities[other]) / float(TotalCities)))
  for area in 0 ..< NumAreas:
    let occupant = if snapshot.board.hasUnit(area):
      snapshot.board.unitAt(area).power else: -1
    for state in -1 ..< Powers:
      values.add(%(if occupant == state: 1 else: 0))
  for owner in snapshot.owner:
    for state in -1 ..< Powers:
      values.add(%(if owner == state: 1 else: 0))
  for area in 0 ..< NumAreas:
    values.add(%(if area in snapshot.famine: 1 else: 0))
  doAssert values.len == 531
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  let seat = seats[index]
  let kind = if choice == 0: skCondottiere else: skBanker
  let decision = scriptedAction(snapshot, seat, kind, snapshot.phase)
  if snapshot.phase == phPress:
    game.applyPress(seat, decision.broadcast, decision.letters,
      decision.pledges, decision.notes, true)
  else:
    game.applyOrders(seat, decision.orders, decision.spend,
      decision.builds, decision.notes, true)
  inc decisionId
  inc index
  if index == seats.len and not game.done:
    snapshot = game
    seats = game.pendingSeats()
    index = 0
    doAssert seats.len > 0
  let observation = if game.done:
    let scores = resultsJson(game)["scores"]
    var scoresBySeat = newJObject()
    for player in 0 ..< Seats: scoresBySeat[$player] = scores[player]
    %*{"kind": "terminal", "scores": scoresBySeat,
      "utilities": scoresBySeat}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: cogiavelli-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "gunboat"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
