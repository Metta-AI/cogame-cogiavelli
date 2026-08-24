# cogame-cogiavelli

**Diplomacy's adjudicator on a Renaissance-Italy board, with a treasury bolted on.**
Six LLM-piloted powers — **VENICE, MILAN, FLORENCE, the PAPACY, NAPLES** and **the TURK** — contend
for twenty-four Italian cities across three seasons a year. Orders are Diplomacy's. The expenditure
sheet is what Diplomacy leaves out.

Live at **[softmax.com/cogiavelli](https://softmax.com/cogiavelli)**.

---

## The game in one screen

Every season, all six powers write **at the same moment**:

* **press** — one public broadcast, up to five private letters, up to four pledges. Nothing said
  here binds anything.
* **orders** — one per unit: `HOLD`, `MOVE`, `SUPPORT`, `CONVOY`.
* **an expenditure sheet** — up to six entries, resolved **before the armies move** and spent
  whether or not they work:

| entry | cost | what it does |
| --- | --- | --- |
| `gift` | any | arrives instantly and can never be taken back — the only binding promise in the game |
| `bribe_disband` | 9 + defence | the enemy unit disbands |
| `bribe_buy` | 15 + defence | the enemy unit **changes sides where it stands** and holds this season |
| `defend` | any | every ducat raises what a briber must beat on one of your own units |
| `assassinate` | 6–30 | two dice; beat the roll and the target's whole court freezes for a season |

Then Italy bites back: **famine** marks two provinces each Spring and starves what stands there at
Winter, **plague** empties one city each Summer, a city you own with **no unit in it** may rebel,
and every unit costs a ducat of upkeep.

Whoever occupies a city owns it, from that moment, **every season**. Hold **12 of the 24** and you
win outright; otherwise you are scored on `(cities + min(ducats, 24) / 24) / 24` — city share plus a
treasury term worth at most one city.

The full rules are in the manifest's `rules.md`; the board is in `map.md`; the design note is
[`docs/plans/2026-08-24-cogiavelli-design.md`](docs/plans/2026-08-24-cogiavelli-design.md).

## A policy is just a prompt

The player container's only job is to deliver a prompt. The game server composes each seat's view —
the whole board, the city table, **every** treasury, the two-year ledger, the press that seat
received, the **complete list of its legal orders** in the exact notation a reply must use, and the
**exact price of every bribable enemy unit** — and asks Claude what to write, order and spend. All
six seats go out as **one parallel batch per phase**.

```bash
coworld upload-policy coworld-cogiavelli:latest \
  --name my-cogiavelli --run /bin/cogiavelli-player \
  --secret-env PLAYER_PROMPT="Take the neutral cities first and garrison them…"
```

Two scripted baselines ship in the same image, env-switched, and play any seat that registers as
scripted — and **every** seat when no LLM credentials are available, so episodes always complete:

* `PLAYER_SCRIPTED=condottiere` — the expander. Walks toward the nearest city it does not own,
  never stands itself off, disbands a threatening neighbour for nine ducats, builds while upkeep
  stays covered.
* `PLAYER_SCRIPTED=banker` — the wall with a vault. Every unit holds, four ducats of loyalty on each
  garrison, never attacks, never bribes, ends rich, small and un-bribable.

## Two name spaces

In game a seat is **only ever a power name** — `VENICE` — plus an anonymous cog alias. Prompts,
press, orders and the player socket never carry a policy name, a player name or a slot index, and
`tests/test_sim.nim` scans every built prompt for every configured policy name to keep it that way.
Spectator-side the replay carries `powers`, `names` (aliases) **and** `policyNames`, so the viewer
renders `VENICE · daveey` and `results.json` attributes by policy.

## Repo layout

| path | what |
| --- | --- |
| `src/cogiavelli/mapdata.nim` | the 42-area board, compiled in: both movement graphs, the 24 cities, the 18 starting units |
| `src/cogiavelli/types.nim` | config, units, orders, the expenditure sheet, press, the 13 event kinds |
| `src/cogiavelli/orders.nim` | one grammar for parsing and printing, plus the legal order set a seat is handed |
| `src/cogiavelli/adjudicate.nim` | the Diplomacy core: four strengths, cut supports, circular movement, Szykman |
| `src/cogiavelli/money.nim` | payment, daggers, bribes, and Winter's rebellions, famine, income, upkeep and builds |
| `src/cogiavelli/sim.nim` | the episode: seasons, the shock stream, scoring, `tableStateJson`, `replayMatch` |
| `src/cogiavelli/llm.nim` | one batched `decideAll` per phase, the prompts, the reply parsers, the baselines |
| `src/cogiavelli/server.nim` | the Coworld game contract, the season loop, the artifacts |
| `client/` | the viewer chrome — `cogame-babel`'s `renderer.js` and `chrome.css` with an appended Cogiavelli block |
| `replay-viewer/` | the static wasm bundle: the **same** sim compiled to wasm, so the browser re-derives every frame |
| `data/italy1499.json` | the hand-authored vector map (42 polygons, label anchors, city dots, unit anchors) |
| `scripts/art/` | the map generator and the nano-banana sprite sheet with its split script |
| `tests/` | map, adjudication, money, episode, baselines, scoring, viewer |

## Building and running

The whole toolchain lives in CI; the repo builds with [nimby](https://github.com/treeform/nimby):

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
# the committed nim.cfg is gitignored: regenerate it for this machine
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim          # every tests/*.nim runs in CI twice, debug and release
docker compose build                          # one image, two entrypoints
./tools/ci/docker_smoke.sh coworld-cogiavelli:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

## The replay

Replays are a **static file plus a browser wasm viewer, never a pod**. `tools/build_replay_viewer.sh`
compiles `replay-viewer/cogiavelli_replay.nim` — the same `sim`, the same adjudicator, the same
seeded shock stream the server ran — to wasm and bundles it with `renderer.js`, `chrome.css` and the
board art. The bytes are self-sufficient: the seed re-derives the seat→power permutation, the aliases
and every draw; the events carry every letter, pledge, order, ledger entry, dagger roll, adjudication
result, retreat, ownership table, plague, famine, rebellion, income and build. The viewer contacts
nothing but S3 for the `.replay` file.

## Art

`data/italy1499.json` is generated by `scripts/art/build_map.py`, which places each province as a
hand-positioned disc, partitions the grid to the nearest seed of the same kind (land or sea), and
traces the region outlines as **one planar graph** so two provinces that share a border emit exactly
the same vertices and abut with no seam. `data/purse.png`, `data/dagger.png` and `data/die.png` are
split out of the committed nano-banana sheet `scripts/art/source/ducat_items_sheet.png` by
`scripts/art/split_items_sheet.py`.

MIT licensed. Built with [coworld-builder](https://github.com/Metta-AI/coworld-builder).
