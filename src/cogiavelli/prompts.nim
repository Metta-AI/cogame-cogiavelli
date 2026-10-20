## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "cogiavelli-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc introduction*(selection: PromptSelection, power, others: string): string =
  let introductions = [
    "You are " & power &
      ", one of six powers contending for Renaissance Italy. The others are\n" &
      others & ", each played by a different cog.\n" &
      "You never learn who plays them.\n",
    "You play " & power & " among six rival powers in Renaissance Italy.\n" &
      "The other powers are " & others & ". Each has a different cog player;\n" &
      "their identities are never revealed to you.\n",
    "Your briefing:\n1. Your power is " & power & ".\n" &
      "2. Six powers compete for Renaissance Italy.\n" &
      "3. The other powers are " & others & ".\n" &
      "4. A different cog plays each opponent. You never learn who they are.\n",
    "Who are you? " & power & ", one of six powers competing for Renaissance Italy.\n" &
      "Who are the others? " & others & ".\n" &
      "Who plays them? A different cog for each power; their identities remain unknown to you.\n",
    "Six powers contend for Renaissance Italy. Your opponents are " & others & ".\n" &
      "Each opponent is played by a different cog whose identity you never learn.\n" &
      "Your power is " & power & ".\n",
    "Take the role of " & power & " in a six-power contest for Renaissance Italy.\n" &
      "You face " & others & ". Each is controlled by a different cog,\n" &
      "and you will never be told who those players are.\n",
    "Role reference\nYour power: " & power & ".\n" &
      "Setting: six powers contending for Renaissance Italy.\n" &
      "Other powers: " & others & ".\n" &
      "Opposing players: a different cog per power; identities are never disclosed to you.\n"
  ]
  introductions[ord(selection.selectedVariant)]

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

const WarfareBriefings = [
  "- Armies move on land, fleets on seas and along coasts. Every unit has equal strength; a\n  unit takes a province only if it out-supports whatever opposes it, and equal strength\n  means a STANDOFF and nobody moves. All six powers order at the same time and see\n  nothing of each other's orders until they resolve.\n- Orders: HOLD, MOVE, SUPPORT (a hold or a move) and CONVOY (a fleet at sea carrying an\n  army between coasts). A supported attack that beats the defence DISLODGES the defender,\n  which retreats to the nearest friendly ground or disbands. You may never dislodge your\n  own unit or help anyone dislodge it.\n",
  "Armies travel on land; fleets travel at sea and along coasts. Units have equal strength. Taking a province requires more support than the opposition; a tie is a standoff in which nobody moves. All six powers submit simultaneously, keeping orders hidden until resolution. Choose HOLD, MOVE, SUPPORT for a hold or move, or CONVOY to carry an army between coasts using a fleet at sea. An attack stronger than the defence dislodges its defender, which retreats to the nearest friendly ground or disbands. Never dislodge your own unit or support its dislodgement.\n",
  "Warfare rules:\n1. Armies move on land; fleets move on seas and coasts.\n2. All units have equal strength. A province is taken only with superior support; equal strength means a standoff and no movement.\n3. Six powers order simultaneously and see no opposing orders before resolution.\n4. Orders are HOLD, MOVE, SUPPORT (hold or move), and CONVOY (an army between coasts via a fleet at sea).\n5. A supported attack beating the defence dislodges the defender to the nearest friendly ground, or it disbands. You cannot dislodge your own unit or help another power do so.\n",
  "Where do units move? Armies on land, fleets at sea and along coasts. How do they take a province? All units have equal strength, so the attacker must out-support its opposition; equal strength produces a standoff and nobody moves. When are orders visible? All six powers choose simultaneously; opposing orders stay hidden until resolution. Which orders exist? HOLD, MOVE, SUPPORT a hold or move, and CONVOY an army between coasts with a fleet at sea. What happens when an attack beats the defence? The defender is dislodged and retreats to the nearest friendly ground or disbands. You may not dislodge your own unit or assist that outcome.\n",
  "All six powers issue orders simultaneously and learn others' orders only when they resolve. Orders are HOLD, MOVE, SUPPORT a hold or move, and CONVOY an army between coasts using a fleet at sea. Armies move on land and fleets at sea or along coasts. Each unit has equal strength: superior support takes a province, while equal strength creates a standoff and no movement. A supported attack exceeding the defence dislodges the defender, which retreats to the nearest friendly ground or disbands. Dislodging your own unit, or helping another power do so, is forbidden.\n",
  "Military briefing: move armies over land and fleets over sea or coast. Unit strength is equal; securing a province requires out-supporting the opposition. Ties leave everyone in a standoff without movement. The six powers choose together, and their orders stay secret until resolution. Use HOLD, MOVE, SUPPORT (hold or move), or CONVOY (a fleet at sea transports an army between coasts). A supported attack beating defence dislodges the defender; it retreats to the nearest friendly ground or disbands. Never dislodge your own unit or aid its dislodgement.\n",
  "Military reference\nMovement: armies on land; fleets at sea and on coasts.\nStrength: equal per unit; superior support takes the province; a tie is a standoff with nobody moving.\nTiming: six simultaneous submissions; orders hidden until resolution.\nOrders: HOLD, MOVE, SUPPORT (hold or move), CONVOY (army between coasts via fleet at sea).\nDislodgement: a supported attack beats defence; defender retreats to nearest friendly ground or disbands.\nRestriction: no dislodging your own units or assisting another power to do so.\n"
]

const DiplomacyBriefings = [
  "- LETTERS ARE NOT BINDING. You may promise anything to anyone and then do the opposite.\n  So may they. Only ducats that have actually changed hands are real.\n\n",
  "Letters do not bind either side. You can promise something and act against it, and so can every opponent. Only ducats already transferred are real commitments.\n\n",
  "Diplomacy rules:\n1. Letters are nonbinding.\n2. Any power may contradict its promises, including you.\n3. Only ducats that have actually changed hands are real.\n\n",
  "Do letters bind you or your rivals? No. Anyone may promise one thing and do the opposite. What is real? Only ducats that have actually changed hands.\n\n",
  "Only transferred ducats are real. Letters bind no one: you and your rivals may promise anything and then do the opposite.\n\n",
  "Diplomatic briefing: treat letters as nonbinding promises. Both you and your opponents can act contrary to them. Only ducats already handed over are real.\n\n",
  "Diplomacy reference: letters are nonbinding; every power can break its promises. Only ducats that have actually changed hands are real.\n\n"
]

proc warfareBriefing*(selection: PromptSelection): string =
  WarfareBriefings[ord(selection.selectedVariant)]

proc diplomacyBriefing*(selection: PromptSelection): string =
  DiplomacyBriefings[ord(selection.selectedVariant)]
