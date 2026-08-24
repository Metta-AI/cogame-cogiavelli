## Cogiavelli player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Cogiavelli strategy), then spectates until the final frame. All
## of the actual decision making happens inside the game server, which
## sends this seat's prompt to Claude whenever the table needs letters or
## orders.
##
## PLAYER_SCRIPTED=condottiere|banker registers the seat as one of the
## built-in rule-based baselines instead: the server plays it
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogiavelli-image> --name my-cogiavelli \
##     --run /bin/cogiavelli-player --secret-env PLAYER_PROMPT="<strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Take the neutral cities first and hold them with a unit inside, because an
empty city rebels. Keep a reserve of at least fifteen ducats: a bribe that
buys a neighbour's army at the right moment is worth two campaigns, and a
defended unit is cheaper than a lost one. Promise peace to the strongest
power and mean it until you can afford not to.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "cogiavelli player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "cogiavelli player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send merely queues, so the
  ## game's quit(0) can outrun the flushed final frame. Treat a dead socket
  ## as a normal end of episode and exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "cogiavelli player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "cogiavelli player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"power"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "cogiavelli player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "cogiavelli player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "cogiavelli player: socket ended (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
