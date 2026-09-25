## Jev chooses ordinary press and orders fields from a private seat view.

import std/[json, os, strutils]
import curly

proc jevAvailable*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer: JsonNode, count: int): int =
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or probabilities.len != count:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for i in 0 ..< count:
    let probability = probabilities[$i].getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += probability
    if probability > best:
      best = probability
      result = i
  if abs(total - 1) > count.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc choice(values: JsonNode, instructions: string): JsonNode =
  var criteria = newJObject()
  for i in 0 ..< values.len:
    criteria[$i] = values[i]
  %*{"type": "choice", "instructions": instructions,
    "criteria": criteria}

proc chooseJevAction*(view, baselines: JsonNode, prompt: string): JsonNode =
  var questions = newJObject()
  var broadcasts = newJArray()
  var recipients = newJArray()
  if view["phase"].getStr() == "press":
    broadcasts = %*["", "I seek peace while we secure our cities.",
      "I will defend the cities I hold.",
      "I welcome a fair exchange of territory and ducats."]
    recipients.add(%"")
    for power in ["VENICE", "MILAN", "FLORENCE", "PAPACY", "NAPLES", "TURK"]:
      if power != view["power"].getStr():
        recipients.add(%power)
    questions["broadcast"] = choice(broadcasts,
      "Choose a truthful public statement or silence.")
    questions["recipient"] = choice(recipients,
      "Choose one recipient for a peace offer, or none.")
    questions["pledge"] = choice(%*["none", "peace"],
      "Choose whether to make a public peace pledge to that recipient.")
  else:
    for i in 0 ..< view["legalOrders"].len:
      let unit = view["legalOrders"][i]
      questions["order_" & $i] = choice(unit["choices"],
        "Choose one legal order for " & unit["unit"].getStr() & ".")
    questions["spend"] = choice(%*["none", "condottiere", "banker"],
      "Choose one affordable spending sheet.")
    questions["builds"] = choice(%*["none", "condottiere", "banker"],
      "Choose one legal build plan, if this is Autumn.")
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let endpoint = if sidecar.len > 0: sidecar else:
    getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model = if sidecar.len > 0: "typesafe/jev-1.13" else:
    getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if sidecar.len > 0:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  else:
    headers["authorization"] = "Bearer " & getEnv("TYPESAFE_API_KEY")
  let body = $ %*{
    "model": model,
    "state": "You control one Cogiavelli power. Use the full ordinary " &
      "observation to choose each independent action field. Respect legal " &
      "orders and available ducats. Strategy: " & prompt &
      "\nObservation: " & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, body, 45)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  if view["phase"].getStr() == "press":
    let broadcast = broadcasts[bestChoice(answers["broadcast"],
      broadcasts.len)].getStr()
    let recipient = recipients[bestChoice(answers["recipient"],
      recipients.len)].getStr()
    var letters = newJArray()
    var pledges = newJArray()
    if recipient.len > 0:
      letters.add(%*{"to": recipient,
        "text": "I propose peace while we secure our cities."})
      if bestChoice(answers["pledge"], 2) == 1:
        pledges.add(%*{"to": recipient, "kind": "peace"})
    else:
      discard bestChoice(answers["pledge"], 2)
    result = %*{"broadcast": broadcast, "letters": letters,
      "pledges": pledges, "notes": ""}
  else:
    var orders = newJArray()
    for i in 0 ..< view["legalOrders"].len:
      let unit = view["legalOrders"][i]
      let options = unit["choices"]
      orders.add(options[bestChoice(answers["order_" & $i], options.len)])
    let spendKind = bestChoice(answers["spend"], 3)
    let buildsKind = bestChoice(answers["builds"], 3)
    let spend = if spendKind == 0: newJArray() else:
      baselines[(if spendKind == 1: "condottiere" else: "banker")]["spend"]
    let builds = if buildsKind == 0: newJArray() else:
      baselines[(if buildsKind == 1: "condottiere" else: "banker")]["builds"]
    result = %*{"orders": orders, "spend": spend,
      "builds": builds, "notes": ""}
  echo "cogiavelli Jev player: chose ", view["phase"].getStr(),
    " action with ", questions.len, " independent choices"
