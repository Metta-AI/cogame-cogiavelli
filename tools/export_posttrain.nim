## Export complete engine-resolved episodes as private candidate evidence.
import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import cogiavelli/[sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: cogiavelli-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert episodes >= 10
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var
    runs = newJArray()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  try:
    for seed in 1 .. episodes:
      variantConfig["seed"] = %seed
      var config = defaultGameConfig()
      config.update($variantConfig)
      config = sampleEpisode(config)
      var game = initSim(config)
      let family = "cogiavelli-" & $seed
      let episodeId = family & "-" & variant & "-" &
        $selection.selectedVariant & "-" & $selection.seed
      let trajectory = newDecisionTrajectory(episodeId, family, "cogiavelli",
        "source-" & revision, revision)
      var decisionId = 0
      while not game.done:
        let snapshot = game
        let phase = game.phase
        let seats = game.pendingSeats()
        doAssert seats.len > 0
        for seat in seats:
          let baseline = if seat mod 2 == 0: skCondottiere else: skBanker
          let decision = scriptedAction(snapshot, seat, baseline, phase)
          let reply = decisionReply(decision, phase)
          let system = systemPrompt(snapshot, seat, selection)
          let user = if phase == phPress: pressPrompt(snapshot, seat, "")
            else: ordersPrompt(snapshot, seat, "")
          let eventIndex = game.events.len
          if phase == phPress:
            let parsed = parsePress(snapshot, seat, reply)
            game.applyPress(seat, parsed.broadcast, parsed.letters,
              parsed.pledges, parsed.notes, true)
          else:
            let parsed = parseOrdersReply(snapshot, seat, reply)
            game.applyOrders(seat, parsed.orders, parsed.spend,
              parsed.builds, parsed.notes, true)
          let executed = executedReply(game.events[eventIndex])
          var observation = snapshot.observationJson(seat)
          observation["prompt_template"] = selection.promptMetadata(system, user)
          var attempt = newDecisionAttempt($decisionId & "-teacher",
            "scripted-" & $baseline, aoTeacher)
          attempt.prompt = %*[{"role": "system", "content": system},
            {"role": "user", "content": user}]
          attempt.parsedAction = reply
          attempt.response = %($reply)
          attempt.accepted = reply == executed
          if not attempt.accepted:
            attempt.rejectionReason = some("engine-normalized-submission")
          trajectory.recordDecision($decisionId, $seat, observation, @[attempt],
            if attempt.accepted: some(attempt.attemptId) else: none(string),
            executed, if attempt.accepted: asAccepted else: asFallback, game.done,
            if attempt.accepted: none(string) else: some("engine-normalized-submission"))
          inc decisionId
      doAssert game.reason in ["complete", "conquest"]
      let results = game.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< config.players.len:
        participants[$seat] = %*{"score": results["scores"][seat]}
      trajectory.finish(esCompleted, results, participants)
      stream.write(trajectory.eventsJsonl())
      runs.add(%*{"seed": seed, "years_played": game.yearsPlayed, "reason": game.reason,
        "decisions": decisionId, "scores": results["scores"]})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogiavelli", "variant": variant,
    "source_revision": revision, "teacher": "condottiere-vs-banker",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", episodes
