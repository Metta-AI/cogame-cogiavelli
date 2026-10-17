"""Complete six-power games preserve private press, orders, and outcomes across wording."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
DIRECT = TRAIN + ["heldout-briefing", "heldout-reference"]
POWERS = ["VENICE", "MILAN", "FLORENCE", "PAPACY", "NAPLES", "TURK"]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


for game, maximum in (("standard", 144), ("gunboat", 108)):
    with subprocess.Popen(
        [BINARY, MANIFEST, game, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        for seed in ("17", "946001"):
            canonical = None
            direct = []
            for choice, prompt_seed in [(v, 0) for v in DIRECT] + [
                ("mixed", i) for i in range(5)
            ]:
                obs = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 6,
                        "split": "validation" if seed == "17" else "test",
                        "promptVariant": choice,
                        "promptSeed": prompt_seed,
                    },
                )
                trace, systems = [], {}
                while obs["kind"] == "decision":
                    view = obs["semantic_view"]
                    metadata = view.pop("prompt_template")
                    selected = TRAIN[prompt_seed] if choice == "mixed" else choice
                    assert metadata == {
                        "bank": "cogiavelli-rules-v1",
                        "variant": selected,
                        "selection": choice,
                        "seed": prompt_seed,
                        "system_sha256": hashlib.sha256(
                            obs["messages"][0]["content"].encode()
                        ).hexdigest(),
                        "user_sha256": hashlib.sha256(
                            obs["messages"][1]["content"].encode()
                        ).hexdigest(),
                    }
                    system, user = [message["content"] for message in obs["messages"]]
                    assert systems.setdefault(obs["seat"], system) == system
                    assert (
                        "prompt_template" not in user and "prompt_selection" not in user
                    )
                    power = view["power"]
                    for index, sender in enumerate(POWERS):
                        recipient = POWERS[(index + 1) % len(POWERS)]
                        if power not in (sender, recipient):
                            assert f"SECRET-{sender}" not in user
                            assert all(
                                f"SECRET-{sender}" not in letter["text"]
                                for letter in view["inbox"]
                            )
                        if power != sender:
                            assert f"PRIVATE-{sender}" not in user
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    action["notes"] = f"PRIVATE-{power}"
                    if view["phase"] == "press":
                        action["letters"] = [
                            {
                                "to": POWERS[(POWERS.index(power) + 1) % len(POWERS)],
                                "text": f"SECRET-{power}",
                            }
                        ]
                        action["letters"].append(
                            {
                                "to": action["letters"][0]["to"],
                                "text": f"DROPPED-SECRET-{power}",
                            }
                        )
                    response = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": obs["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert response["kind"] == "accepted"
                    assert response["action"]["notes"] == action["notes"]
                    if view["phase"] == "press":
                        assert response["action"]["letters"] == action["letters"][:1]
                    trace.append((view, user, response["action"]))
                    assert len(trace) <= maximum
                    obs = response["observation"]
                assert obs["kind"] == "terminal" and trace and len(systems) == 6
                outcome = trace, obs
                if choice == "canonical":
                    canonical = outcome
                else:
                    assert outcome == canonical
                if choice == "mixed":
                    assert systems == direct[prompt_seed]
                else:
                    assert systems not in direct
                    direct.append(systems)
                print(
                    game,
                    seed,
                    choice,
                    prompt_seed,
                    len(trace),
                    "complete-game decisions; private press/hash/action/outcome parity PASS",
                    obs["scores"],
                    flush=True,
                )
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0

for language in (False, True):
    invalids = [
        {"promptVariant": value}
        for value in ("heldout-briefing", "heldout-reference", "unknown", "mixed")
    ]
    invalids += [
        {"promptVariant": "mixed", "promptSeed": value} for value in (-1, True, 1.5)
    ]
    invalids += [{"split": "unknown"}]
    if not language:
        invalids.append({"promptVariant": "plain"})
    for invalid in invalids:
        result = subprocess.run(
            [BINARY, MANIFEST, "standard"] + (["--language"] if language else []),
            input=json.dumps({"kind": "reset", "seed": "17", "players": 6} | invalid)
            + "\n",
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

if len(sys.argv) == 3:
    for game in ("standard", "gunboat"):
        processes = [
            subprocess.Popen(
                [str(Path(binary).resolve()), MANIFEST, game],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for binary in (sys.argv[2], BINARY)
        ]
        try:
            for seed in ("17", "946001"):
                observations = [
                    request(p, {"kind": "reset", "seed": seed, "players": 6})
                    for p in processes
                ]
                steps = 0
                while observations[0]["kind"] == "decision":
                    assert observations[0] == observations[1]
                    encodings = [request(p, {"kind": "encode"}) for p in processes]
                    assert encodings[0] == encodings[1]
                    assert (
                        len(encodings[0]["values"]) == 531
                        and len(encodings[0]["actions"]) == 2
                    )
                    results = [
                        request(
                            p,
                            {
                                "kind": "step",
                                "decision_id": obs["decision_id"],
                                "response": json.dumps({"choice": steps % 2}),
                            },
                        )
                        for p, obs in zip(processes, observations, strict=True)
                    ]
                    assert results[0] == results[1]
                    observations = [result["observation"] for result in results]
                    steps += 1
                    assert steps <= 144
                assert (
                    observations[0]["kind"] == "terminal"
                    and observations[0] == observations[1]
                )
                print(
                    game, seed, "original numeric complete-game parity PASS", flush=True
                )
        finally:
            for process in processes:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
