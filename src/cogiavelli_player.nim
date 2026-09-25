## Cogiavelli player: chooses complete press or orders actions from its view.

import std/[json, options, os, strutils, times]
import whisky
import cogiavelli/[llm, jev_policy]

const DefaultPrompt = """
Take neutral cities first and hold them with a unit inside. Keep a reserve of
at least fifteen ducats. Promise peace to the strongest power and mean it
until you can afford not to.
"""
const
  ReceivePollMs = 5_000
  SpectateGraceSeconds = 120.0
  DefaultEpisodeTimeoutSeconds = 1200.0

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT", DefaultPrompt)
  let scripted = parseScriptKind(getEnv("PLAYER_SCRIPTED"))
  let jev = getEnv("PLAYER_POLICY").strip().toLowerAscii() == "jev"
  let client = if scripted == skNone and not jev: newLlmClient() else: nil
  let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
  var timeoutSeconds = if hostedTimeout.len > 0:
    parseFloat(hostedTimeout) else: DefaultEpisodeTimeoutSeconds
  if timeoutSeconds <= 0:
    timeoutSeconds = DefaultEpisodeTimeoutSeconds
  let deadline = epochTime() + timeoutSeconds + SpectateGraceSeconds
  echo "cogiavelli player: connecting to game"
  let socket = newWebSocket(url)
  try:
    while epochTime() < deadline:
      let received = socket.receiveMessage(ReceivePollMs)
      if received.isNone:
        continue
      let message = received.get()
      if message.kind != TextMessage:
        continue
      let payload = parseJson(message.data)
      case payload["type"].getStr()
      of "welcome":
        echo "cogiavelli player: seated at slot ", payload["slot"].getInt()
      of "turn":
        let view = payload["view"]
        let baselines = payload["baselines"]
        var action: JsonNode
        var usedScript = false
        if scripted != skNone:
          action = baselines[$scripted]
          usedScript = true
        elif jev:
          if jevAvailable():
            action = chooseJevAction(view, baselines, prompt)
          else:
            action = baselines["condottiere"]
            usedScript = true
        elif client.disabled:
          action = baselines["condottiere"]
          usedScript = true
        else:
          action = client.completeJson(payload["system"].getStr(),
            payload["user"].getStr() & "\nOperator strategy: " & prompt)
        socket.send($ %*{"type": "decision", "id": payload["id"],
          "action": action, "scripted": usedScript})
      of "final":
        echo "cogiavelli player: final scores ", payload["scores"]
        break
      else:
        discard
  except CatchableError as error:
    echo "cogiavelli player: socket ended (", error.msg, ")"
  socket.close()
