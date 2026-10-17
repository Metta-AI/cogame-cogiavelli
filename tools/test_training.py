"""Exercise both certified variants through full native training matches."""

import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "coworld_manifest_template.json"
EXPORTER = Path(sys.argv[1]).resolve()
BRIDGE = Path(sys.argv[2]).resolve()

with tempfile.TemporaryDirectory() as directory:
    for variant in ("standard", "gunboat"):
        output = Path(directory) / variant
        subprocess.run(
            [str(EXPORTER), str(output), "10", variant], cwd=ROOT, check=True
        )
        manifest = json.loads((output / "manifest.json").read_text())
        source = output / "trajectories.jsonl"
        episodes, decisions = [], 0
        assert source.stat().st_mode & 0o777 == 0o600
        assert not (output / "train.jsonl").exists()
        assert not (output / "validation.jsonl").exists()
        with source.open() as stream:
            for line in stream:
                row = json.loads(line)
                assert row["source_revision"] == manifest["source_revision"]
                if row["event_type"] == "episode":
                    episodes.append(row)
                    continue
                decisions += 1
                (attempt,) = row["attempts"]
                assert attempt["origin"] == "teacher"
                assert "THE BOARD:" in attempt["prompt"][1]["content"]
                assert "Player1" not in json.dumps(attempt["prompt"])
                reply = json.loads(attempt["response"])
                assert reply == attempt["parsed_action"]
                if "LETTERS" in attempt["prompt"][1]["content"]:
                    assert set(reply) == {"broadcast", "letters", "pledges", "notes"}
                else:
                    assert set(reply) == {"orders", "spend", "builds", "notes"}
                if row["action_status"] == "accepted":
                    assert attempt["accepted"] and row["executed_action"] == reply
                else:
                    assert (
                        not attempt["accepted"] and row["selected_attempt_id"] is None
                    )
                    assert row["fallback_origin"] == "engine-normalized-submission"
        assert len(episodes) == len(manifest["runs"]) == 10
        assert decisions == sum(run["decisions"] for run in manifest["runs"])
        assert {row["seed_family"] for row in episodes} == {
            f"cogiavelli-{seed}" for seed in range(1, 11)
        }
        assert all(row["status"] == "completed" for row in episodes)
        assert all(
            run["reason"] in ("complete", "conquest") and len(run["scores"]) == 6
            for run in manifest["runs"]
        )

        for teacher in (True, False):
            process = subprocess.Popen(
                [str(BRIDGE), str(MANIFEST), variant],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd="/tmp",
            )
            assert process.stdin is not None and process.stdout is not None
            rng = random.Random(13)

            def request(payload: dict) -> dict:
                process.stdin.write(json.dumps(payload) + "\n")
                process.stdin.flush()
                return json.loads(process.stdout.readline())

            try:
                observation = request(
                    {
                        "kind": "reset",
                        "players": 6,
                        "seed": f"cogiavelli-{variant}-{teacher}",
                    }
                )
                decisions = 0
                while observation["kind"] == "decision":
                    assert observation["seat"] in range(6)
                    assert observation["decision_id"] == decisions
                    assert "THE BOARD:" in observation["semantic_view"]["user"]
                    encoded = request({"kind": "encode"})
                    assert len(encoded["values"]) == 531
                    assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                    action = (
                        json.loads(request({"kind": "teacher"})["response"])
                        if teacher
                        else rng.choice(encoded["actions"])
                    )
                    accepted = request(
                        {
                            "kind": "step",
                            "decision_id": decisions,
                            "response": json.dumps(action),
                        }
                    )
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                    assert decisions <= 500
                assert set(observation["scores"]) == set(map(str, range(6)))
                assert observation["utilities"] == observation["scores"]
                assert all(0 <= score <= 1 for score in observation["scores"].values())
                print(variant, "teacher" if teacher else "random", decisions)
            finally:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
