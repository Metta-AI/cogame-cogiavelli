# Cogiavelli training

The exporter plays ten complete native matches per certified variant.
Each decision records the hosted system prompt, the acting power's press
or orders prompt, and a reply accepted by the production parser. Six
powers decide against the same phase snapshot before resolution. Train
and validation sets split whole matches by seed.

```sh
nim c -d:release --path:src -o:/tmp/cogiavelli-posttrain tools/export_posttrain.nim
/tmp/cogiavelli-posttrain /tmp/cogiavelli-data 10 standard
```

The other certified variant is `gunboat`, without the press phase. The
output contains `train.jsonl`, `validation.jsonl`, and a manifest with
source revision, seeds, years played, final scores, and row counts. Ten
matches yielded 1,146/282 standard and 855/207 gunboat train/validation
decisions. The teacher alternates the shipped `condottiere` and `banker`
policies by seat.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/cogiavelli-data --output /tmp/cogiavelli-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

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
