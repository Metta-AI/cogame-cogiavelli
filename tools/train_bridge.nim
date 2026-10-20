## Numeric baseline choices or hosted language actions over the six-power simulator.

import std/[hashes, json, os]
import cogiavelli/[llm, sim, prompts]

var
  game: Sim
  snapshot: Sim
  seats: seq[int]
  index: int
  decisionId: int
  manifestPath: string
  variant: string
  selection: PromptSelection
  languageMode: bool

proc currentDecision(): JsonNode =
  let seat = seats[index]
  let system = systemPrompt(snapshot, seat, selection)
  let user = if snapshot.phase == phPress:
    pressPrompt(snapshot, seat, "")
    else: ordersPrompt(snapshot, seat, "")
  result = %*{"kind": "decision", "game": "cogiavelli",
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

  if languageMode:
    result["inference_mode"] = %"text_action"
    result["semantic_view"] = snapshot.observationJson(seat)
    result["semantic_view"]["prompt_template"] = selection.promptMetadata(system, user)
    result["action_schema"] = if snapshot.phase == phPress:
      %*{"type": "object", "properties": {
        "broadcast": {"type": "string"}, "letters": {"type": "array"},
        "pledges": {"type": "array"}, "notes": {"type": "string"}},
        "anyOf": [{"required": ["broadcast"]}, {"required": ["letters"]}]}
      else: %*{"type": "object", "required": ["orders"], "properties": {
        "orders": {"type": "array", "items": {"type": "string"}},
        "spend": {"type": "array"}, "builds": {"type": "array", "items": {"type": "string"}},
        "notes": {"type": "string"}}}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  selection = promptSelection(command)
  let split = if command.hasKey("split"): command["split"].getStr() else: "train"
  if split notin ["train", "validation", "test"]:
    raise newException(ValueError, "split must be train, validation, or test")
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and split == "train":
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  if not languageMode and selection.variant != pvCanonical:
    raise newException(ValueError, "prompt variation requires --language")
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
  doAssert not languageMode
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
  let seat = seats[index]
  let decision = if languageMode:
    if snapshot.phase == phPress: parsePress(snapshot, seat, action)
    else: parseOrdersReply(snapshot, seat, action)
  else:
    let choice = action["choice"].getInt()
    doAssert choice in 0 .. 1
    scriptedAction(snapshot, seat, if choice == 0: skCondottiere else: skBanker, snapshot.phase)
  let eventIndex = game.events.len
  if snapshot.phase == phPress:
    game.applyPress(seat, decision.broadcast, decision.letters,
      decision.pledges, decision.notes, true)
  else:
    game.applyOrders(seat, decision.orders, decision.spend,
      decision.builds, decision.notes, true)
  let accepted = if languageMode: executedReply(game.events[eventIndex]) else: action
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
  %*{"kind": "accepted", "action": accepted, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3]:
    quit("usage: cogiavelli-train-bridge MANIFEST VARIANT [--language]", 1)
  languageMode = args.len == 3
  if languageMode: doAssert args[2] == "--language"
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "gunboat"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher":
        if languageMode:
          %*{"response": $scriptedAction(snapshot, seats[index], skCondottiere,
            snapshot.phase).decisionReply(snapshot.phase)}
        else: %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
