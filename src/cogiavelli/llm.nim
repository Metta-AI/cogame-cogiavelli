## Claude-backed decision making for Cogiavelli. Each seat's policy is
## just a prompt: the game server composes that seat's view — the board,
## the city table, every treasury, the ledger, the press it received, the
## complete legal order set for each of its units and the exact price of
## every bribable enemy unit — plus the seat's prompt, and asks Claude what
## it writes, orders and spends.
##
## All six powers decide simultaneously by rule, so EVERY phase fires its
## requests as ONE `curly.makeRequests` batch — never seat by seat. The
## loop is bullwhip's `decideAll`: build one batch over the still-open
## seats, parse each reply, re-batch the failures once with an
## invalid-reply hint, then fall back to the scripted baseline for whatever
## is still open.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing.

import
  std/[algorithm, json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  InvalidHint = "\nYour previous reply was invalid. Respond with ONLY the " &
    "requested JSON object."

type
  ScriptKind* = enum
    skNone = "none"
    skCondottiere = "condottiere"
    skBanker = "banker"

  Decision* = object
    broadcast*: string
    letters*: seq[Letter]
    pledges*: seq[Pledge]
    orders*: seq[string]
    spend*: seq[SpendEntry]
    builds*: seq[string]
    notes*: string
    scripted*: bool     ## decided by a baseline, not by the model

  BaselineParams* = object
    ## The scripted baselines' tunable constants, in one place so
    ## `tools/tune_baseline.nim` can sweep them. The shipped values are the
    ## grid's fitted point; `docs/tuning.md` records the sweep that chose
    ## them.
    bribeTreasury*: int        ## condottiere: disband a threat from here up
    buyTreasury*: int          ## condottiere: buy a city-sitter from here up
    vacatePenalty*: int        ## condottiere: rank cost of leaving own city
    autumnVacatePenalty*: int  ## ... and the same in Autumn
    defendTreasury*: int       ## banker: keep defending while this rich
    defendAmount*: int         ## banker: ducats per defend entry
    buildTreasury*: int        ## banker: build only from here up

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool

const ShippedBaseline* = BaselineParams(
  bribeTreasury: 12,
  buyTreasury: 20,
  vacatePenalty: 1,
  autumnVacatePenalty: 2,
  defendTreasury: 15,
  defendAmount: 4,
  buildTreasury: 30
)

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"condottiere" play the
  ## expander, "banker"/"miser" the hoarder, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "condottiere": skCondottiere
  of "banker", "miser": skBanker
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cogiavelli llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. Haiku leads: hosted Bedrock capacity is
  ## shared account-wide and the sonnet profiles run out first.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cogiavelli llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cogiavelli llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cogiavelli llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cogiavelli llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc myUnits(sim: Sim, power: int): seq[Unit] =
  for unit in sim.board.units:
    if unit.power == power:
      result.add(unit)
  result.sort(proc (a, b: Unit): int =
    cmp(Provinces[a.province].code, Provinces[b.province].code))

proc unownedCities(sim: Sim, power: int): seq[int] =
  for slot, city in Cities:
    if sim.owner[slot] != power:
      result.add(city)

proc distanceMap(sim: Sim, targets: seq[int], fleet: bool):
    array[NumAreas, int] =
  ## Multi-source BFS on one movement graph: hops to the nearest target.
  for index in 0 ..< NumAreas:
    result[index] = -1
  var frontier: seq[int]
  for target in targets:
    let neighbours = if fleet: FleetAdj[target] else: ArmyAdj[target]
    if neighbours.len == 0 and not (fleet or isLand(target)):
      continue
    if result[target] < 0:
      result[target] = 0
      frontier.add(target)
  while frontier.len > 0:
    var next: seq[int]
    for node in frontier:
      let neighbours = if fleet: FleetAdj[node] else: ArmyAdj[node]
      for other in neighbours:
        if result[other] < 0:
          result[other] = result[node] + 1
          next.add(other)
    frontier = next

proc cityOccupied(sim: Sim, city: int): bool =
  sim.board.hasUnit(city)

proc condottiereOrders*(sim: Sim, power: int,
    params = ShippedBaseline): seq[string] =
  ## Rank each unit's legal moves: (a) an unowned neutral city, (b) an
  ## unoccupied city owned by another power, (c) a move that strictly
  ## reduces the distance to the nearest city this power does not own,
  ## (d) hold. A move that would vacate an owned city drops one rank, two
  ## in Autumn. Units walk in ascending province code and claim
  ## destinations, so the baseline never stands itself off; anything left
  ## at rank (c) or (d) supports a neighbour's claim instead.
  type Plan = object
    unit: int
    dest: int            ## -1 = hold
    rawRank: int
    supportUnit: int     ## -1 = not supporting
    supportDest: int
  let targets = sim.unownedCities(power)
  let landMap = distanceMap(sim, targets, false)
  let seaMap = distanceMap(sim, targets, true)
  var claimed: array[NumAreas, bool]
  var plans: seq[Plan]
  let vacatePenalty = if sim.season == seAutumn: params.autumnVacatePenalty
                      else: params.vacatePenalty
  for unit in sim.myUnits(power):
    let fleet = unit.kind == ukFleet
    let hops = if fleet: seaMap else: landMap
    let neighbours = if fleet: FleetAdj[unit.province]
                     else: ArmyAdj[unit.province]
    var options: seq[int]
    for dest in neighbours:
      if not claimed[dest]:
        options.add(dest)
    options.sortByCode()
    let vacatesCity = isCity(unit.province) and
      sim.owner[CityIndex[unit.province]] == power
    var bestScore = 3
    var bestDest = -1
    var bestRaw = 3
    for dest in options:
      var raw = -1
      if isCity(dest) and sim.owner[CityIndex[dest]] < 0:
        raw = 0
      elif isCity(dest) and sim.owner[CityIndex[dest]] != power and
          not sim.cityOccupied(dest):
        raw = 1
      elif hops[dest] >= 0 and hops[unit.province] >= 0 and
          hops[dest] < hops[unit.province]:
        raw = 2
      else:
        continue
      let score = raw + (if vacatesCity: vacatePenalty else: 0)
      if score < bestScore:
        bestScore = score
        bestDest = dest
        bestRaw = raw
    if bestDest >= 0:
      claimed[bestDest] = true
      plans.add(Plan(unit: unit.province, dest: bestDest, rawRank: bestRaw,
        supportUnit: -1, supportDest: -1))
    else:
      plans.add(Plan(unit: unit.province, dest: -1, rawRank: 3,
        supportUnit: -1, supportDest: -1))
  ## Only ranks (a) and (b) are protected from conversion, so a support
  ## can never point at a unit that is itself about to become a support.
  var attacks: seq[tuple[unit, dest: int]]
  for plan in plans:
    if plan.dest >= 0 and plan.rawRank < 2:
      attacks.add((plan.unit, plan.dest))
  for plan in plans.mitems:
    if plan.dest >= 0 and plan.rawRank < 2:
      continue
    let index = sim.board.unitIndexAt(plan.unit)
    if index < 0:
      continue
    let fleet = sim.board.units[index].kind == ukFleet
    let neighbours = if fleet: FleetAdj[plan.unit] else: ArmyAdj[plan.unit]
    var bestUnit = -1
    var bestDest = -1
    for attack in attacks:
      if attack.unit == plan.unit or attack.dest == plan.unit:
        continue
      if attack.dest notin neighbours:
        continue
      if bestUnit < 0 or Provinces[attack.unit].code <
          Provinces[bestUnit].code:
        bestUnit = attack.unit
        bestDest = attack.dest
    if bestUnit >= 0:
      if plan.dest >= 0:
        claimed[plan.dest] = false
      plan.dest = -1
      plan.supportUnit = bestUnit
      plan.supportDest = bestDest
  for plan in plans:
    let index = sim.board.unitIndexAt(plan.unit)
    if index < 0:
      continue
    let head = kindLetter(sim.board.units[index].kind) & " " &
      Provinces[plan.unit].code
    if plan.supportUnit >= 0:
      result.add(head & " S " & Provinces[plan.supportUnit].code & " - " &
        Provinces[plan.supportDest].code)
    elif plan.dest >= 0:
      result.add(head & " - " & Provinces[plan.dest].code)
    else:
      result.add(head & " H")

proc condottiereSpend(sim: Sim, power: int,
    params = ShippedBaseline): seq[SpendEntry] =
  ## Buy the war, not the peace: disband a neighbour that threatens an
  ## owned city, or buy the nearest enemy unit sitting on a city.
  let treasury = sim.treasury[power]
  var mine: seq[int]
  for slot, city in Cities:
    if sim.owner[slot] == power:
      mine.add(city)
  if treasury >= params.bribeTreasury:
    var threats: seq[int]
    for unit in sim.board.units:
      if unit.power == power:
        continue
      var threatens = unit.province in mine
      if not threatens:
        let neighbours = if unit.kind == ukFleet: FleetAdj[unit.province]
                         else: ArmyAdj[unit.province]
        for dest in neighbours:
          if dest in mine:
            threatens = true
            break
      if threatens:
        threats.add(unit.province)
    threats.sortByCode()
    if threats.len > 0:
      let target = threats[0]
      return @[SpendEntry(power: power, kind: spBribeDisband,
        targetPower: sim.board.unitAt(target).power, targetProvince: target,
        targetUnit: unitText(sim.board.unitAt(target)),
        amount: BribeDisbandCost)]
  if treasury >= params.buyTreasury:
    var candidates: seq[int]
    for unit in sim.board.units:
      if unit.power == power:
        continue
      if not isCity(unit.province):
        continue
      if sim.owner[CityIndex[unit.province]] == power:
        continue
      candidates.add(unit.province)
    candidates.sortByCode()
    if candidates.len > 0:
      let target = candidates[0]
      return @[SpendEntry(power: power, kind: spBribeBuy,
        targetPower: sim.board.unitAt(target).power, targetProvince: target,
        targetUnit: unitText(sim.board.unitAt(target)),
        amount: BribeBuyCost)]

proc condottiereBuilds(sim: Sim, power: int): seq[string] =
  ## Keep upkeep covered: build only while treasury - 3 >= unit count.
  var treasury = sim.treasury[power]
  var units = 0
  var fleets = 0
  for unit in sim.board.units:
    if unit.power == power:
      units.inc
      if unit.kind == ukFleet:
        fleets.inc
  var vacant: seq[int]
  for slot, city in Cities:
    if sim.owner[slot] == power and not sim.board.hasUnit(city):
      vacant.add(city)
  vacant.sortByCode()
  for city in vacant:
    if result.len >= MaxBuilds:
      break
    if treasury - BuildCost < units:
      break
    let wantFleet = isCoastal(city) and fleets < units - fleets
    result.add((if wantFleet: "F " else: "A ") & Provinces[city].code)
    treasury -= BuildCost
    units.inc
    if wantFleet:
      fleets.inc

proc bankerOrders(sim: Sim, power: int): seq[string] =
  ## The wall with a vault: every unit holds, and a unit next to an owned
  ## city held by one of its own supports that unit's hold instead.
  for unit in sim.myUnits(power):
    let head = kindLetter(unit.kind) & " " & Provinces[unit.province].code
    let neighbours = if unit.kind == ukFleet: FleetAdj[unit.province]
                     else: ArmyAdj[unit.province]
    var options: seq[int]
    for dest in neighbours:
      if not isCity(dest) or sim.owner[CityIndex[dest]] != power:
        continue
      if not sim.board.hasUnit(dest):
        continue
      if sim.board.unitAt(dest).power != power:
        continue
      options.add(dest)
    options.sortByCode()
    if options.len > 0:
      result.add(head & " S " & Provinces[options[0]].code)
    else:
      result.add(head & " H")

proc bankerSpend(sim: Sim, power: int,
    params = ShippedBaseline): seq[SpendEntry] =
  var treasury = sim.treasury[power]
  var garrisons: seq[int]
  for unit in sim.board.units:
    if unit.power == power and isCity(unit.province):
      garrisons.add(unit.province)
  garrisons.sortByCode()
  for province in garrisons:
    if result.len >= MaxSpendEntries or treasury < params.defendTreasury:
      break
    result.add(SpendEntry(power: power, kind: spDefend, targetPower: power,
      targetProvince: province, targetUnit: unitText(sim.board.unitAt(province)),
      amount: params.defendAmount))
    treasury -= params.defendAmount

proc bankerBuilds(sim: Sim, power: int,
    params = ShippedBaseline): seq[string] =
  if sim.treasury[power] < params.buildTreasury:
    return
  var vacant: seq[int]
  for slot, city in Cities:
    if sim.owner[slot] == power and not sim.board.hasUnit(city):
      vacant.add(city)
  vacant.sortByCode()
  if vacant.len > 0:
    result.add("A " & Provinces[vacant[0]].code)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind,
    phase: PhaseKind, params = ShippedBaseline): Decision =
  ## Both baselines are deterministic, silent, and legal by construction.
  result.scripted = true
  if phase == phPress:
    return
  let power = sim.powerOf[seat]
  case kind
  of skBanker:
    result.orders = bankerOrders(sim, power)
    result.spend = bankerSpend(sim, power, params)
    if sim.season == seAutumn:
      result.builds = bankerBuilds(sim, power, params)
  else:
    result.orders = condottiereOrders(sim, power, params)
    result.spend = condottiereSpend(sim, power, params)
    if sim.season == seAutumn:
      result.builds = condottiereBuilds(sim, power)

