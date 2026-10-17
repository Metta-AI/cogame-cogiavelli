# Cogiavelli training

The exporter plays complete published matches with six powers. Standard has
four years and private press; gunboat has six years without press. Teachers
alternate the shipped `condottiere` and `banker` policies by seat. Every power
uses the same frozen phase snapshot before orders and expenditure resolve.

```sh
nim c -d:release --path:src -o:/tmp/cogiavelli-posttrain tools/export_posttrain.nim
/tmp/cogiavelli-posttrain /tmp/cogiavelli-data 10 standard plain 0
```

The exporter requires clean committed source and a new output directory.
`trajectories.jsonl` contains private complete-episode evidence; `manifest.json`
records source revision, seeds, wordings, years, scores, and decision counts.
Episodes are written one at a time. Engine-normalized submissions retain the
original proposal and actual accepted submission separately. A repaired proposal
cannot become an accepted teacher target. Later economic and military resolution
is reflected in the episode outcome and replay, not the submitted orders alone.

Convert private events with `coworld.decision_trajectory.read_trajectory_jsonl`
and `export_complete_episodes` from the shared Metta package. Conversion does not
authorize training. `metta_training.posttrain.hosted.export_hosted` requires
external review bound to the complete-episode SHA256 and source revision.
Select `scripted-condottiere` and `scripted-banker` explicitly. The seed family
`cogiavelli-SEED` keeps all wordings and both variants in the same data split.

## Rule wording

`promptVariant` selects `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` uses an explicit nonnegative `promptSeed` to select one
training wording independently of game randomness. Selection remains fixed for
all powers, phases, and retries. `heldout-briefing` and `heldout-reference` are
reserved for evaluation; training resets and teacher exports reject them.
Only the role and opponent introduction varies. Common rules, legal actions,
scoring, private observations, operator guidance, and published budgets remain
unchanged. Canonical wording matches the original numeric bridge.

```sh
/tmp/cogiavelli-train-bridge coworld_manifest_template.json standard --language
python3 tools/test_prompt_variants.py /tmp/cogiavelli-train-bridge
```

The language bridge accepts full press or orders JSON through production parsers.
Its accepted action records the engine-normalized submission, including private
letter deduplication and illegal-order repair. Terminal outcomes include later
phase resolution. Private `semantic_view.prompt_template` records the selected
bank, wording, seed, and exact system/user hashes. Model messages omit metadata.

## Private native evidence

Set `COGAME_SAVE_TRAJECTORY_URI` to a private destination, with
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
Capture preserves actual request bodies, messages, responses, retries, parsed
proposals, and engine-accepted submissions. Authorization headers are excluded.
Failed requests and repaired proposals remain separate from executed fallbacks.
Explicit scripted policies are teachers. Deadline episodes are marked truncated.
Private evidence is written before public results announce completion.

```sh
python3 tools/test_prompt_native_games.py GAME PLAYER OUTPUT SOURCE_REVISION
```

The panel launches six real player processes for each published variant and
wording. A closed local endpoint exercises actual failed requests and fallbacks.
It also runs explicit teachers. Checks compare private observations, request
hashes, accepted submissions, complete replays, and scores under ordinary budgets.
This verifies prompt plumbing and deterministic semantics, not model robustness.
The game-owned transport provides no authenticated serving receipts or token
probabilities; captured requests alone do not qualify on-policy training data.

Historical CPU pilots used the earlier row exporter. One optimizer step changed
validation loss from 1.77859 to 1.77401 for standard and 1.70834 to 1.70291 for
gunboat. Those results do not qualify the new candidate corpus or establish
improved learning or paraphrase robustness.

## Numeric reinforcement learning

`tools/train_bridge.nim` uses the same native simulator and hosted
prompts. Its 531 values encode variant, season, phase, acting power, year,
public treasuries, public city counts, public unit positions, city owners,
and famine. They exclude private letters and pending orders from other
powers. Two choices select the shipped `condottiere` and `banker`
policies. Terminal utilities are the game's native [0, 1] city and
treasury score. Post-training above retains arbitrary legal orders,
press, and expenditure replies.

```sh
nim c -d:release --path:src -o:/tmp/cogiavelli-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/cogiavelli-posttrain /tmp/cogiavelli-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=6` and choose `standard` or `gunboat`.

Both variants completed 512 Metta RL timesteps with the native terminal
score and each power's public numeric observation.

Native PufferLib completed 4,096 CUDA timesteps per variant on metta1.
Reloaded checkpoints on held-out seeds 101 and 102 reported mean scores
0.142795/0.106771 for standard and 0.155903/0.183594 for gunboat.
Checkpoint SHA-256 values were
`3425e3d0a31b14a1f50bb14e48b899eb243a49bf2e9b9f9fd6b53208ff5afc3f`
and `ceb8d3c020fa12750132143736076f3d6f5fc6a98029390fb7aadebb3177fc51`.
