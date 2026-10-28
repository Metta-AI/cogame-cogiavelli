# Cogiavelli training

## Authentic hosted model traces

The scripted exporter below remains a mechanics smoke test. For real model data,
set `COGAME_SAVE_TRAJECTORY_URI` on the ordinary game server. The opt-in private
JSONL artifact records every native press/orders request and returned response,
platform call ID, actual applied action, and retry/fallback/normalization status.
Requests still run as one parallel batch per phase, with the existing retry and
fallback behavior. All private observations are frozen before any seat applies.

Only unmodified model actions can be selected. Optional omitted JSON fields
receive their native empty defaults for the equality check; the stored response
is unchanged. Parser repairs and engine repairs are excluded. Scripted or
credential-free baseline decisions remain unknown-origin and cannot become model
teaching targets. Missing provider usage remains unknown. Authenticate platform
receipts with the maintained research collector before training; a local trace
alone is not model provenance. Scenario families group the native seed across
variants and wording, preserving the existing whole-scenario split convention.

To check the complete production server/player path locally, compile
`src/cogiavelli.nim` and `src/cogiavelli_player.nim`, then run:

```sh
python3 tools/test_native_capture.py bin/cogiavelli bin/cogiavelli-player tmp/native-capture
```

This retains six complete standard/gunboat games: capture on/off replay and
outcome parity, retries, fallback, parser/engine normalization, privacy, missing
usage, and offline fallback. The synthetic provider is system-test evidence,
not an authentic model teacher. Hosted real-model receipt admission and Qwen
training qualification must be measured separately.

The exporter plays ten complete native matches per certified variant.
Each decision records the hosted system prompt, the acting power's press
or orders prompt, and a reply accepted unchanged by the production engine. Six
powers decide against the same phase snapshot before resolution. Train
and validation sets split whole matches by seed.

```sh
nim c -d:release --path:src -o:/tmp/cogiavelli-posttrain tools/export_posttrain.nim
/tmp/cogiavelli-posttrain /tmp/cogiavelli-data 10 standard
```

The other certified variant is `gunboat`, without the press phase. The
output contains `train.jsonl`, `validation.jsonl`, and a manifest with
source revision, seeds, years played, final scores and row counts.
Proposals normalized by the engine are excluded from teacher targets and
counted in the manifest. The teacher alternates the shipped `condottiere` and `banker`
policies by seat.

All 2,490 examples fit 4,096 tokens with the local WordLevel smoke
tokenizer. One CPU optimizer step reduced four-example validation loss
from 1.77859 to 1.77401 for standard and 1.70834 to 1.70291 for gunboat.
This verifies the post-training path, not improved league play.

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.


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

## Prompt fuzzing

The v2 bank varies role, movement and support, simultaneous orders, and nonbinding
diplomacy explanations. Economic prices, disaster rules, scoring and JSON requirements
remain exact. Select `canonical`, `plain`, `numbered`, `questions`, or `reordered`
with `promptVariant`. `mixed` requires a nonnegative `promptSeed` and selects by
seed modulo five without consuming game randomness. One wording lasts the whole game.

Language bridge resets accept these fields with `--language`. Held-out briefing
and reference variants require an evaluation split; teacher exports reject them.
The bridge retains exact private prompt hashes and normalized engine actions.

Append `PROMPT_VARIANT PROMPT_SEED` to export arguments. Mixed export advances the
prompt seed separately within each split and records each selection. This keeps
all five wordings available in training despite every-fifth-seed validation. Episode IDs distinguish wordings;
scenario-family IDs exclude wording and game variant. Keep those families in one
split. Export from committed source. Original train/validation JSONL files remain
the dataset interface; the opt-in hosted evidence above does not change the game action protocol.

`tools/test_prompt_variants.py BRIDGE` plays 16 complete games covering both variants,
seven direct wordings and one mixed selection. Existing training workflows check
20 mixed exported games and numeric play. Scripted checks establish mechanical
invariance, not improved learned-policy robustness.

Episode IDs include requested selection, resolved wording, and prompt seed, so
matched explicit and mixed collections remain distinct. Scenario families stay unchanged.