# ---- Prompt building --------------------------------------------------------

proc boardText(sim: Sim): string =
  var lines: seq[string]
  for power in 0 ..< Powers:
    var units: seq[string]
    for unit in sim.board.units:
      if unit.power == power:
        units.add(unitText(unit) & " (" & Provinces[unit.province].name & ")")
    units.sort(system.cmp)
    lines.add(PowerNames[power] & ": " &
      (if units.len > 0: units.join(", ") else: "(no units)"))
  lines.join("\n")

proc cityTableText(sim: Sim): string =
  var lines: seq[string]
  let counts = sim.cityCounts()
  var neutral: seq[string]
  for power in 0 ..< Powers:
    var owned: seq[string]
    for slot, city in Cities:
      if sim.owner[slot] == power:
        owned.add(Provinces[city].code)
    owned.sort(system.cmp)
    lines.add(PowerNames[power] & " (" & $counts[power] & "): " &
      (if owned.len > 0: owned.join(" ") else: "none"))
  for slot, city in Cities:
    if sim.owner[slot] < 0:
      neutral.add(Provinces[city].code)
  neutral.sort(system.cmp)
  lines.add("NEUTRAL (" & $neutral.len & "): " &
    (if neutral.len > 0: neutral.join(" ") else: "none"))
  lines.join("\n")

