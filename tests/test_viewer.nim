## The viewer contract: the frame carries every key the renderer reads, the
## replay bytes are strict UTF-8 JSON, and the appended chrome block
## declares no name the copied cogame-babel chrome already declares.

import
  std/[json, os, sets, strutils, unicode],
  cogiavelli/[sim, llm]

proc check(condition: bool, message: string) =
  if not condition:
    raise newException(AssertionDefect, message)

proc repoDir(): string =
  currentSourcePath().parentDir().parentDir()

proc newConfig(): GameConfig =
  result = defaultGameConfig()
  result.seed = 7
  result.years = 1
  result.turnDelayMs = 0
  for index in 0 ..< 6:
    result.players.add(PlayerConfig(name: "Policy" & $index))
    result.tokens.add("t")
  result = sampleEpisode(result)

proc playOut(config: GameConfig): Sim =
  var sim = initSim(config)
  var client = LlmClient(disabled: true)
  let prompts = newSeq[string](6)
  var kinds: seq[ScriptKind]
  for index in 0 ..< 6:
    kinds.add(skCondottiere)
  var guard = 0
  while not sim.done and guard < 400:
    guard.inc
    let seats = sim.pendingSeats()
    let phase = sim.phase
    let decisions = decideAll(client, sim, phase, seats, prompts, kinds)
    for index, seat in seats:
      if sim.done:
        break
      if phase == phPress:
        ## Multi-byte press so the replay bytes are exercised for real.
        sim.applyPress(seat, "Bologna \u00e8 di nessuno \u2014 \U0001F3F3",
          @[Letter(fromPower: sim.powerOf[seat],
            toPower: (sim.powerOf[seat] + 1) mod Powers,
            text: "Prendi Torino \u2014 non attraverser\u00f2 il Po " &
              "\U0001F91D")],
          @[], "vault: 12\u0111 \U0001F4B0", true)
      else:
        sim.applyOrders(seat, decisions[index].orders,
          decisions[index].spend, decisions[index].builds,
          "note \u2014 \U0001F5E1", true)
  sim

let episode = playOut(newConfig())

block frameKeys:
  ## The literal list of keys client/renderer.js reads off a frame.
  const wanted = ["seats", "seatOfPower", "units", "owners", "arrows",
    "purses", "daggers", "gifts", "famine", "plague", "rebellions", "stabs",
    "standoffs", "year", "season", "phase", "years", "yearsPlayed", "counts",
    "treasuries", "press", "gameDone", "reason", "conqueror"]
  let frame = episode.tableStateJson()
  for key in wanted:
    check(frame.hasKey(key), "the frame carries " & key)
  const seatKeys = ["power", "name", "cities", "units", "ducats", "score",
    "pending", "eliminated", "paralysed", "stabbedThisTurn", "spentTotal",
    "receivedTotal", "broadcast", "lettersOut", "pledges", "notes"]
  for seat in frame["seats"]:
    for key in seatKeys:
      check(seat.hasKey(key), "every seat carries " & key)
  for unit in frame["units"]:
    for key in ["power", "kind", "province", "dislodged", "bought"]:
      check(unit.hasKey(key), "every unit carries " & key)
  for owner in frame["owners"]:
    check(owner.hasKey("city") and owner.hasKey("power"),
      "every owner row carries city and power")

block strictUtf8:
  var names = newJArray()
  var powers = newJArray()
  var events = newJArray()
  for seat in 0 ..< Seats:
    names.add(%episode.names[seat])
    powers.add(%PowerNames[episode.powerOf[seat]])
  for event in episode.events:
    events.add(event.eventToJson())
  let payload = $ %*{
    "protocol": "cogiavelli.replay.v1",
    "names": names,
    "policyNames": names,
    "powers": powers,
    "config": {"years": episode.config.years, "seed": episode.config.seed,
      "press": episode.config.press, "sampled": true,
      "victoryCities": VictoryCities, "totalCities": TotalCities,
      "map": "italy1499"},
    "events": events,
    "results": episode.resultsJson()
  }
  check(validateUtf8(payload) == -1,
    "the replay payload is strict UTF-8 after a multi-byte press fixture")
  let reparsed = parseJson(payload)
  check(reparsed["events"].len == episode.events.len, "and it re-parses")
  var pressSeen = false
  for event in reparsed["events"]:
    if event["kind"].getStr() == "press":
      pressSeen = true
      check(validateUtf8(event{"broadcast"}.getStr()) == -1,
        "every recorded string is valid UTF-8")
  check(pressSeen, "the fixture actually produced press events")
  for frame in statesFromEvents(episode.config, episode.events):
    check(validateUtf8($frame) == -1, "every re-derived frame is UTF-8")

