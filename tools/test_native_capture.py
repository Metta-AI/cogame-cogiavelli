"""Exercise complete native server/player games and preserve all test artifacts."""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        season, year = re.match(r"(SPRING|SUMMER|AUTUMN) (\d+)", user).groups()
        slot = self.headers["X-Coworld-Player-Slot"]
        assert "PRIVATE_OPERATOR_" + slot in user
        assert all("PRIVATE_OPERATOR_" + str(i) not in user for i in range(6) if str(i) != slot)
        assert "SPECTATOR_POLICY_" not in user and "SPECTATOR_POLICY_" not in body["system"]
        retry = "Your previous reply was invalid" in user
        if (year == "1499" and season == "SUMMER") or (year == "1499" and season == "SPRING" and not retry):
            text = "invalid fixture reply"
        else:
            notes = "PRIVATE_CAPTURE_" + slot
            if year == "1499" and season == "AUTUMN":
                notes = "x" * 5000
            if " — LETTERS." in user:
                action = {
                    "broadcast": f"PUBLIC_PHASE_{year}_{season.lower()}_{slot}",
                    "letters": [],
                    "pledges": [],
                    "notes": notes,
                }
            else:
                legal = user.split("YOUR UNITS AND EVERY LEGAL ORDER:\n")[1].split("\n\n")[0]
                orders = re.findall(r"^  [AF] [A-Z]+ \([^\n]*?\): ([^|\n]+)", legal, re.M)
                action = {"orders": [o.strip() for o in orders], "spend": [], "builds": [], "notes": notes}
                if season != "AUTUMN":
                    action.pop("builds")
                if year == "1500" and season == "SPRING":
                    action["orders"] = ["A NOT_A_PROVINCE - NOPE"]
            text = json.dumps(action)
        response = json.dumps(
            {
                "model": body["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": None if year == "1500" and season == "SUMMER" else {"input_tokens": 100, "output_tokens": 20},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(response)


def run(game, player, output, variant, capture, model_enabled=True):
    root = output / f"{variant['id']}-capture{capture}{'' if model_enabled else '-offline'}"
    root.mkdir(mode=0o700)
    config = dict(variant["game_config"])
    seats = 6
    config.update(
        seed=42,
        turnDelayMs=0,
        players=[{"name": f"SPECTATOR_POLICY_{i}"} for i in range(seats)],
        llmTimeoutSeconds=1,
        playerConnectTimeoutSeconds=5,
        episodeTimeoutSeconds=120,
        tokens=[f"fixture-{i}" for i in range(seats)],
    )
    (root / "config.json").write_text(json.dumps(config))
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    env = dict(os.environ)
    for key in (
        "COWORLD_LLM_ENDPOINT",
        "COWORLD_LLM_MODEL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "AWS_BEARER_TOKEN_BEDROCK",
    ):
        env.pop(key, None)
    episode = f"cogiavelli-native-capture-fixture-{variant['id']}"
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID=episode,
        COWORLD_GAME_VERSION="identity-fixture",
        COWORLD_SOURCE_REVISION="a" * 40,
    )
    if not capture:
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    if model_enabled:
        env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{provider.server_port}"
        env["COWORLD_LLM_MODEL"] = "native-capture-fixture"
    children = []
    streams = []
    try:
        log = (root / "game.log").open("wb")
        streams.append(log)
        server = subprocess.Popen([str(game)], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(server)
        for _ in range(100):
            assert server.poll() is None, "game exited before readiness; see retained game.log"
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        else:
            raise TimeoutError("native game did not become ready")
        for seat in range(seats):
            log = (root / f"player-{seat}.log").open("wb")
            streams.append(log)
            player_env = dict(env, PLAYER_PROMPT=f"PRIVATE_OPERATOR_{seat}", COWORLD_TIMEOUT_SECONDS="120")
            player_env["COWORLD_PLAYER_WS_URL"] = f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}"
            children.append(subprocess.Popen([str(player)], env=player_env, stdout=log, stderr=subprocess.STDOUT))
        assert server.wait(timeout=120) == 0
        for child in children[1:]:
            assert child.wait(timeout=5) == 0
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert results["reason"] in ("complete", "conquest")
        assert results["years"] == config["years"] or results["reason"] == "conquest"
        if capture:
            trace = root / "trajectory.jsonl"
            rows = [json.loads(line) for line in trace.read_text().splitlines()]
            assert trace.stat().st_mode & 0o077 == 0
            assert rows[-1]["status"] == "completed" and rows[-1]["outcome"] == results
            assert rows[-1]["seed_family"] == "cogiavelli-42"
            events = [event for event in replay["events"] if event["kind"] in ("press", "orders")]
            assert len(events) == len(rows) - 1
            for event, row in zip(events, rows[:-1], strict=True):
                assert event["seat"] == int(row["seat"])
                assert event["year"] == row["observation"]["year"]
                assert event["season"] == row["observation"]["season"]
                if event["kind"] == "press":
                    action = {
                        "broadcast": event["broadcast"],
                        "letters": [{"to": e["to"], "text": e["text"]} for e in event["letters"] if not e["public"]],
                        "pledges": event["pledges"],
                        "notes": event.get("text", ""),
                    }
                else:
                    powers = ["VENICE", "MILAN", "FLORENCE", "PAPACY", "NAPLES", "TURK"]
                    spend = [
                        {
                            "action": e["kind"],
                            "target": e["targetUnit"] or (powers[e["targetPower"]] if e["targetPower"] >= 0 else ""),
                            "amount": e["amount"],
                        }
                        for e in event["spend"]
                    ]
                    action = {
                        "orders": event["orders"],
                        "spend": spend,
                        "builds": event["builds"],
                        "notes": event.get("text", ""),
                    }
                assert action == row["executed_action"]
                if not model_enabled:
                    assert row["action_status"] == "fallback"
                    assert row["selected_attempt_id"] is None
                    assert len(row["attempts"]) == 1 and row["attempts"][0]["origin"] == "unknown"
                    assert row["attempts"][0]["platform_call_id"] is None
                    continue
                year, season = row["observation"]["year"], row["observation"]["season"]
                attempts = row["attempts"]
                if event["kind"] == "press":
                    assert f"PUBLIC_PHASE_{year}_{season}_" not in json.dumps(row["observation"]["inbox"])
                if year == 1499 and season == "spring":
                    assert len(attempts) == 2 and not attempts[0]["accepted"]
                    assert attempts[1]["accepted"]
                    assert row["selected_attempt_id"] == attempts[1]["attempt_id"]
                elif year == 1499 and season == "summer":
                    assert row["action_status"] == "fallback"
                    assert row["selected_attempt_id"] is None and len(attempts) == 2
                elif year == 1499 and season == "autumn":
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                elif year == 1500 and season == "spring" and event["kind"] == "orders":
                    assert row["action_status"] == "rejected" and row["selected_attempt_id"] is None
                else:
                    assert row["action_status"] == "accepted"
                if year == 1500 and season == "summer":
                    assert attempts[0]["input_tokens"] is None and attempts[0]["output_tokens"] is None
                for attempt in attempts:
                    assert attempt["prompt"][0]["content"] == attempt["request"]["system"]
                    assert attempt["platform_call_id"] is not None and attempt["behavior_logprobs"] is None
                    assert "SPECTATOR_POLICY_" not in json.dumps(attempt["prompt"])
        return results, replay
    finally:
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        for stream in streams:
            stream.close()


def main():
    game, player, destination = map(lambda value: Path(value).resolve(), sys.argv[1:])
    destination.mkdir(mode=0o700, exist_ok=False)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
    for variant in manifest["variants"]:
        captured = run(game, player, destination, variant, True)
        ordinary = run(game, player, destination, variant, False)
        assert captured == ordinary, "capture changed the native outcome or replay"
    captured = run(game, player, destination, manifest["variants"][0], True, model_enabled=False)
    ordinary = run(game, player, destination, manifest["variants"][0], False, model_enabled=False)
    assert captured == ordinary, "capture changed the offline fallback game"
    print(
        "six complete native games: physical replay parity, applied-action joins, retries, fallback, "
        "normalization, privacy, missing usage and offline no-evidence fallback pass"
    )


if __name__ == "__main__":
    main()