proc treasuryText(sim: Sim): string =
  var parts: seq[string]
  for power in 0 ..< Powers:
    parts.add(PowerNames[power] & " " & $sim.treasury[power] & "\u0111")
  parts.join(" \u00b7 ")

proc ledgerText(sim: Sim): string =
  ## The resolved ledger of the last two years — 2 x SeasonsPerYear resolved
  ## seasons, the same window `historyText` shows orders for. `sim.ledger`
  ## is the whole-episode record the endcard draws; the prompt gets the
  ## window the note promises.
  var lines: seq[string]
  var start = 0
  if sim.history.len > 2 * SeasonsPerYear:
    start = sim.history.len - 2 * SeasonsPerYear
  for index in start ..< sim.history.len:
    for power in 0 ..< Powers:
      for entry in sim.history[index].spends[power]:
        if not entry.applied:
          continue
        let payer = PowerNames[entry.power]
        case entry.kind
        of spGift:
          lines.add(payer & " gave " & PowerNames[entry.targetPower] & " " &
            $entry.amount & " ducats")
        of spBribeDisband, spBribeBuy:
          lines.add(payer & " paid " & $entry.amount & " against " &
            entry.targetUnit & " (" & PowerNames[entry.targetPower] & ")")
        of spDefend:
          lines.add(payer & " paid " & $entry.amount & " to keep " &
            entry.targetUnit & " loyal")
        of spAssassinate:
          lines.add(payer & " paid " & $entry.amount & " for a dagger against " &
            PowerNames[entry.targetPower])
  if lines.len == 0:
    return "(nothing has been paid yet)"
  ## A two-year window is bounded but not small; keep the prompt bounded too.
  if lines.len > 40:
    lines = lines[lines.len - 40 .. ^1]
  lines.join("\n")