block chromeScopes:
  ## cogame-tandem, 2026-08-23: a game-block `function markBeat` was
  ## shadowed by the chrome alias block's `var markBeat = C.markBeat`.
  ## Nothing in the appended block may re-declare a chrome name.
  let source = readFile(repoDir() / "client" / "renderer.js")
  const marker = "// ---------- Cogiavelli ----------"
  let cut = source.find(marker)
  check(cut > 0, "the appended block is marked")
  let chrome = source[0 ..< cut]
  let appended = source[cut .. ^1]
  ## A plain scanner, not a regex: std/re needs libpcre, which the CI
  ## runner and the run image do not carry.
  proc names(text: string): HashSet[string] =
    result = initHashSet[string]()
    for line in text.splitLines():
      let trimmed = line.strip(trailing = false)
      let indent = line.len - trimmed.len
      if indent != 2:
        continue
      var rest = ""
      for keyword in ["function ", "var ", "let ", "const "]:
        if trimmed.startsWith(keyword):
          rest = trimmed[keyword.len .. ^1]
          break
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '$'}:
          name.add(ch)
        else:
          break
      if name.len > 0:
        result.incl(name)

  let chromeNames = names(chrome)
  let appendedNames = names(appended)
  check(chromeNames.len > 20, "the chrome declares plenty of names")
  check(appendedNames.len > 10, "so does the appended block")
  let clash = chromeNames * appendedNames
  check(clash.len == 0,
    "the appended block re-declares chrome names: " & $clash)
  check("markDucatBeat" in appendedNames,
    "the beat builder is named markDucatBeat, never markBeat")
  check("buildDucatBar" in appendedNames,
    "the bar builder is named buildDucatBar, never buildScrub")
  check("markBeat" notin appendedNames and "buildScrub" notin appendedNames,
    "no chrome builder name is reused")

block chromeProvenance:
  ## The page keeps every element cogame-babel ships and adds exactly one.
  let page = readFile(repoDir() / "client" / "replay.html")
  for id in ["layout", "stage", "topband", "wordmark", "clock", "topright",
      "statuschip", "feedtoggle", "scorebug", "board-wrap", "table",
      "lightpool", "grain", "endscreen", "transport", "scrub", "play",
      "pos", "feed", "loading"]:
    check(("id=\"" & id & "\"") in page, "replay.html keeps #" & id)
  check("id=\"ducatbar\"" in page, "and adds #ducatbar")
  check("id=\"viewpanel\"" notin page, "no zoom bar is added")
  check("relayout" in page, "the page sets --band and --hudscale on :root")
  let bundle = readFile(repoDir() / "replay-viewer" / "index.html")
  check("id=\"ducatbar\"" in bundle, "the bundle page matches")
  check("cogiavelli_replay.js" in bundle, "and loads this game's wasm module")

block chromeCss:
  let css = readFile(repoDir() / "client" / "chrome.css")
  check(".plate-name { flex: 1 1 auto; min-width: 3.2em; }" in css,
    "policy names do not collapse in a 360px iframe")
  check("--band" in css and "--hudscale" in css,
    "the transport custom properties are declared")
  for kind in ["press", "orders", "spend", "bribe", "assassin", "battle",
      "stab", "cities", "plague", "famine", "winter", "end"]:
    check((".beat-marker." & kind) in css,
      "every beat kind the scrubber emits has a rule: " & kind)
  check("@media (max-width: 640px)" in css and
    "@media (max-width: 420px)" in css, "the small-screen queries are there")

block mapAsset:
  let map = parseJson(readFile(repoDir() / "data" / "italy1499.json"))
  check(map["areas"].len == NumAreas, "the drawn map has all 42 areas")
  var codes: HashSet[string]
  for area in map["areas"]:
    codes.incl(area["code"].getStr())
    check(area["polygon"].len >= 3, "every area is a polygon")
    for key in ["label", "dot", "unit"]:
      check(area.hasKey(key), "every area carries a " & key & " anchor")
  for index in 0 ..< NumAreas:
    check(Provinces[index].code in codes,
      "the drawn map covers " & Provinces[index].code)

echo "test_viewer: ok"
