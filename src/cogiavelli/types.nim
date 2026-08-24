## Shared value types for Cogiavelli: the runtime config, the board's
## units and orders, the expenditure sheet, press, and the 13-kind event
## log. No IO, no rules — the rules live in `sim.nim`, `adjudicate.nim`
## and `money.nim`.

import std/[json, strutils], mapdata

export mapdata

type
  CogiavelliError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    years*: int           ## years played, starting at 1499
    press*: bool          ## false = gunboat: no letters, only ducats and orders
    episodeTimeoutSeconds*: int ## assumed platform kill time when env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  UnitKind* = enum
    ukArmy = "A"
    ukFleet = "F"

  Unit* = object
    power*: int
    kind*: UnitKind
    province*: int

  OrderKind* = enum
    okHold = "hold"
    okMove = "move"
    okSupportHold = "shold"
    okSupportMove = "smove"
    okConvoy = "convoy"

  Order* = object
    power*: int
    unit*: int          ## province the ordered unit stands in
    kind*: OrderKind
    target*: int        ## move destination; -1 otherwise
    auxFrom*: int       ## supported / convoyed unit's province; -1 otherwise
    auxTo*: int         ## supported / convoyed destination; -1 otherwise
    viaConvoy*: bool
    raw*: string        ## what the seat wrote, before repair
    illegal*: bool
    why*: string        ## parse|nonadjacent|wrongunit|notthere|noconvoy|notowned

  OrderOutcome* = enum
    ooSuccess = "success"
    ooBounce = "bounce"
    ooVoid = "void"
    ooNoConvoy = "noconvoy"
    ooDislodged = "dislodged"
    ooCut = "cut"
    ooIllegal = "illegal"
    ooHeld = "held"

  OrderResult* = object
    power*: int
    unit*: int
    kind*: OrderKind
    target*: int
    auxFrom*: int
    auxTo*: int
    text*: string       ## canonical notation, for the feed
    outcome*: OrderOutcome

  Dislodgement* = object
    unit*: int          ## province the dislodged unit stood in
    attackerFrom*: int

  Retreat* = object
    unit*: int          ## province it was dislodged from
    to*: int            ## destination, or -1 for a disband

  SpendKind* = enum
    spGift = "gift"
    spBribeDisband = "bribe_disband"
    spBribeBuy = "bribe_buy"
    spDefend = "defend"
    spAssassinate = "assassinate"

  SpendEntry* = object
    power*: int
    kind*: SpendKind
    targetPower*: int   ## gift / assassinate target, or the unit's owner
    targetProvince*: int ## province of the targeted unit; -1 otherwise
    targetUnit*: string ## "A ROM" as written back to spectators; "" otherwise
    amount*: int
    applied*: bool      ## the entry was paid for (it may still have failed)
    why*: string        ## "" | insufficient | notarget | illegal | outbid |
                        ## defended | bought | disbanded | missed | landed

  Letter* = object
    fromPower*: int
    toPower*: int       ## -1 = ALL
    text*: string
    public*: bool

  PledgeKind* = enum
    plPeace = "peace"
    plKeepout = "keepout"
    plSupport = "support"

  Pledge* = object
    fromPower*: int
    toPower*: int       ## -1 = ALL
    kind*: PledgeKind
    province*: int      ## keepout only; -1 otherwise
    broken*: bool
    brokenBy*: string

  Stab* = object
    power*: int
    pledgeTo*: int
    kind*: PledgeKind
    province*: int
    order*: string

  Season* = enum
    seSpring = "spring"
    seSummer = "summer"
    seAutumn = "autumn"
    seWinter = "winter"

  PhaseKind* = enum
    phPress = "press"
    phOrders = "orders"
    phResolve = "resolve"
    phWinter = "winter"

  Rebellion* = object
    city*: int
    power*: int
    roll*: int

  BuildRecord* = object
    power*: int
    entry*: string
    applied*: bool
    why*: string

  EventKind* = enum
    evStart = "start"
    evSeason = "season"
    evFamine = "famine"
    evPress = "press"
    evOrders = "orders"
    evSpend = "spend"
    evAssassin = "assassin"
    evBribe = "bribe"
    evBattle = "battle"
    evCities = "cities"
    evPlague = "plague"
    evWinter = "winter"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    year*: int
    season*: Season
    phaseKind*: PhaseKind
    seat*: int
    power*: int
    scripted*: bool
    text*: string             ## press/orders: notes; end: reason
    ## board snapshots (start, season, cities, winter, end)
    units*: seq[Unit]
    owners*: seq[int]         ## 24 city owners, -1 = neutral
    treasury*: seq[int]
    cityCounts*: seq[int]
    seed*: int
    ## famine / plague
    provinces*: seq[int]
    province*: int
    killed*: seq[Unit]
    ## press
    broadcast*: string
    letters*: seq[Letter]
    pledges*: seq[Pledge]
    ## orders
    orders*: seq[string]
    illegalRaw*: seq[string]
    illegalWhy*: seq[string]
    buildTexts*: seq[string]  ## Autumn: the builds Winter will execute
    ## spend / assassin / bribe
    entries*: seq[SpendEntry]
    treasuryAfter*: int
    target*: int
    amount*: int
    d1*: int
    d2*: int
    roll*: int
    success*: bool
    targetUnit*: string
    targetPower*: int
    bribeKind*: SpendKind
    defence*: int
    outcome*: string
    ## battle
    results*: seq[OrderResult]
    dislodged*: seq[Dislodgement]
    retreats*: seq[Retreat]
    standoffs*: seq[int]
    stabs*: seq[Stab]
    ## cities
    gained*: seq[seq[int]]
    lost*: seq[seq[int]]
    ## winter
    rebellions*: seq[Rebellion]
    famineKills*: seq[Unit]
    income*: seq[int]
    incomeDraws*: seq[int]
    upkeep*: seq[int]
    upkeepDisbands*: seq[Unit]
    builds*: seq[BuildRecord]
    ## end
    cities*: seq[int]
    conqueror*: string

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    years: 4,
    press: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 300,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 1200,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CogiavelliError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("years"):
    config.years = node["years"].getInt()
  if node.hasKey("press"):
    config.press = node["press"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.years < 1:
    raise newException(CogiavelliError, "years must be at least 1")