proc historyText(sim: Sim, power: int): string =
  var lines: seq[string]
  var start = 0
  if sim.history.len > 6:
    start = sim.history.len - 6
  for index in start ..< sim.history.len:
    let record = sim.history[index]
    var parts: seq[string]
    for other in 0 ..< Powers:
      if record.orders[other].len == 0:
        continue
      var texts: seq[string]
      for slot in 0 ..< record.orders[other].len:
        let outcome =
          if slot < record.outcomes[other].len: $record.outcomes[other][slot]
          else: ""
        texts.add(record.orders[other][slot] & " [" & outcome & "]")
      parts.add(PowerNames[other] & ": " & texts.join("; "))
    lines.add(seasonName(record.season) & " " & $record.year & " — " &
      parts.join(" | "))
  discard power
  if lines.len == 0:
    return "(no seasons resolved yet)"
  lines.join("\n")

proc inboxText(sim: Sim, power: int): string =
  var lines: seq[string]
  for letter in sim.pressLast & sim.press:
    if letter.public:
      lines.add(PowerNames[letter.fromPower] & " broadcasts: " & letter.text)
    elif letter.toPower == power:
      lines.add(PowerNames[letter.fromPower] & " writes to you: " & letter.text)
  for pledge in sim.pledges:
    if pledge.fromPower == power or sim.pledgeVisible(pledge, power):
      let target = if pledge.toPower < 0: "ALL" else: PowerNames[pledge.toPower]
      lines.add(PowerNames[pledge.fromPower] & " pledges " & $pledge.kind &
        " to " & target &
        (if pledge.province >= 0: " (" & Provinces[pledge.province].code & ")"
         else: ""))
  if lines.len == 0:
    return "(nobody has written to you)"
  lines.join("\n")

