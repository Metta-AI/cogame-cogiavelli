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

const PromptBankVersion* = "cogiavelli-rules-v1"

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
