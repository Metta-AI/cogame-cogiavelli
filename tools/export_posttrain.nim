## Export full native games with the exact hosted press and orders prompts.

import std/[json, os, osproc, strutils]
import cogiavelli/[llm, sim]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: cogiavelli-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSim(sampleEpisode(config))
    var rows: seq[string]
    while not game.done:
      let seats = game.pendingSeats()
      doAssert seats.len > 0
      let snapshot = game
      let phase = game.phase
      for seat in seats:
        let baseline = if seat mod 2 == 0: skCondottiere else: skBanker
        let decision = scriptedAction(snapshot, seat, baseline, phase)
        var reply: JsonNode
        var user: string
        if phase == phPress:
          reply = %*{"broadcast": "", "letters": [], "pledges": [],
            "notes": ""}
          user = pressPrompt(snapshot, seat, "")
          let accepted = parsePress(snapshot, seat, reply)
          game.applyPress(seat, accepted.broadcast, accepted.letters,
            accepted.pledges, accepted.notes, true)
        else:
          var spend = newJArray()
          for entry in decision.spend:
            let target = if entry.targetUnit.len > 0: entry.targetUnit
              else: PowerNames[entry.targetPower]
            spend.add(%*{"action": $entry.kind, "target": target,
              "amount": entry.amount})
          reply = %*{"orders": decision.orders, "spend": spend,
            "builds": decision.builds, "notes": ""}
          user = ordersPrompt(snapshot, seat, "")
          let accepted = parseOrdersReply(snapshot, seat, reply)
          doAssert accepted.orders == decision.orders
          doAssert accepted.spend.len == decision.spend.len
          doAssert accepted.builds == decision.builds
          for index, entry in decision.spend:
            doAssert accepted.spend[index].kind == entry.kind
            doAssert accepted.spend[index].amount == entry.amount
            doAssert accepted.spend[index].targetPower == entry.targetPower
            doAssert accepted.spend[index].targetProvince == entry.targetProvince
          game.applyOrders(seat, accepted.orders, accepted.spend,
            accepted.builds, accepted.notes, true)
        rows.add($(%*{
          "episode_id": "cogiavelli-" & variant & "-" & $seed,
          "seed": "cogiavelli-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(snapshot, seat)},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $reply}],
          "game": "cogiavelli",
          "action_schema_revision": "cogiavelli-press-orders-v1"
        }))
    doAssert game.reason in ["complete", "conquest"]
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "years_played": game.yearsPlayed,
      "reason": game.reason, "decisions": rows.len,
      "scores": resultsJson(game)["scores"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cogiavelli", "variant": variant,
    "source_revision": revision, "teacher": "condottiere-vs-banker",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