proc shockText(sim: Sim): string =
  var parts: seq[string]
  if sim.famine.len > 0:
    var names: seq[string]
    for province in sim.famine:
      names.add(Provinces[province].name)
    parts.add("FAMINE this year: " & names.join(" and ") &
      " — anything standing there at Winter starves.")
  if sim.plagueCity >= 0:
    parts.add("PLAGUE struck " & Provinces[sim.plagueCity].name &
      " this year; it pays nothing.")
  for rebellion in sim.lastRebellions:
    if rebellion.roll == RebellionFace:
      parts.add(Provinces[rebellion.city].name & " rebelled against " &
        PowerNames[rebellion.power] & ".")
  if parts.len == 0:
    return "(nothing yet)"
  parts.join("\n")

proc legalOrderText(sim: Sim, power: int): string =
  var lines: seq[string]
  for unit in sim.myUnits(power):
    let options = legalOrders(sim.board, unit.province)
    lines.add("  " & unitText(unit) & " (" & Provinces[unit.province].name &
      "): " & options.join(" | "))
  if lines.len == 0:
    return "  (you have no units)"
  lines.join("\n")

proc bribeMenuText(sim: Sim, power: int): string =
  ## The price list, exactly as the validator applies it. The defender's
  ## own `defend` entries ride in the SAME simultaneous batch, so what they
  ## add to these prices is unknowable at prompt time — the menu quotes the
  ## floor and the prompt says a defended unit costs more.
  var lines: seq[string]
  for unit in sim.board.units:
    if unit.power == power:
      continue
    lines.add("  " & unitText(unit) & " (" & PowerNames[unit.power] &
      ") \u2014 disband " & $BribeDisbandCost & ", buy " & $BribeBuyCost)
  if lines.len == 0:
    return "  (there is nothing to buy)"
  lines.sort(system.cmp)
  lines.join("\n")

proc otherPowersText(power: int): string =
  var parts: seq[string]
  for index in 0 ..< Powers:
    if index != power:
      parts.add(PowerPromptNames[index])
  if parts.len < 2:
    return parts.join("")
  parts[0 ..< parts.len - 1].join(", ") & " and " & parts[^1]

proc systemPrompt*(sim: Sim, seat: int): string =
  let power = sim.powerOf[seat]
  "You are " & PowerNames[power] &
    ", one of six powers contending for Renaissance Italy. The others are\n" &
    otherPowersText(power) & ", each played by a different cog.\n" &
    "You never learn who plays them.\n" & """
Rules:
- Armies move on land, fleets on seas and along coasts. Every unit has equal strength; a
  unit takes a province only if it out-supports whatever opposes it, and equal strength
  means a STANDOFF and nobody moves. All six powers order at the same time and see
  nothing of each other's orders until they resolve.
- Orders: HOLD, MOVE, SUPPORT (a hold or a move) and CONVOY (a fleet at sea carrying an
  army between coasts). A supported attack that beats the defence DISLODGES the defender,
  which retreats to the nearest friendly ground or disbands. You may never dislodge your
  own unit or help anyone dislodge it.
- Whoever occupies a city owns it, from that moment. Cities pay 3 ducats each every
  Winter; every unit costs 1 ducat of upkeep; a new unit costs 3 ducats and appears in a
  vacant city you own.
- DUCATS ARE THE OTHER ARMY. In the same submission as your orders you may: GIFT ducats
  to another power (they arrive, always — this is the only promise in the game that
  cannot be broken); BRIBE an enemy unit to disband (9 ducats) or to change sides and
  serve you (15 ducats); DEFEND one of your own units against bribery (every ducat you
  pay raises what a briber must beat); or ASSASSINATE a rival, paying 6 to 30 ducats for
  a roll of two dice — beat the roll and that power's whole court freezes: every one of
  its units holds this season and it sends no letters the next. Money resolves BEFORE the
  armies move, and it is spent whether or not it works. Everything you pay is published.
- Italy bites back: famine marks two provinces each Spring and starves whatever still
  stands there at Winter, plague empties one city every Summer, and a city you own with
  no unit in it may rebel and be lost.
- Hold 12 of the 24 cities and you win outright. Otherwise you are scored on your share
  of the 24 cities plus what is left in your treasury. Nothing else scores.
- LETTERS ARE NOT BINDING. You may promise anything to anyone and then do the opposite.
  So may they. Only ducats that have actually changed hands are real.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply must
begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc commonBlock(sim: Sim, power: int): string =
  result.add("THE BOARD:\n" & sim.boardText() & "\n\n")
  result.add("THE CITIES (24, " & $VictoryCities & " wins outright):\n" &
    sim.cityTableText() & "\n\n")
  result.add("TREASURIES: " & sim.treasuryText() & "\n\n")
  result.add("SHOCKS IN FORCE:\n" & sim.shockText() & "\n\n")
  result.add("THE LEDGER SO FAR:\n" & sim.ledgerText() & "\n\n")
  result.add("RECENT ORDERS:\n" & sim.historyText(power) & "\n\n")
  result.add("YOUR POST:\n" & sim.inboxText(power) & "\n\n")

proc pressPrompt*(sim: Sim, seat: int, prompt: string): string =
  let power = sim.powerOf[seat]
  result.add(seasonName(sim.season) & " " & $sim.year & " \u2014 LETTERS.\n\n")
  result.add(sim.commonBlock(power))
  result.add("YOUR NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"broadcast\":\"\u2026\",\"letters\":" &
    "[{\"to\":\"MILAN\",\"text\":\"\u2026\"}],\"pledges\":" &
    "[{\"to\":\"MILAN\",\"kind\":\"peace\"}],\"notes\":\"\u2026\"} \u2014 " &
    "broadcast at most " & $MaxBroadcastLen & " characters, at most " &
    $MaxLetters & " letters of at most " & $MaxLetterLen &
    " characters each (one per power), at most " & $MaxPledges &
    " pledges, notes at most " & $MaxNotesLen &
    " characters. A pledge is the only promise spectators can watch you " &
    "break; free text is never checked.")

proc ordersPrompt*(sim: Sim, seat: int, prompt: string): string =
  let power = sim.powerOf[seat]
  result.add(seasonName(sim.season) & " " & $sim.year &
    " \u2014 ORDERS AND EXPENDITURE.\n\n")
  result.add(sim.commonBlock(power))
  result.add("YOUR TREASURY: " & $sim.treasury[power] & " ducats.\n\n")
  result.add("YOUR UNITS AND EVERY LEGAL ORDER:\n" &
    sim.legalOrderText(power) & "\n\n")
  result.add("UNITS YOU COULD BRIBE THIS SEASON:\n" &
    sim.bribeMenuText(power) & "\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"orders\":[\"A VER - MAN\"," &
    "\"F VEN S A VER - MAN\"],\"spend\":[{\"action\":\"bribe_buy\"," &
    "\"target\":\"A ROM\",\"amount\":15}],\"notes\":\"\u2026\"} \u2014 " &
    "exactly one order per unit, copied character for character from the " &
    "list above; an order that is not on the list becomes a hold. spend " &
    "is at most " & $MaxSpendEntries & " entries; action is one of gift, " &
    "bribe_disband, bribe_buy, defend, assassinate; target is a power " &
    "name for gift and assassinate and a unit like \"A ROM\" for the " &
    "others; amount is a whole number of ducats you actually have. " &
    "Anything you cannot afford is dropped, in the order you wrote it.")
  if sim.season == seAutumn:
    result.add("\nYou may also send \"builds\":[\"A VEN\",\"F PAL\"] \u2014 " &
      "up to " & $MaxBuilds & " entries, " & $BuildCost &
      " ducats each, executed this Winter in a vacant city you own; a " &
      "fleet only in a coastal city.")

# ---- Reply parsing ----------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating
  ## fences and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CogiavelliError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc parsePress*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## A reply is invalid only when it is not an object or carries neither
  ## `broadcast` nor `letters`. Illegal contents are repaired, never
  ## rejected.
  if payload.kind != JObject:
    raise newException(CogiavelliError, "press reply is not a JSON object")
  let broadcastNode = payload{"broadcast"}
  let lettersNode = payload{"letters"}
  if (broadcastNode.isNil or broadcastNode.kind != JString) and
      (lettersNode.isNil or lettersNode.kind != JArray):
    raise newException(CogiavelliError,
      "press reply has neither a broadcast string nor a letters array")
  if not broadcastNode.isNil and broadcastNode.kind == JString:
    result.broadcast = cleanText(broadcastNode.getStr(), MaxBroadcastLen)
  let power = sim.powerOf[seat]
  if not lettersNode.isNil and lettersNode.kind == JArray:
    for entry in lettersNode:
      if result.letters.len >= MaxLetters or entry.kind != JObject:
        continue
      let target = powerIndex(cleanText(entry{"to"}.getStr(), MaxTargetLen))
      if target < 0 or target == power:
        continue
      result.letters.add(Letter(fromPower: power, toPower: target,
        text: cleanText(entry{"text"}.getStr(), MaxLetterLen), public: false))
  let pledgesNode = payload{"pledges"}
  if not pledgesNode.isNil and pledgesNode.kind == JArray:
    for entry in pledgesNode:
      if result.pledges.len >= MaxPledges or entry.kind != JObject:
        continue
      var kind: PledgeKind
      try:
        kind = parseEnum[PledgeKind](
          entry{"kind"}.getStr().strip().toLowerAscii())
      except ValueError:
        continue
      let target = powerIndex(cleanText(entry{"to"}.getStr(), MaxTargetLen))
      var province = -1
      if kind == plKeepout:
        province = provinceByCode(cleanText(entry{"province"}.getStr(), 8))
        if province < 0 or province >= NumLand:
          continue
      elif target < 0 or target == power:
        continue
      result.pledges.add(Pledge(fromPower: power, toPower: target, kind: kind,
        province: province))
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

proc parseSpendEntry(sim: Sim, power: int, node: JsonNode): SpendEntry =
  ## Returns an entry with `amount == 0` when the entry must be dropped.
  if node.kind != JObject:
    return
  var kind: SpendKind
  try:
    kind = parseEnum[SpendKind](node{"action"}.getStr().strip().toLowerAscii())
  except ValueError:
    return
  let amountNode = node{"amount"}
  var amount = 0
  if amountNode.isNil:
    return
  case amountNode.kind
  of JInt:
    amount = amountNode.getInt()
  of JFloat:
    amount = int(amountNode.getFloat())
  of JString:
    try:
      amount = parseInt(amountNode.getStr().strip())
    except ValueError:
      return
  else:
    return
  if amount < 1 or amount > 999:
    return
  if kind == spAssassinate:
    amount = clamp(amount, AssassinMin, AssassinMax)
  let target = cleanText(node{"target"}.getStr(), MaxTargetLen)
  result = SpendEntry(power: power, kind: kind, targetPower: -1,
    targetProvince: -1, amount: amount)
  case kind
  of spGift, spAssassinate:
    result.targetPower = powerIndex(target)
    if result.targetPower < 0:
      result.why = "notarget"
  of spBribeDisband, spBribeBuy, spDefend:
    let province = parseUnitRef(sim.board, target)
    result.targetProvince = province
    if province < 0:
      result.why = "notarget"
    else:
      result.targetPower = sim.board.unitAt(province).power
      result.targetUnit = unitText(sim.board.unitAt(province))

proc parseOrdersReply*(sim: Sim, seat: int, payload: JsonNode): Decision =
  if payload.kind != JObject:
    raise newException(CogiavelliError, "orders reply is not a JSON object")
  let ordersNode = payload{"orders"}
  if ordersNode.isNil or ordersNode.kind != JArray:
    raise newException(CogiavelliError, "orders reply has no orders array")
  for entry in ordersNode:
    if result.orders.len >= MaxOrders:
      break
    if entry.kind != JString:
      continue
    result.orders.add(cleanText(entry.getStr(), MaxOrderLen))
  let power = sim.powerOf[seat]
  let spendNode = payload{"spend"}
  if not spendNode.isNil and spendNode.kind == JArray:
    for entry in spendNode:
      if result.spend.len >= MaxSpendEntries:
        break
      let parsed = parseSpendEntry(sim, power, entry)
      if parsed.amount == 0:
        continue
      result.spend.add(parsed)
  let buildsNode = payload{"builds"}
  if not buildsNode.isNil and buildsNode.kind == JArray:
    for entry in buildsNode:
      if result.builds.len >= MaxBuilds or entry.kind != JString:
        continue
      result.builds.add(cleanText(entry.getStr(), MaxBuildLen))
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)

# ---- Transport --------------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(CogiavelliError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CogiavelliError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CogiavelliError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(CogiavelliError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(CogiavelliError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogiavelliError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogiavelliError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  phase: PhaseKind,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order, from ONE parallel batch.
  ## Never raises: any failure falls back to the scripted baseline so the
  ## episode always advances. `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skCondottiere else: kind), phase)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user =
        if phase == phPress: pressPrompt(sim, seat, prompts[seat])
        else: ordersPrompt(sim, seat, prompts[seat])
      if attempt > 0:
        user.add(InvalidHint)
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let payload = extractJsonObject(text)
        result[index] =
          if phase == phPress: parsePress(sim, seat, payload)
          else: parseOrdersReply(sim, seat, payload)
      except CatchableError as error:
        echo "cogiavelli llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "cogiavelli: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skCondottiere, phase)
