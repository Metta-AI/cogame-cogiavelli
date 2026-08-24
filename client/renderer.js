// Babel shared renderer + drivers.
//
// One canvas scene (two booths — one per pair — each with a speaker cog and
// its scene card, the glyph ribbon carrying the message, and a listener cog
// with its four-card lineup; names, tallies and private-notes parchments
// under every cog) fed by three drivers: live /global websocket, live
// /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side /
// wasm-side; this file only draws state objects:
//   {seats:[{name,score,correct,asSpeaker,asListener,role,partner,notes} ×4],
//    round, rounds, roundsPlayed, glyphs[16], perm[4][16],
//    pairs:[{speaker,listener,target,lineup[4],tokens|null,pick|null,
//            correct|null} ×2],
//    phase:"speak0|pick0|speak1|pick1|between|done", gameDone, reason}
// Spectators always see the CANONICAL alphabet (glyphs[t]); the per-seat
// permutations are the agents' problem, not the audience's.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Babel
  // seats four cogs: red, blue, green, yellow. The extra colours stay so
  // the chrome's seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  // The pick verdict (green flash / red shake + amber truth) holds for a
  // beat, then fades down to a resting tint so a paused frame still reads.
  var PICK_HOLD_MS = 2500;
  var PICK_FADE_MS = 700;
  var PICK_REST = 0.35;
  var SHAKE_MS = 600;
  var RIBBON_SLIDE_MS = 420;

  // Symbols fall through to a system symbol font when rajdhani lacks them.
  var GLYPH_FONT = "'rajdhani', 'Apple Symbols', 'Segoe UI Symbol', " +
    "'Noto Sans Symbols 2', system-ui, sans-serif";

  var SHAPES = ["circle", "square", "triangle", "star"];
  var COLOURS = ["red", "blue", "green", "yellow"];
  var LETTERS = "ABCD";

  // Scene id = shape*16 + colour*4 + count; count 0..3 means 1..4 items.
  function sceneOf(id) {
    if (typeof id !== "number" || id < 0 || id > 63) return null;
    return { shape: id >> 4, colour: (id >> 2) & 3, count: (id & 3) + 1 };
  }

  function sceneText(id) {
    var s = sceneOf(id);
    if (!s) return "?";
    return s.count + " " + COLOURS[s.colour] + " " + SHAPES[s.shape] +
      (s.count === 1 ? "" : "s");
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    // COGIAVELLI hook: the board sprites the appended block draws.
    names = names.concat(["purse.png", "dagger.png", "die.png"]);
    if (window.CogiavelliChrome) window.CogiavelliChrome.loadMap(assetBase);
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat block scales as one unit.
  var SEAT_BASE = 84;
  var NOTE_LINES = 3, NOTE_LINE_H = 12, NOTE_PAD = 6;
  var LABEL_GUTTER = 16;

  function noteHeight(scale) {
    return (NOTE_LINES * NOTE_LINE_H + NOTE_PAD * 2 - 2) * scale;
  }

  function seatBlock(size) {
    // The seat block: role tag headroom above the cog, the cog, then name,
    // score and the notes parchment below it. Parchment room is reserved
    // even while a seat has no notes: notes arrive without warning.
    var scale = size / SEAT_BASE;
    return {
      w: size * 1.9,
      above: size * 0.18,
      cogHalf: size / 2,
      below: size * 0.62 + 34 * scale + noteHeight(scale)
    };
  }

  function computeLayout(width, height) {
    // Two booths stacked vertically. In each, left to right: speaker block,
    // target card, ribbon, lineup of four cards, listener block. The ribbon
    // soaks up whatever width is left; the seat size shrinks until the
    // fixed parts fit. Callers embed this viewer at wildly different sizes,
    // so the fit is solved per frame rather than assumed.
    var margin = 10;
    var boothGap = 8;
    var boothH = (height - 2 * margin - boothGap) / 2;
    var size = Math.min(SEAT_BASE, width / 9, height / 5);
    var layout = null;
    for (var attempt = 0; attempt < 40; attempt++) {
      var b = seatBlock(size);
      var scale = size / SEAT_BASE;
      var gap = 12 * scale;
      var cardH = size * 1.45;
      var cardW = cardH * 0.78;
      var lcardH = cardH * 0.82;
      var lcardW = lcardH * 0.78;
      var lgap = 6 * scale;
      var gutter = LABEL_GUTTER * scale;
      var ribbonMin = size * 2.0;
      var fixedW = 2 * margin + 2 * b.w + cardW + 4 * lcardW + 3 * lgap +
        ribbonMin + 4 * gap;
      var blockH = b.above + 2 * b.cogHalf + b.below;
      var fits = fixedW <= width && blockH <= boothH &&
        cardH + gutter <= boothH;
      var ribbonW = Math.max(width - fixedW + ribbonMin, ribbonMin);
      var booths = [];
      for (var k = 0; k < 2; k++) {
        var top = margin + k * (boothH + boothGap);
        var cy = top + boothH / 2;
        var cogY = cy - blockH / 2 + b.above + b.cogHalf;
        var x = margin;
        var speaker = { x: x + b.w / 2, y: cogY };
        x += b.w + gap;
        var target = { x: x, y: cy - cardH / 2, w: cardW, h: cardH };
        x += cardW + gap;
        var ribbon = { x: x, y: cy - size * 0.45, w: ribbonW, h: size * 0.9 };
        x += ribbonW + gap;
        var lineup = [];
        for (var c = 0; c < 4; c++) {
          lineup.push({ x: x + c * (lcardW + lgap),
            y: cy - lcardH / 2 + gutter / 2, w: lcardW, h: lcardH });
        }
        x += 4 * lcardW + 3 * lgap + gap;
        var listener = { x: x + b.w / 2, y: cogY };
        booths.push({ top: top, h: boothH, speaker: speaker, target: target,
          ribbon: ribbon, lineup: lineup, listener: listener, gutter: gutter });
      }
      layout = { size: size, scale: scale, booths: booths, width: width,
        height: height };
      if (fits || size < 24) break;
      size *= 0.92;
    }
    return layout;
  }

  // Which seats sit in which booth: the state's pairs when it has them
  // (live global / replay), else the resting arrangement so a redacted
  // player frame still shows four cogs at two empty tables.
  function boothPairs(view) {
    var pairs = view.pairs || [];
    if (pairs.length >= 2) return pairs;
    var rest = [{ speaker: 0, listener: 1 }, { speaker: 2, listener: 3 }];
    return rest.map(function (p, i) { return pairs[i] || p; });
  }

  function draw(ctx, canvas, images, view) {
    // COGIAVELLI hook: this game draws a map of Italy, not two booths. The
    // booth scene below is the inherited chrome and is left untouched.
    if (window.CogiavelliChrome && view.state && view.state.units) {
      window.CogiavelliChrome.drawBoard(ctx, canvas, images, view);
      return;
    }
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var layout = computeLayout(w, h);
    var scale = layout.scale;
    var size = layout.size;
    var fx = view.effects || { speakAt: [], pickAt: [] };
    var glyphs = view.glyphs || [];

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Leaders get a tag once the table is settled.
    var top = -1;
    var level = true;
    seats.forEach(function (seat) {
      if (seat.correct > top) top = seat.correct;
    });
    seats.forEach(function (seat) {
      if (seat.correct !== top) level = false;
    });

    var pairs = boothPairs(view);
    pairs.forEach(function (pair, pi) {
      var booth = layout.booths[pi];
      if (!booth) return;
      var speakerSeat = seats[pair.speaker];
      var listenerSeat = seats[pair.listener];
      var speakerColor = seatColor(pair.speaker);
      var listenerColor = seatColor(pair.listener);
      var pending = pendingSeat(view.phase, pairs);

      // Booth strip: a faint plate so the two tables read as rooms.
      ctx.save();
      ctx.fillStyle = STRIP;
      roundRect(ctx, 4, booth.top, w - 8, booth.h, 10 * scale);
      ctx.fill();
      ctx.restore();

      // Speaker: cog, scene card.
      drawSeat(ctx, images, speakerSeat, pair.speaker, booth.speaker, size,
        scale, {
          role: pair.target !== undefined && pair.target !== null ?
            "SPEAKS" : "",
          pending: pending === pair.speaker && !view.done,
          leads: view.done && !level && speakerSeat &&
            speakerSeat.correct === top,
          roundsPlayed: view.roundsPlayed
        });
      drawCard(ctx, booth.target, pair.target, scale, {
        accent: COLOR_HEX[speakerColor]
      });

      // Ribbon: the message in canonical glyphs, speaker-coloured.
      var speakAt = fx.speakAt[pi];
      var slide = typeof speakAt === "number" ?
        Math.min(1, (now - speakAt) / RIBBON_SLIDE_MS) : 1;
      drawRibbon(ctx, booth.ribbon, pair.tokens, glyphs,
        COLOR_HEX[speakerColor], slide, scale);

      // Lineup A–D with the pick verdict on top.
      var pickAt = fx.pickAt[pi];
      var pickAge = typeof pickAt === "number" ? now - pickAt : null;
      var verdictAlpha = pickAge === null ? PICK_REST :
        pickAge < PICK_HOLD_MS ? 1 :
        Math.max(PICK_REST, 1 - (pickAge - PICK_HOLD_MS) / PICK_FADE_MS *
          (1 - PICK_REST));
      var lineup = pair.lineup || [];
      for (var c = 0; c < 4; c++) {
        var rect = booth.lineup[c];
        var picked = typeof pair.pick === "number" && pair.pick === c;
        var isTruth = lineup[c] !== undefined && lineup[c] === pair.target;
        var shake = 0;
        if (picked && pair.correct === false && pickAge !== null &&
            pickAge < SHAKE_MS) {
          shake = Math.sin(pickAge / 22) * 4 * scale * (1 - pickAge / SHAKE_MS);
        }
        var shifted = { x: rect.x + shake, y: rect.y, w: rect.w, h: rect.h };
        drawCard(ctx, shifted, lineup[c], scale, {
          label: LETTERS[c],
          labelColor: picked ? COLOR_HEX[listenerColor] : GHOST,
          verdict: picked ? (pair.correct ? "correct" : "wrong") :
            (isTruth && pair.correct === false ? "truth" : ""),
          verdictAlpha: verdictAlpha
        });
      }

      // Listener.
      drawSeat(ctx, images, listenerSeat, pair.listener, booth.listener, size,
        scale, {
          role: pair.target !== undefined && pair.target !== null ?
            "LISTENS" : "",
          pending: pending === pair.listener && !view.done,
          leads: view.done && !level && listenerSeat &&
            listenerSeat.correct === top,
          roundsPlayed: view.roundsPlayed
        });
    });
  }

  // The seat whose decision the table is waiting on.
  function pendingSeat(phase, pairs) {
    var m = /^(speak|pick)([01])$/.exec(phase || "");
    if (!m) return -1;
    var pair = pairs[Number(m[2])];
    if (!pair) return -1;
    return m[1] === "speak" ? pair.speaker : pair.listener;
  }

  // Cog, role tag, name, score and the notes parchment.
  function drawSeat(ctx, images, seat, index, pos, size, scale, opts) {
    if (!seat) return;
    var color = seatColor(index);
    var sprite = images["soldier_" + color + "_front.png"];

    ctx.save();
    ctx.translate(pos.x, pos.y);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // Acting halo.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Role tag over the cog while a round is on; LEADS once it is over.
    var tag = opts.leads ? "LEADS" : opts.role;
    if (tag) {
      drawTag(ctx, pos.x, pos.y - size * 0.52, tag,
        opts.leads ? AMBER : COLOR_HEX[color], scale);
    }

    // Name.
    ctx.save();
    ctx.font = "600 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", size * 1.7), pos.x,
      pos.y + size * 0.62 + 12 * scale);

    // Score: correct / roundsPlayed in amber.
    var played = typeof opts.roundsPlayed === "number" ? opts.roundsPlayed :
      (seat.roundsPlayed || 0);
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText((seat.correct || 0) + " / " + played, pos.x,
      pos.y + size * 0.62 + 27 * scale);
    ctx.restore();

    // Notes parchment.
    var bw = size * 1.9;
    drawParchment(ctx, pos.x - bw / 2, pos.y + size * 0.62 + 34 * scale, bw,
      seat.notes || "", scale);
  }

  function drawParchment(ctx, x, y, w, text, scale) {
    var pad = NOTE_PAD * scale;
    var lineH = NOTE_LINE_H * scale;
    var h = noteHeight(scale);
    ctx.save();
    ctx.font = Math.round(10.5 * scale) + "px " + GLYPH_FONT;
    var lines = text ? wrapLines(ctx, text, w - pad * 2, NOTE_LINES) : [];
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.10)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    // Folded corner.
    if (text) {
      ctx.beginPath();
      ctx.moveTo(x + w - 7 * scale, y);
      ctx.lineTo(x + w, y + 7 * scale);
      ctx.lineTo(x + w - 7 * scale, y + 7 * scale);
      ctx.closePath();
      ctx.fillStyle = "rgba(42, 31, 22, 0.25)";
      ctx.fill();
    }
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (text) {
      ctx.fillStyle = INK;
      lines.forEach(function (line, i) {
        ctx.fillText(line, x + pad, y + pad + i * lineH);
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("NO NOTES YET", x + pad, y + pad);
    }
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // A scene card: `count` copies of `shape` filled in `colour` on paper.
  // No scene (idle table / redacted frame) draws an empty dashed card.
  // opts: {label, labelColor, accent, verdict:"correct|wrong|truth|",
  //        verdictAlpha}
  function drawCard(ctx, rect, sceneId, scale, opts) {
    var scene = sceneOf(sceneId);
    var r = 5 * scale;
    ctx.save();
    if (opts.label) {
      ctx.font = "700 " + Math.round(12 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = opts.labelColor || "#b8ac98";
      ctx.fillText(opts.label, rect.x + rect.w / 2, rect.y - 4 * scale);
    }
    if (!scene) {
      ctx.fillStyle = "rgba(242, 232, 216, 0.08)";
      ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 3]);
      roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
      ctx.fill();
      ctx.stroke();
      ctx.restore();
      return;
    }
    // Paper with a soft drop shadow.
    ctx.shadowColor = "rgba(0,0,0,0.55)";
    ctx.shadowBlur = 6 * scale;
    ctx.shadowOffsetY = 2 * scale;
    ctx.fillStyle = PAPER;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = opts.accent || CARD_EDGE;
    ctx.lineWidth = opts.accent ? 2 : 1;
    ctx.stroke();

    // Items: 1 centred, 2 side by side, 3 in a triangle, 4 in a grid.
    var spots = [
      [[0.5, 0.5]],
      [[0.3, 0.5], [0.7, 0.5]],
      [[0.5, 0.3], [0.3, 0.7], [0.7, 0.7]],
      [[0.3, 0.3], [0.7, 0.3], [0.3, 0.7], [0.7, 0.7]]
    ][scene.count - 1];
    var radius = rect.w * (scene.count === 1 ? 0.3 : 0.17);
    var color = COLOR_HEX[COLOURS[scene.colour]];
    spots.forEach(function (spot) {
      drawShape(ctx, scene.shape, rect.x + spot[0] * rect.w,
        rect.y + spot[1] * rect.h, radius, color);
    });

    // Verdict overlay.
    var a = opts.verdictAlpha === undefined ? 1 : opts.verdictAlpha;
    if (opts.verdict === "correct" || opts.verdict === "wrong") {
      var tint = opts.verdict === "correct" ? COLOR_HEX.green : COLOR_HEX.red;
      ctx.fillStyle = rgba(tint, 0.55 * a);
      roundRect(ctx, rect.x, rect.y, rect.w, rect.h, r);
      ctx.fill();
      ctx.strokeStyle = rgba(tint, a);
      ctx.lineWidth = 3;
      ctx.stroke();
      ctx.font = "700 " + Math.round(rect.h * 0.55) + "px " + GLYPH_FONT;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.globalAlpha = a;
      ctx.fillStyle = PAPER;
      ctx.shadowColor = INK;
      ctx.shadowBlur = 4;
      ctx.fillText(opts.verdict === "correct" ? "✔" : "✘",
        rect.x + rect.w / 2, rect.y + rect.h / 2 + rect.h * 0.03);
      ctx.globalAlpha = 1;
    } else if (opts.verdict === "truth") {
      ctx.strokeStyle = rgba(AMBER, a);
      ctx.lineWidth = 3;
      roundRect(ctx, rect.x - 2, rect.y - 2, rect.w + 4, rect.h + 4,
        r + 2);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawShape(ctx, shape, cx, cy, radius, color) {
    ctx.save();
    ctx.fillStyle = color;
    ctx.strokeStyle = shade(color, 0.55);
    ctx.lineWidth = Math.max(1, radius * 0.12);
    ctx.lineJoin = "round";
    ctx.beginPath();
    if (shape === 0) {
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    } else if (shape === 1) {
      var s = radius * 0.9;
      roundRect(ctx, cx - s, cy - s, 2 * s, 2 * s, radius * 0.15);
    } else if (shape === 2) {
      var tr = radius * 1.1;
      for (var i = 0; i < 3; i++) {
        var ang = -Math.PI / 2 + i * Math.PI * 2 / 3;
        var px = cx + Math.cos(ang) * tr;
        var py = cy + radius * 0.12 + Math.sin(ang) * tr;
        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      ctx.closePath();
    } else {
      var outer = radius * 1.12;
      var inner = outer * 0.45;
      for (var k = 0; k < 10; k++) {
        var rr = k % 2 === 0 ? outer : inner;
        var a = -Math.PI / 2 + k * Math.PI / 5;
        var sx = cx + Math.cos(a) * rr;
        var sy = cy + radius * 0.06 + Math.sin(a) * rr;
        if (k === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
      }
      ctx.closePath();
    }
    ctx.fill();
    ctx.stroke();
    // Highlight.
    ctx.beginPath();
    ctx.arc(cx - radius * 0.3, cy - radius * 0.3, radius * 0.22, 0,
      Math.PI * 2);
    ctx.fillStyle = "rgba(242, 232, 216, 0.35)";
    ctx.fill();
    ctx.restore();
  }

  // The message between the cogs, large canonical glyphs in the speaker's
  // colour, sliding in from the speaker's side when it lands.
  function drawRibbon(ctx, rect, tokens, glyphs, color, slide, scale) {
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, rect.h / 2);
    ctx.fill();
    ctx.stroke();
    // Direction: a faint shaft with a head at the listener's end.
    var midY = rect.y + rect.h / 2;
    ctx.strokeStyle = "rgba(242, 232, 216, 0.18)";
    ctx.fillStyle = "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(rect.x + rect.h * 0.5, rect.y + rect.h - 5 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.55, rect.y + rect.h - 5 * scale);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(rect.x + rect.w - rect.h * 0.4, rect.y + rect.h - 5 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.6, rect.y + rect.h - 9 * scale);
    ctx.lineTo(rect.x + rect.w - rect.h * 0.6, rect.y + rect.h - 1 * scale);
    ctx.closePath();
    ctx.fill();
    if (!tokens || !tokens.length) {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("· · ·", rect.x + rect.w / 2, midY);
      ctx.restore();
      return;
    }
    var n = tokens.length;
    var fontPx = Math.min(rect.h * 0.72, (rect.w - rect.h) / n * 0.85);
    ctx.font = "700 " + Math.round(fontPx) + "px " + GLYPH_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    var step = Math.min(fontPx * 1.25, (rect.w - rect.h) / n);
    var startX = rect.x + rect.w / 2 - (n - 1) * step / 2;
    var eased = 1 - Math.pow(1 - slide, 3);
    var offset = (1 - eased) * rect.w * 0.25;
    ctx.globalAlpha = Math.max(0.05, eased);
    ctx.fillStyle = color;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    tokens.forEach(function (t, i) {
      var glyph = glyphs[t] !== undefined ? glyphs[t] : "?";
      ctx.fillText(glyph, startX + i * step - offset, midY - fontPx * 0.04);
    });
    ctx.restore();
  }

  // A small tag ("SPEAKS", "LEADS") in the seat's colour, pinned over the
  // cog.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }

  function spellTokens(tokens, nameMap) {
    return (tokens || []).map(function (t) { return nameMap.glyph(t); })
      .join(" ");
  }

  // `ctx` carries what a line needs from earlier events: the current
  // round's pairs (for lineups) and the running success tally.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      // COGIAVELLI hook: this game's thirteen event kinds, added to the
      // existing switch rather than replacing it.
      case "season": case "famine": case "press": case "orders":
      case "spend": case "assassin": case "bribe": case "battle":
      case "cities": case "plague": case "winter":
        return window.CogiavelliChrome.describeEvent(event, nameMap, ctx);
      case "start":
        if (window.CogiavelliChrome && event.powers) {
          return window.CogiavelliChrome.describeEvent(event, nameMap, ctx);
        }
        return "Table set — sixteen glyphs, no meanings.";
      case "round":
        return "Pairs: " + (event.pairs || []).map(function (p) {
          return name(p.speaker) + " → " + name(p.listener);
        }).join(" · ");
      case "speak":
        return name(event.seat) + " → " + name(event.other) + ": " +
          spellTokens(event.tokens, nameMap);
      case "pick":
        var pair = ctx.pairs && ctx.pairs[event.pair];
        var lineup = pair && pair.lineup || [];
        var chosen = lineup[event.pick];
        var letter = LETTERS[event.pick] || "?";
        var verdict = event.correct ? " — ✔" :
          " — ✘ it was " + (pair ? sceneText(pair.target) : "?");
        return name(event.seat) + " picks " + letter +
          (chosen !== undefined ? " (" + sceneText(chosen) + ")" : "") +
          verdict;
      case "end":
        if (window.CogiavelliChrome && event.cities) {
          return window.CogiavelliChrome.describeEvent(event, nameMap, ctx);
        }
        return endText(event, ctx);
      default: return JSON.stringify(event);
    }
  }

  function endText(event, ctx) {
    var total = ctx.pairRounds || 0;
    var pct = total ? Math.round(ctx.successes / total * 100) : 0;
    return "Final — " + ctx.successes + "/" + total + " (" + pct + "%)" +
      (event.text === "deadline" ? " — episode deadline." : ".");
  }

  function blockHead(block) {
    // COGIAVELLI hook: blocks are seasons, not rounds.
    if (window.CogiavelliChrome) {
      var head = window.CogiavelliChrome.blockHead(block);
      if (head) return head;
    }
    return block < 0 ? "SETUP" : "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, successes: 0, pairRounds: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "pick") {
        ctx.pairRounds += 1;
        if (event.correct) ctx.successes += 1;
      }
      var scored = event.kind === "pick" && event.correct;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "speak" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "") +
        // COGIAVELLI hook: per-kind feed colours for this game's events.
        (window.CogiavelliChrome ?
          " " + window.CogiavelliChrome.feedClass(event) : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      if (window.CogiavelliChrome) {
        window.CogiavelliChrome.extraLines(event, nameMap).forEach(
          function (extra) {
            html += '<div class="feed-line ' + extra.cls +
              (i >= limit ? " feed-future" : "") + '">' +
              escapeHtml(extra.text) + "</div>";
          });
      }
      // Notes: say-styled, only when the seat's notes changed.
      if ((event.kind === "speak" || event.kind === "pick") && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // per pair, when its message landed (the ribbon slides in from it) and
  // when its pick landed (the verdict flash fades from it).
  function makeEffects() {
    var seen = 0;
    var speakAt = [null, null];
    var pickAt = [null, null];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest events get to animate — replaying every historical
      // verdict as a fresh flash would strobe the table.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            speakAt = [null, null];
            pickAt = [null, null];
          } else if (event.kind === "speak") {
            speakAt[event.pair] = animate ? now : null;
          } else if (event.kind === "pick") {
            pickAt[event.pair] = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; speakAt = [null, null]; pickAt = [null, null];
      },
      view: function () {
        return { effects: { speakAt: speakAt.slice(), pickAt: pickAt.slice() } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function phaseText(state, nameMap) {
    var m = /^(speak|pick)([01])$/.exec(state.phase || "");
    var pairs = state.pairs || [];
    if (!m || !pairs[Number(m[2])]) return "";
    var pair = pairs[Number(m[2])];
    var seat = m[1] === "speak" ? pair.speaker : pair.listener;
    var who = nameMap ? nameMap.seat(seat) :
      (state.seats && state.seats[seat] || {}).name || ("Seat " + seat);
    return clampName(who).toUpperCase() +
      (m[1] === "speak" ? " SPEAKS" : " LISTENS");
  }

  function matchHeader(state, config, nameMap) {
    // COGIAVELLI hook: the clock names the beat on screen.
    if (window.CogiavelliChrome && state && state.units) {
      return window.CogiavelliChrome.clockText(state, nameMap);
    }
    var parts = [];
    if (state) {
      var played = state.roundsPlayed || 0;
      var inRound = /^(speak|pick)[01]$/.test(state.phase || "");
      var total = state.rounds || (config && config.rounds) || 0;
      parts.push("ROUND " + (played + (inRound ? 1 : 0)) +
        (total ? " / " + total : ""));
      if (state.gameDone || state.done) {
        parts.push("FINAL");
      } else {
        var phase = phaseText(state, nameMap);
        if (phase) parts.push(phase);
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    // COGIAVELLI hook: six power plates with cities, units and ducats.
    if (window.CogiavelliChrome && state.units) {
      window.CogiavelliChrome.scorebug(container, state, nameMap);
      return;
    }
    var pending = pendingSeat(state.phase, state.pairs || []);
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.asSpeaker || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      for (var q = 0; q < Math.min(seat.asListener || 0, 12); q++) {
        pips += '<span class="plate-pip hollow"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (pending === index && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + (seat.correct || 0) + "</span>" +
        '<span class="plate-label">correct</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.rounds || 0) +
          " of " + (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    // COGIAVELLI hook: the endcard carries the ledger next to the cities,
    // and the ledger walks the episode a year at a time once it is in the
    // document.
    if (window.CogiavelliChrome && results.powers) {
      container.innerHTML = window.CogiavelliChrome.endcard(results, nameMap);
      window.CogiavelliChrome.animateEndcard(container);
      return;
    }
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var correct = results.correct || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (correct[b] || 0) - (correct[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " LEADS THE TABLE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">correct</span>' +
      '<span class="end-head">as speaker</span>' +
      '<span class="end-head">as listener</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(correct[i] || 0) +
        cell((results.asSpeaker || [])[i] || 0) +
        cell((results.asListener || [])[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.pairs = state.pairs || [];
    view.glyphs = state.glyphs || [];
    view.phase = state.phase || "";
    view.roundsPlayed = state.roundsPlayed || 0;
    view.rounds = state.rounds || 0;
    view.now = Date.now();
    // COGIAVELLI hook: the appended board drawer reads the raw frame.
    view.state = state;
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is
      // behind a seat) and a redacted state (no pairs, no glyphs), so
      // their map degrades to the table aliases and empty booths.
      var nameMap = makeNameMap([], null, []);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames,
                latest.glyphs);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (window.CogiavelliChrome) {
                var log = latest.events || [];
                window.CogiavelliChrome.setPayload(latest);
                window.CogiavelliChrome.setBeat(log[log.length - 1] || null,
                  log.length, log, nameMap);
              }
              if (options.clock) {
                options.clock.textContent =
                  matchHeader(latest, latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              if (window.CogiavelliChrome) {
                window.CogiavelliChrome.buildDucatBar(
                  document.getElementById("ducatbar"), latest, nameMap);
              }
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per pick (coloured by the listener on success, a neutral ghost on
  // failure) and the end (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      // COGIAVELLI hook: every beat is a labelled, clickable button that
      // seeks to its own event; the drag-to-seek handlers below are the
      // inherited ones and still work.
      if (window.CogiavelliChrome) {
        window.CogiavelliChrome.markDucatBeat(container, event, i,
          events.length, onSeek);
        return;
      }
      var kind = event.kind;
      if (kind !== "pick" && kind !== "end") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "pick" && event.correct ?
          " seat" + (event.seat % COLORS.length) : "") +
        (kind === "end" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames,
      config.glyphs);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    // COGIAVELLI hook: the appended block needs the payload for its clock,
    // its bar race and its beat labels.
    if (window.CogiavelliChrome) window.CogiavelliChrome.setPayload(payload);

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        var state = states[Math.min(index, states.length - 1)] ||
          { seats: [], pairs: [], phase: "", roundsPlayed: 0 };
        // The alphabet is per episode; frames may omit it, the config
        // never does.
        if (!state.glyphs && config.glyphs) {
          state = Object.assign({}, state, { glyphs: config.glyphs });
        }
        return state;
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (window.CogiavelliChrome) {
          window.CogiavelliChrome.setBeat(
            index > 0 ? events[index - 1] : null, index, events, nameMap);
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
        if (window.CogiavelliChrome) {
          window.CogiavelliChrome.buildDucatBar(
            document.getElementById("ducatbar"), currentState(), nameMap);
        }
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event
        // just absorbed — so the message gets read and the verdict gets
        // seen before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = window.CogiavelliChrome ?
          window.CogiavelliChrome.stepMs(shown) :
          shown && shown.kind === "speak" ? 1600 :
          shown && shown.kind === "pick" ? 2000 :
          shown && shown.kind === "round" ? 800 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.BabelRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();

// ---------- Cogiavelli ----------
// COGIAVELLI additions to the inherited cogame-babel chrome.
//
// Everything above this line is cogame-babel's client/renderer.js, kept as
// it is apart from the hook points its comments name. This block only ADDS:
// it declares no name the chrome above already declares (asserted by
// tests/test_viewer.nim), and its two builders are called markDucatBeat and
// buildDucatBar so nothing can be shadowed by a hoisted chrome alias.
(function () {
  "use strict";

  var POWERS = ["VENICE", "MILAN", "FLORENCE", "PAPACY", "NAPLES", "TURK"];
  var POWER_LONG = ["Venice", "Milan", "Florence", "the Papacy", "Naples",
    "the Turk"];
  var SEASONS = ["SPRING", "SUMMER", "AUTUMN", "WINTER"];
  var START_YEAR = 1499;
  var DUCAT = "\u0111";
  var PROVINCE_NAMES = {
    TUR: "Turin", SAV: "Savoy", COM: "Como", MIL: "Milan", PAV: "Pavia",
    GEN: "Genoa", TRE: "Trent", MAN: "Mantua", VER: "Verona", PAD: "Padua",
    VEN: "Venice", FRI: "Friuli", TRI: "Trieste", FER: "Ferrara",
    MOD: "Modena", BOL: "Bologna", RMG: "Romagna", PIS: "Pisa",
    FLO: "Florence", SIE: "Siena", URB: "Urbino", ANC: "Ancona",
    PER: "Perugia", ROM: "Rome", ABR: "Abruzzi", NAP: "Naples",
    APU: "Apulia", BAR: "Bari", CAL: "Calabria", MES: "Messina",
    PAL: "Palermo", BOS: "Bosnia", RAG: "Ragusa", ALB: "Albania",
    DUR: "Durazzo", AVL: "Avlona", LIG: "the Ligurian Sea",
    UTS: "the Upper Tyrrhenian", LTS: "the Lower Tyrrhenian",
    ION: "the Ionian Sea", LAD: "the Lower Adriatic",
    UAD: "the Upper Adriatic"
  };
  var SEAT_HEX = ["#e0523a", "#3f7cc4", "#45a85e", "#ddc531", "#a86fd6",
    "#e08a3a"];
  var PAPER_TONE = "#e6d9bf";
  var SEA_TONE = "#2f4460";
  var INK_TONE = "#241a12";
  var AMBER_TONE = "#e8a33d";

  var mapData = null;
  var mapByCode = {};
  var payloadRef = null;
  var seatOfPower = [0, 1, 2, 3, 4, 5];
  var beat = null;
  var beatIndex = 0;
  var ledgerTimer = null;

  // ---- small helpers ------------------------------------------------------

  function placeName(code) {
    if (!code) return "";
    return PROVINCE_NAMES[code] || code;
  }

  function powerName(index) {
    return POWERS[index] || ("POWER " + index);
  }

  function powerLong(index) {
    return POWER_LONG[index] || powerName(index);
  }

  function powerIndexOf(name) {
    return POWERS.indexOf(String(name || "").toUpperCase());
  }

  function seatOf(power) {
    var seat = seatOfPower[power];
    return typeof seat === "number" ? seat : power;
  }

  function tint(power) {
    return SEAT_HEX[seatOf(power) % SEAT_HEX.length];
  }

  function mix(hex, other, amount) {
    function bytes(value) {
      var n = parseInt(value.slice(1), 16);
      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    var a = bytes(hex);
    var b = bytes(other);
    var out = a.map(function (v, i) {
      return Math.round(v + (b[i] - v) * amount);
    });
    return "rgb(" + out[0] + "," + out[1] + "," + out[2] + ")";
  }

  function esc(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function seasonHead(round) {
    if (typeof round !== "number" || round < 0) return "SETUP";
    return SEASONS[round % 4] + " " + (START_YEAR + Math.floor(round / 4));
  }

  function beatHead(event) {
    if (!event) return "";
    if (typeof event.round === "number") return seasonHead(event.round);
    return "";
  }

  // ---- map ----------------------------------------------------------------

  function loadMap(assetBase) {
    if (mapData || loadMap.started) return;
    loadMap.started = true;
    var url = String(assetBase || ".").replace(/\/$/, "") + "/italy1499.json";
    fetch(url).then(function (response) {
      if (!response.ok) throw new Error("map " + response.status);
      return response.json();
    }).then(function (data) {
      mapData = data;
      (data.areas || []).forEach(function (area) {
        mapByCode[area.code] = area;
      });
    }).catch(function () { /* the board falls back to anchors-only */ });
  }

  // ---- layout -------------------------------------------------------------

  function boardBox(canvas, state) {
    // The whole map is always fitted to the frame. Below 640px the canvas
    // draws an ACTION BOX instead: the bounding box of every area named in
    // this season's orders and payments, padded by one province and at
    // least 40% of the map. No controls, no pan, no zoom.
    var full = { x: 0, y: 0, w: (mapData && mapData.width) || 1000,
      h: (mapData && mapData.height) || 900 };
    if (!mapData || canvas.width >= 640) return full;
    var codes = [];
    (state.arrows || []).forEach(function (arrow) {
      codes.push(arrow.from, arrow.to, arrow.aux);
    });
    (state.units || []).forEach(function (unit) { codes.push(unit.province); });
    (state.famine || []).forEach(function (code) { codes.push(code); });
    if (state.plague) codes.push(state.plague);
    var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9, seen = 0;
    codes.forEach(function (code) {
      var area = mapByCode[code];
      if (!area) return;
      seen += 1;
      area.polygon.forEach(function (point) {
        minX = Math.min(minX, point[0]);
        maxX = Math.max(maxX, point[0]);
        minY = Math.min(minY, point[1]);
        maxY = Math.max(maxY, point[1]);
      });
    });
    if (seen < 2) return full;
    var pad = 90;
    minX -= pad; minY -= pad; maxX += pad; maxY += pad;
    var w = Math.max(maxX - minX, full.w * 0.4);
    var h = Math.max(maxY - minY, full.h * 0.4);
    var cx = (minX + maxX) / 2;
    var cy = (minY + maxY) / 2;
    return {
      x: Math.max(0, Math.min(cx - w / 2, full.w - w)),
      y: Math.max(0, Math.min(cy - h / 2, full.h - h)),
      w: Math.min(w, full.w), h: Math.min(h, full.h)
    };
  }

  function projector(canvas, box) {
    var scale = Math.min(canvas.width / box.w, canvas.height / box.h);
    var ox = (canvas.width - box.w * scale) / 2 - box.x * scale;
    var oy = (canvas.height - box.h * scale) / 2 - box.y * scale;
    return {
      scale: scale,
      x: function (v) { return ox + v * scale; },
      y: function (v) { return oy + v * scale; }
    };
  }

  // ---- board --------------------------------------------------------------

  function drawBoard(ctx, canvas, images, view) {
    var state = view.state;
    var w = canvas.width;
    var h = canvas.height;
    var floor = images["arena_floor.png"];
    ctx.fillStyle = (floor && floor.width) ?
      ctx.createPattern(floor, "repeat") : "#16110d";
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    ctx.fillRect(0, 0, w, h);
    if (!mapData) {
      ctx.fillStyle = "#8a7f72";
      ctx.font = "600 14px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillText("ITALY 1499", w / 2, h / 2);
      return;
    }
    var box = boardBox(canvas, state);
    var p = projector(canvas, box);
    var ownerOf = {};
    (state.owners || []).forEach(function (row) {
      ownerOf[row.city] = row.power;
    });
    var famine = {};
    (state.famine || []).forEach(function (code) { famine[code] = true; });

    mapData.areas.forEach(function (area) {
      var owner = ownerOf[area.code];
      var fill = SEA_TONE;
      if (area.kind !== "sea") {
        fill = PAPER_TONE;
        if (typeof owner === "number" && owner >= 0) {
          fill = mix(PAPER_TONE, tint(owner), 0.42);
        } else if (area.city) {
          fill = mix(PAPER_TONE, "#8a7f72", 0.18);
        } else {
          fill = mix(PAPER_TONE, "#8a7f72", 0.30);
        }
      }
      ctx.beginPath();
      area.polygon.forEach(function (point, i) {
        var x = p.x(point[0]);
        var y = p.y(point[1]);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.strokeStyle = "rgba(36, 26, 18, 0.85)";
      ctx.lineWidth = Math.max(1, 1.4 * p.scale);
      ctx.stroke();
      if (famine[area.code]) hatch(ctx, p, area, "rgba(120, 78, 34, 0.42)");
      if (state.plague && state.plague === area.code) {
        ctx.fillStyle = "rgba(96, 128, 96, 0.48)";
        ctx.fill();
      }
    });

    // Cities: amber stars, filled when owned, hollow when neutral.
    var labelPx = Math.max(8, Math.round(17 * p.scale));
    mapData.areas.forEach(function (area) {
      if (area.city) {
        var owner = ownerOf[area.code];
        star(ctx, p.x(area.dot[0]), p.y(area.dot[1]),
          Math.max(4, 7 * p.scale),
          typeof owner === "number" && owner >= 0 ? AMBER_TONE : null);
      }
      if (labelPx >= 8) {
        ctx.font = "600 " + labelPx + "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillStyle = area.kind === "sea" ? "rgba(226, 216, 198, 0.55)" :
          "rgba(36, 26, 18, 0.8)";
        ctx.fillText(labelPx >= 10 ? area.name : area.code,
          p.x(area.label[0]), p.y(area.label[1]));
      }
    });

    (state.arrows || []).forEach(function (arrow) {
      drawArrow(ctx, p, arrow);
    });
    (state.units || []).forEach(function (unit) {
      drawUnit(ctx, p, unit);
    });
    (state.standoffs || []).forEach(function (code) {
      var area = mapByCode[code];
      if (area) stamp(ctx, p.x(area.unit[0]), p.y(area.unit[1]), "STANDOFF",
        "#e0523a", p.scale);
    });
    (state.stabs || []).forEach(function (stab) {
      var seat = seatOf(stab.power);
      var home = homeAnchor(stab.power, state);
      if (home) stamp(ctx, p.x(home[0]), p.y(home[1]) - 26 * p.scale, "STAB",
        SEAT_HEX[seat % SEAT_HEX.length], p.scale);
    });
    (state.purses || []).forEach(function (purse, i) {
      drawPurse(ctx, p, images, purse, state, i);
    });
    (state.gifts || []).forEach(function (gift, i) {
      drawGift(ctx, p, images, gift, state, i);
    });
    (state.daggers || []).forEach(function (dagger) {
      drawDagger(ctx, p, images, dagger, state);
    });
  }

  function hatch(ctx, p, area, colour) {
    ctx.save();
    ctx.clip();
    ctx.strokeStyle = colour;
    ctx.lineWidth = Math.max(1, 3 * p.scale);
    var step = Math.max(6, 14 * p.scale);
    for (var i = -600; i < 1600; i += step) {
      ctx.beginPath();
      ctx.moveTo(p.x(i), p.y(0));
      ctx.lineTo(p.x(i + 900), p.y(900));
      ctx.stroke();
    }
    ctx.restore();
  }

  function star(ctx, cx, cy, radius, fill) {
    ctx.save();
    ctx.beginPath();
    for (var i = 0; i < 10; i++) {
      var r = i % 2 === 0 ? radius : radius * 0.45;
      var angle = -Math.PI / 2 + i * Math.PI / 5;
      var x = cx + Math.cos(angle) * r;
      var y = cy + Math.sin(angle) * r;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = AMBER_TONE;
    if (fill) { ctx.fillStyle = fill; ctx.fill(); }
    ctx.stroke();
    ctx.restore();
  }

  function anchorOf(code) {
    var area = mapByCode[code];
    return area ? area.unit : null;
  }

  function homeAnchor(power, state) {
    var found = null;
    (state.units || []).forEach(function (unit) {
      if (unit.power === power && !found) found = anchorOf(unit.province);
    });
    return found;
  }

  function drawArrow(ctx, p, arrow) {
    var from = anchorOf(arrow.from);
    var to = anchorOf(arrow.kind === "convoy" ? arrow.aux : arrow.to);
    if (!from || !to) return;
    var colour = tint(arrow.power);
    var failed = arrow.outcome !== "success";
    ctx.save();
    ctx.lineWidth = Math.max(1.5, (arrow.kind === "move" ? 3.4 : 2.2) *
      p.scale);
    ctx.strokeStyle = arrow.outcome === "bounce" ? "#e0523a" :
      failed ? "rgba(138, 127, 114, 0.85)" : colour;
    if (arrow.kind === "convoy") ctx.setLineDash([7, 5]);
    if (arrow.kind === "support") ctx.globalAlpha = 0.75;
    var x1 = p.x(from[0]);
    var y1 = p.y(from[1]);
    var x2 = p.x(to[0]);
    var y2 = p.y(to[1]);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
    if (arrow.kind === "move") {
      var angle = Math.atan2(y2 - y1, x2 - x1);
      var head = Math.max(6, 11 * p.scale);
      ctx.beginPath();
      ctx.moveTo(x2, y2);
      ctx.lineTo(x2 - Math.cos(angle - 0.4) * head,
        y2 - Math.sin(angle - 0.4) * head);
      ctx.lineTo(x2 - Math.cos(angle + 0.4) * head,
        y2 - Math.sin(angle + 0.4) * head);
      ctx.closePath();
      ctx.fillStyle = ctx.strokeStyle;
      ctx.fill();
    }
    ctx.restore();
  }

  function drawUnit(ctx, p, unit) {
    var anchor = anchorOf(unit.province);
    if (!anchor) return;
    var x = p.x(anchor[0]);
    var y = p.y(anchor[1]);
    var size = Math.max(11, 22 * p.scale);
    var colour = tint(unit.power);
    ctx.save();
    if (unit.dislodged) ctx.globalAlpha = 0.5;
    ctx.strokeStyle = INK_TONE;
    ctx.lineWidth = 2;
    ctx.fillStyle = colour;
    if (unit.kind === "F") {
      // A fleet is a pennant.
      ctx.beginPath();
      ctx.moveTo(x - size * 0.1, y + size * 0.6);
      ctx.lineTo(x - size * 0.1, y - size * 0.6);
      ctx.lineTo(x + size * 0.75, y - size * 0.22);
      ctx.lineTo(x - size * 0.1, y + size * 0.15);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(x - size * 0.1, y + size * 0.6);
      ctx.lineTo(x - size * 0.1, y - size * 0.6);
      ctx.stroke();
    } else {
      // An army is a block bearing its power's initial.
      ctx.beginPath();
      ctx.rect(x - size * 0.5, y - size * 0.45, size, size * 0.9);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = "#241a12";
      ctx.font = "700 " + Math.round(size * 0.66) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(powerName(unit.power).charAt(0), x, y + 1);
    }
    if (unit.bought) {
      stamp(ctx, x, y - size * 0.9, "BOUGHT", AMBER_TONE, p.scale);
    }
    ctx.restore();
  }

  function stamp(ctx, x, y, text, colour, scale) {
    ctx.save();
    ctx.font = "700 " + Math.max(8, Math.round(11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    var pad = Math.max(3, 5 * scale);
    var width = ctx.measureText(text).width + pad * 2;
    var height = Math.max(13, 16 * scale);
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    ctx.strokeStyle = colour;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.rect(x - width / 2, y - height / 2, width, height);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK_TONE;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x, y + 1);
    ctx.restore();
  }

  function sprite(ctx, images, name, x, y, size) {
    var image = images[name];
    if (image && image.width) {
      ctx.drawImage(image, x - size / 2, y - size / 2, size, size);
      return true;
    }
    return false;
  }

  function drawPurse(ctx, p, images, purse, state, index) {
    var anchor = anchorOf(String(purse.to || "").split(/\s+/).pop());
    if (!anchor) return;
    var x = p.x(anchor[0]) + (index % 2 ? 16 : -16) * p.scale;
    var y = p.y(anchor[1]) - 26 * p.scale;
    var size = Math.max(18, 34 * p.scale);
    if (!sprite(ctx, images, "purse.png", x, y, size)) {
      star(ctx, x, y, size / 3, AMBER_TONE);
    }
    label(ctx, x, y + size * 0.55, purse.amount + DUCAT,
      purse.outcome === "bought" || purse.outcome === "disbanded" ?
        AMBER_TONE : "#8a7f72", p.scale);
    if (purse.outcome === "defended" || purse.outcome === "outbid") {
      stamp(ctx, x, y - size * 0.6, purse.outcome.toUpperCase(), "#3f7cc4",
        p.scale);
    }
  }

  function drawGift(ctx, p, images, gift, state, index) {
    var anchor = homeAnchor(gift.to, state);
    if (!anchor) return;
    var x = p.x(anchor[0]) + (index % 2 ? 20 : -20) * p.scale;
    var y = p.y(anchor[1]) + 24 * p.scale;
    var size = Math.max(14, 26 * p.scale);
    if (!sprite(ctx, images, "purse.png", x, y, size)) {
      star(ctx, x, y, size / 3, AMBER_TONE);
    }
    label(ctx, x, y + size * 0.6, "+" + gift.amount + DUCAT, AMBER_TONE,
      p.scale);
  }

  function drawDagger(ctx, p, images, dagger, state) {
    var anchor = homeAnchor(dagger.target, state);
    if (!anchor) return;
    var x = p.x(anchor[0]);
    var y = p.y(anchor[1]) - 34 * p.scale;
    var size = Math.max(20, 38 * p.scale);
    if (!sprite(ctx, images, "dagger.png", x, y, size)) {
      stamp(ctx, x, y, "DAGGER", "#e0523a", p.scale);
    }
    var dieSize = Math.max(12, 22 * p.scale);
    sprite(ctx, images, "die.png", x + size * 0.7, y, dieSize);
    sprite(ctx, images, "die.png", x + size * 1.3, y, dieSize);
    label(ctx, x + size, y + dieSize * 0.9,
      dagger.amount + DUCAT + " needs " + dagger.amount + " or less \u2014 " +
        dagger.roll,
      dagger.success ? "#e0523a" : "#8a7f72", p.scale);
    if (dagger.success) {
      stamp(ctx, x, y - size * 0.7, "FROZEN", "#3f7cc4", p.scale);
    }
  }

  function label(ctx, x, y, text, colour, scale) {
    ctx.save();
    ctx.font = "700 " + Math.max(8, Math.round(11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = "rgba(18, 13, 9, 0.78)";
    var width = ctx.measureText(text).width + 8;
    ctx.fillRect(x - width / 2, y - 8, width, 16);
    ctx.fillStyle = colour;
    ctx.fillText(text, x, y);
    ctx.restore();
  }

  // ---- feed ---------------------------------------------------------------

  function describeDucatEvent(event, nameMap, ctx) {
    switch (event.kind) {
      case "start":
        return "Italy, 1499 \u2014 six powers, twenty-four cities, twelve " +
          "to win.";
      case "season":
        return event.phase === "press" ?
          "The couriers ride." : "Orders and expenditure are sealed.";
      case "famine":
        return "FAMINE this year: " + (event.provinces || [])
          .map(placeName).join(" and ") + ".";
      case "press":
        return powerLong(event.power) + (event.broadcast ?
          " broadcasts: \u201c" + event.broadcast + "\u201d" :
          " writes no broadcast.");
      case "orders":
        return powerLong(event.power) + " orders " +
          (event.orders || []).map(orderWords).join("; ") + ".";
      case "spend":
        return spendLine(event);
      case "assassin":
        return powerLong(event.power) + " pays " + event.amount +
          " ducats for a dagger against " + powerLong(event.target) +
          ". The dice show " + event.d1 + " and " + event.d2 + " \u2014 " +
          event.roll + ". " + (event.success ?
            powerLong(event.target) + "'s court is frozen." :
            "The dagger snaps.");
      case "bribe":
        return bribeLine(event);
      case "battle":
        return battleLine(event, ctx);
      case "cities":
        return citiesLine(event);
      case "plague":
        return "PLAGUE strikes " + placeName(event.province) + ". " +
          ((event.killed || []).length ?
            (event.killed.length === 1 ? "One unit is lost" :
              event.killed.length + " units are lost") + " and it pays " +
              "nothing this year." :
            "It pays nothing this year.");
      case "winter":
        return winterLine(event);
      case "end":
        return endLine(event);
      default:
        return "";
    }
  }

  function orderWords(text) {
    // "F VEN S A PAD - FER" reads as words, never as notation: a casual
    // spectator should never have to decode A/F, S, C or a dash.
    var parts = String(text).trim().split(/\s+/);
    var where = placeName(parts[1]);
    if (parts.length < 3 || parts[2] === "H") return where + " holds";
    if (parts[2] === "-") {
      return where + " \u2192 " + placeName(parts[3]) +
        (parts.length > 4 ? " by sea" : "");
    }
    var aux = parts[4] ? placeName(parts[4]) : "";
    if (parts[2] === "S") {
      if (parts[5] === "-") {
        return where + " supports " + aux + " \u2192 " + placeName(parts[6]);
      }
      return where + " supports " + aux;
    }
    if (parts[2] === "C") {
      return where + " convoys " + aux + " \u2192 " + placeName(parts[6]);
    }
    return text;
  }

  function unitWords(targetUnit, power) {
    var parts = String(targetUnit || "").trim().split(/\s+/);
    var kind = parts[0] === "F" ? "fleet" : "army";
    var where = parts[1] ? placeName(parts[1]) : "";
    return "the " + adjectiveOf(power) + " " + kind +
      (where ? " in " + where : "");
  }

  function spendLine(event) {
    var paid = (event.entries || []).filter(function (e) { return e.applied; });
    if (!paid.length) return powerLong(event.power) + " pays nothing.";
    return powerLong(event.power) + " opens the vault: " +
      paid.map(function (entry) {
        if (entry.kind === "gift") {
          return "gives " + powerLong(entry.targetPower) + " " +
            entry.amount + " ducats";
        }
        if (entry.kind === "assassinate") {
          return "puts " + entry.amount + " on a dagger against " +
            powerLong(entry.targetPower);
        }
        if (entry.kind === "defend") {
          return "pays " + entry.amount + " to keep " +
            unitWords(entry.targetUnit, entry.targetPower) + " loyal";
        }
        return "pays " + entry.amount + " to " +
          (entry.kind === "bribe_buy" ? "buy " : "disband ") +
          unitWords(entry.targetUnit, entry.targetPower);
      }).join(", ") + ". " + event.treasuryAfter + " ducats left.";
  }

  function bribeLine(event) {
    var what = event.bribeKind === "bribe_buy" ? "buy " : "disband ";
    var head = powerLong(event.power) + " pays " + event.amount +
      " ducats to " + what + unitWords(event.targetUnit, event.targetPower) +
      ".";
    if (event.outcome === "bought") return head + " It changes sides.";
    if (event.outcome === "disbanded") return head + " It disbands.";
    if (event.outcome === "defended") {
      // "defended" is the vocabulary's only place for a bribe that did not
      // meet the price, so say which it was: nobody paid to defend this
      // unit, the offer was simply short.
      if (!event.defence) {
        return head + " That is under the price and the bribe fails.";
      }
      return head + " " + powerLong(event.targetPower) + " had paid " +
        event.defence + " to keep it loyal, and the bribe fails.";
    }
    return head + " A rival paymaster matches it and both fail.";
  }

  function adjectiveOf(power) {
    return ["Venetian", "Milanese", "Florentine", "Papal", "Neapolitan",
      "Turkish"][power] || "";
  }

  function unitWord(text) {
    return String(text || "").charAt(0) === "F" ? "fleet" : "army";
  }

  function battleLine(event, ctx) {
    var moved = (event.results || []).filter(function (r) {
      return r.outcome === "success" && r.to;
    });
    var bounced = (event.results || []).filter(function (r) {
      return r.outcome === "bounce";
    });
    if (!moved.length && !bounced.length) return "Nothing moves.";
    var parts = [];
    if (moved.length) {
      parts.push(moved.slice(0, 6).map(function (r) {
        return powerLong(r.power) + " takes " + placeName(r.to);
      }).join("; "));
    }
    if (bounced.length) {
      parts.push("STANDOFF in " + bounced.slice(0, 4).map(function (r) {
        return placeName(r.to || r.from);
      }).join(", "));
    }
    return parts.join(". ") + ".";
  }

  function citiesLine(event) {
    var counts = event.counts || [];
    return "Cities: " + counts.map(function (count, power) {
      var gained = (event.gained || [])[power] || [];
      var lost = (event.lost || [])[power] || [];
      return powerLong(power) + " " + count +
        (gained.length ? " (+" + gained.map(placeName).join(", ") + ")" : "") +
        (lost.length ? " (\u2212" + lost.map(placeName).join(", ") + ")" : "");
    }).join(", ") + ".";
  }

  function winterLine(event) {
    var parts = [];
    (event.rebellions || []).forEach(function (rebellion) {
      if (rebellion.roll === 1) {
        parts.push(placeName(rebellion.city) + " rebels against " +
          powerLong(rebellion.power));
      }
    });
    (event.income || []).forEach(function (income, power) {
      parts.push(powerLong(power) + " collects " + income + " and pays " +
        ((event.upkeep || [])[power] || 0) + " in upkeep");
    });
    (event.builds || []).forEach(function (build) {
      if (build.applied) {
        parts.push(powerLong(build.power) + " builds " + build.entry);
      }
    });
    return "Winter accounts \u2014 " + parts.join("; ") + ".";
  }

  function endLine(event) {
    var cities = event.cities || [];
    var treasury = event.treasury || [];
    if (event.text === "conquest" && event.conqueror) {
      var power = powerIndexOf(event.conqueror);
      return powerLong(power < 0 ? 0 : power) + " holds " +
        (cities[power] || 0) + " cities \u2014 ITALY IS HERS.";
    }
    var best = 0;
    cities.forEach(function (count, power) {
      if (count > cities[best]) best = power;
    });
    var line = "Final \u2014 " + powerLong(best) + " " + cities[best] +
      " of 24 cities and " + (treasury[best] || 0) + " ducats.";
    if (event.text === "deadline") {
      line += " Episode deadline \u2014 scored on the board as it stood.";
    }
    return line;
  }

  function extraLines(event, nameMap) {
    var out = [];
    if (event.kind === "press") {
      (event.letters || []).forEach(function (letter) {
        if (letter.public) return;
        out.push({
          cls: "feed-letter",
          text: powerLong(event.power) + " \u2192 " + letter.to +
            " (private): \u201c" + letter.text + "\u201d"
        });
      });
      (event.pledges || []).forEach(function (pledge) {
        out.push({
          cls: "feed-pledge",
          text: powerLong(event.power) + " pledges " + pledge.kind + " to " +
            pledge.to + (pledge.province ? " over " + placeName(pledge.province)
              : "") + "."
        });
      });
    }
    if (event.kind === "orders") {
      (event.illegal || []).forEach(function (bad) {
        out.push({
          cls: "feed-illegal",
          text: powerLong(event.power) + " ordered \u201c" + bad.raw +
            "\u201d \u2014 " + reasonWord(bad.why) + "; the unit holds."
        });
      });
    }
    if (event.kind === "spend") {
      (event.entries || []).forEach(function (entry) {
        if (entry.applied) return;
        out.push({
          cls: "feed-illegal",
          text: powerLong(event.power) + " tried to pay " + entry.amount +
            " ducats but " + droppedWord(entry.why) + "."
        });
      });
    }
    if (event.kind === "battle") {
      (event.dislodged || []).forEach(function (hit) {
        var retreat = (event.retreats || []).filter(function (r) {
          return r.unit === hit.unit;
        })[0];
        out.push({
          cls: "feed-dislodge",
          text: "The unit in " + placeName(hit.unit) + " is dislodged by " +
            placeName(hit.attackerFrom) + " and " +
            (retreat && retreat.to !== "D" ?
              "retreats to " + placeName(retreat.to) : "disbands") + "."
        });
      });
      (event.stabs || []).forEach(function (stab) {
        out.push({
          cls: "feed-stab",
          text: "STAB \u2014 " + powerLong(stab.power) + " promised " +
            stab.pledgeTo + " " + stab.kind + " and did " + stab.order + "."
        });
      });
    }
    if (event.kind === "winter") {
      (event.famineKills || []).forEach(function (unit) {
        out.push({
          cls: "feed-famine",
          text: "Famine starves the " + adjectiveOf(unit.power) + " " +
            (unit.kind === "F" ? "fleet" : "army") + " in " +
            placeName(unit.province) + "."
        });
      });
      (event.upkeepDisbands || []).forEach(function (unit) {
        out.push({
          cls: "feed-winter",
          text: powerLong(unit.power) + " cannot pay the " +
            (unit.kind === "F" ? "fleet" : "army") + " in " +
            placeName(unit.province) + "; it disbands."
        });
      });
    }
    if ((event.kind === "press" || event.kind === "orders") && event.text) {
      out.push({
        cls: "feed-notes",
        text: powerLong(event.power) + " notes: " + nameMap.text(event.text)
      });
    }
    return out;
  }

  function reasonWord(why) {
    return {
      parse: "that is not an order",
      nonadjacent: "not adjacent",
      wrongunit: "that unit cannot do that",
      notthere: "there is no unit there",
      noconvoy: "no fleet could carry it",
      notowned: "that is not its unit"
    }[why] || why;
  }

  function droppedWord(why) {
    return {
      insufficient: "could not afford it",
      notarget: "there was nothing to pay for",
      illegal: "the rules forbid it"
    }[why] || "it was dropped";
  }

  function feedClass(event) {
    return {
      press: "feed-broadcast", orders: "feed-order", spend: "feed-gift",
      assassin: "feed-dagger", bribe: "feed-bribe", battle: "feed-bounce",
      cities: "feed-cities", plague: "feed-plague", famine: "feed-famine",
      winter: "feed-winter", end: "feed-end", season: "feed-it",
      start: "feed-it"
    }[event.kind] || "";
  }

  function ducatBlockHead(block) {
    if (typeof block !== "number") return "";
    return seasonHead(block);
  }

  // ---- clock --------------------------------------------------------------

  function clockText(state, nameMap) {
    var head = beatHead(beat) ||
      (SEASONS[["spring", "summer", "autumn", "winter"]
        .indexOf(state.season)] || "SPRING") + " " + state.year;
    if (!beat) return head;
    switch (beat.kind) {
      case "press":
        return head + " \u00b7 LETTERS \u00b7 " + powerName(beat.power);
      case "orders":
        return head + " \u00b7 ORDERS \u00b7 " + powerName(beat.power);
      case "spend":
        return head + " \u00b7 PAYMENTS \u00b7 " + powerName(beat.power) +
          " " + purseTotal(beat) + DUCAT;
      case "bribe":
        return "BRIBE \u00b7 " + powerName(beat.power) + " " + beat.amount +
          DUCAT + " ON " + (beat.targetUnit || "");
      case "assassin":
        return "DAGGER \u00b7 " + powerName(beat.power) + " " + beat.amount +
          DUCAT + " VS " + powerName(beat.target) + " \u2014 " + beat.roll;
      case "battle":
        return head + " \u00b7 BATTLE";
      case "cities":
        return head + " \u00b7 CITIES \u00b7 " + leaderText(beat.counts);
      case "plague":
        return "PLAGUE \u00b7 " + placeName(beat.province).toUpperCase();
      case "famine":
        return "FAMINE \u00b7 " + (beat.provinces || [])
          .map(function (code) { return placeName(code).toUpperCase(); })
          .join(", ");
      case "winter":
        return "WINTER " + beat.year + " \u00b7 ACCOUNTS";
      case "end":
        return "FINAL \u00b7 " + leaderText(beat.cities) + " CITIES";
      case "season":
        return head + " \u00b7 " +
          (beat.phase === "press" ? "LETTERS" : "ORDERS") +
          " \u00b7 WAITING ON " + pendingCount(state);
      default:
        return head;
    }
  }

  function purseTotal(event) {
    var total = 0;
    (event.entries || []).forEach(function (entry) {
      if (entry.applied) total += entry.amount;
    });
    return total;
  }

  function leaderText(counts) {
    var list = counts || [];
    var best = 0;
    list.forEach(function (count, power) {
      if (count > list[best]) best = power;
    });
    return powerName(best) + " " + (list[best] || 0);
  }

  function pendingCount(state) {
    var count = 0;
    (state.seats || []).forEach(function (seat) {
      if (seat.pending) count += 1;
    });
    return count;
  }

  // ---- scorebug -----------------------------------------------------------

  function scorebug(container, state, nameMap) {
    var html = "";
    (state.seats || []).forEach(function (seat, index) {
      var chips = "";
      if (seat.pending && !state.gameDone) {
        chips += '<span class="plate-it">\u25b6</span>';
      }
      if (seat.stabbedThisTurn) chips += '<span class="plate-stab">STAB</span>';
      if (seat.paralysed) chips += '<span class="plate-frozen">FROZEN</span>';
      if (seat.eliminated) chips += '<span class="plate-out">OUT</span>';
      html += '<div class="plate seat' + (index % 6) + ' ' +
        ["red", "blue", "green", "yellow", "violet", "orange"][index % 6] +
        (seat.eliminated ? " dead" : "") + '">' +
        '<span class="plate-power">' + esc(seat.power) + "</span>" +
        '<span class="plate-name">' + esc(nameMap ? nameMap.seat(index) :
          seat.name) + "</span>" +
        chips +
        '<span class="plate-score">' + seat.cities + "</span>" +
        '<span class="plate-cities">cities</span>' +
        '<span class="plate-ducats">' + seat.units + " units \u00b7 " +
        seat.ducats + DUCAT + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // ---- the ducat bar (the appended game element) --------------------------

  function buildDucatBar(element, state, nameMap) {
    if (!element || !state || !state.seats) return;
    var total = 24;
    var html = '<div class="ducat-race">';
    var claimed = 0;
    state.seats.forEach(function (seat, index) {
      claimed += seat.cities;
      var width = (seat.cities / total * 100).toFixed(2);
      html += '<div class="ducat-seg seat' + (index % 6) +
        '" style="width:' + width + '%"><span class="ducat-tag">' +
        esc(seat.power) + " " + seat.cities + "</span></div>";
    });
    html += '<div class="ducat-seg neutral" style="width:' +
      ((total - claimed) / total * 100).toFixed(2) +
      '%"><span class="ducat-tag">NEUTRAL ' + (total - claimed) +
      "</span></div>";
    html += '<div class="ducat-line" style="left:' +
      (12 / total * 100).toFixed(2) + '%"></div>';
    html += "</div><div class=\"ducat-coins\">";
    state.seats.forEach(function (seat, index) {
      html += '<span class="ducat-coin seat' + (index % 6) + '">' +
        esc(seat.power.slice(0, 3)) + " " + seat.ducats + DUCAT + "</span>";
    });
    html += "</div>";
    if (element.dataset.html !== html) {
      element.dataset.html = html;
      element.innerHTML = html;
    }
  }

  // ---- scrubber beats -----------------------------------------------------

  var BEAT_KINDS = {
    press: 1, orders: 1, spend: 1, bribe: 1, assassin: 1, battle: 1,
    cities: 1, plague: 1, famine: 1, winter: 1, end: 1
  };

  function beatLabel(event) {
    var head = beatHead(event);
    switch (event.kind) {
      case "press":
        var to = (event.letters || []).filter(function (l) {
          return !l.public;
        }).map(function (l) { return l.to; });
        return head + " \u00b7 LETTERS \u00b7 " + powerLong(event.power) +
          (to.length ? " writes to " + to.join(", ") : " says nothing");
      case "orders":
        return head + " \u00b7 ORDERS \u00b7 " + powerLong(event.power);
      case "spend":
        return head + " \u00b7 PAYMENTS \u00b7 " + powerLong(event.power) +
          " spends " + purseTotal(event) + DUCAT;
      case "bribe":
        return "BRIBE \u00b7 " + powerLong(event.power) + " " +
          (event.bribeKind === "bribe_buy" ? "buys " : "pays to disband ") +
          unitWords(event.targetUnit, event.targetPower) + " for " +
          event.amount + DUCAT;
      case "assassin":
        return "DAGGER \u00b7 " + powerLong(event.power) + " pays " +
          event.amount + DUCAT + " against " + powerLong(event.target) +
          " \u2014 " + event.roll + ", " +
          (event.success ? "it lands" : "it misses");
      case "battle":
        return head + " \u00b7 BATTLE";
      case "cities":
        return head + " \u00b7 CITIES \u00b7 " + leaderText(event.counts);
      case "plague":
        return "PLAGUE \u00b7 " + placeName(event.province);
      case "famine":
        return "FAMINE \u00b7 " + (event.provinces || []).map(placeName)
          .join(", ");
      case "winter":
        var bits = [];
        (event.rebellions || []).forEach(function (r) {
          if (r.roll === 1) bits.push(placeName(r.city) + " rebels");
        });
        (event.builds || []).forEach(function (b) {
          if (b.applied) {
            bits.push(powerLong(b.power) + " builds " + b.entry);
          }
        });
        return "WINTER " + event.year +
          (bits.length ? " \u00b7 " + bits.slice(0, 3).join(" \u00b7 ") : "");
      case "end":
        return "FINAL";
      default:
        return head;
    }
  }

  function addBeat(container, kind, label, position, onSeek, index) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "beat-marker " + kind;
    button.style.left = position + "%";
    button.title = label;
    button.setAttribute("aria-label", label);
    button.innerHTML = '<span class="beat-label">' + esc(label) + "</span>";
    button.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(index);
    };
    container.appendChild(button);
  }

  function markDucatBeat(container, event, i, total, onSeek) {
    if (!BEAT_KINDS[event.kind]) return;
    var position = (i + 1) / total * 100;
    addBeat(container, event.kind, beatLabel(event), position, onSeek, i + 1);
    // A stab inside a battle gets its own derived beat.
    (event.stabs || []).forEach(function (stab) {
      addBeat(container, "stab",
        "STAB \u00b7 " + powerLong(stab.power) + " breaks " + stab.kind +
          " with " + stab.pledgeTo,
        position, onSeek, i + 1);
    });
  }

  // ---- endcard ------------------------------------------------------------

  function endcard(results, nameMap) {
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      return (results.scores[b] || 0) - (results.scores[a] || 0);
    });
    var top = order[0];
    var verdict = esc(names[top]) + " (" + esc(results.powers[top]) + ") " +
      (results.reason === "conquest" ? "TOOK ITALY" : "LED ITALY");
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL \u2014 ' + (results.years || 0) +
      ((results.years || 0) === 1 ? " YEAR" : " YEARS") +
      " \u00b7 24 CITIES</div>" +
      '<div class="end-verdict">' + verdict + "</div>";
    if (results.reason === "deadline") {
      html += '<div class="end-reason">episode deadline \u2014 scored on ' +
        'the board as it stood</div>';
    }
    var stabs = stabCounts();
    html += '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head">power</span>' +
      '<span class="end-head">cities</span>' +
      '<span class="end-head">ducats</span>' +
      '<span class="end-head">spent</span>' +
      '<span class="end-head">stabs</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var winner = i === top ? " end-row-winner" : "";
      html += '<span class="end-cell rank' + winner + '">' + (rank + 1) +
        "</span>" +
        '<span class="end-cell name seat' + (i % 6) + winner + '">' +
        esc(names[i]) + " \u00b7 " + esc(results.powers[i]) + "</span>" +
        '<span class="end-cell' + winner + '">' + (results.cities[i] || 0) +
        "</span>" +
        '<span class="end-cell' + winner + '">' + (results.ducats[i] || 0) +
        DUCAT + "</span>" +
        '<span class="end-cell' + winner + '">' + (results.spent[i] || 0) +
        DUCAT + "</span>" +
        '<span class="end-cell stabs' + winner + '">' +
        (stabs[powerIndexOf(results.powers[i])] || 0) + "</span>" +
        '<span class="end-cell' + winner + '">' +
        (results.scores[i] || 0).toFixed(3) + "</span>";
    });
    html += "</div>" + ledgerHtml() + "</div>";
    return html;
  }

  function stabCounts() {
    // Broken pledges, by power, from the recorded battle events.
    var counts = [0, 0, 0, 0, 0, 0];
    ((payloadRef && payloadRef.events) || []).forEach(function (event) {
      if (event.kind !== "battle") return;
      (event.stabs || []).forEach(function (stab) {
        if (typeof stab.power === "number" && stab.power >= 0) {
          counts[stab.power] += 1;
        }
      });
    });
    return counts;
  }

  function ledgerFrames() {
    // Who paid what to whom, accumulated year by year, so the endcard can
    // walk the episode a year at a time.
    var events = (payloadRef && payloadRef.events) || [];
    var running = [];
    for (var a = 0; a < 6; a++) running.push([0, 0, 0, 0, 0, 0]);
    var frames = [];
    var year = null;
    function snapshot(at) {
      var copy = running.map(function (row) { return row.slice(); });
      frames.push({ year: at, matrix: copy });
    }
    events.forEach(function (event) {
      if (event.kind !== "spend") return;
      if (year !== null && event.year !== year) snapshot(year);
      year = event.year;
      (event.entries || []).forEach(function (entry) {
        if (!entry.applied) return;
        var to = entry.targetPower;
        if (typeof to !== "number" || to < 0) return;
        running[entry.power][to] += entry.amount;
      });
    });
    snapshot(year);
    return frames;
  }

  function ledgerGridHtml(frame, only) {
    var html = '<div class="end-ledger-grid end-ledger-year' +
      (only ? " on" : "") + '">';
    html += '<span class="end-ledger-when">' +
      (frame.year ? esc(String(frame.year)) : "") + "</span>";
    for (var t = 0; t < 6; t++) {
      html += '<span class="end-head">' + esc(POWERS[t].slice(0, 3)) +
        "</span>";
    }
    for (var f = 0; f < 6; f++) {
      html += '<span class="end-head">' + esc(POWERS[f].slice(0, 3)) +
        "</span>";
      for (var g = 0; g < 6; g++) {
        html += '<span class="end-cell ledger' +
          (frame.matrix[f][g] ? " paid" : "") + '">' +
          (frame.matrix[f][g] || "\u00b7") + "</span>";
      }
    }
    return html + "</div>";
  }

  function ledgerHtml() {
    var frames = ledgerFrames();
    var html = '<div class="end-ledger"><div class="end-ledger-head">' +
      "THE LEDGER \u2014 ducats paid, payer by target, year by year</div>";
    frames.forEach(function (frame, index) {
      html += ledgerGridHtml(frame, index === 0);
    });
    return html + "</div>";
  }

  function animateEndcard(container) {
    // One year per second, in a loop. The endcard is built once per page,
    // so there is never more than one of these running; the previous one
    // is cleared before a new one starts.
    if (ledgerTimer) {
      clearInterval(ledgerTimer);
      ledgerTimer = null;
    }
    if (!container || !container.querySelectorAll) return;
    var layers = container.querySelectorAll(".end-ledger-year");
    if (layers.length < 2) return;
    var at = 0;
    ledgerTimer = setInterval(function () {
      layers[at].classList.remove("on");
      at = (at + 1) % layers.length;
      layers[at].classList.add("on");
    }, 1000);
  }

  // ---- playback pacing ----------------------------------------------------

  function stepMs(event) {
    if (!event) return 600;
    switch (event.kind) {
      case "battle": return 1200;
      case "press": case "orders": return 950;
      case "bribe": case "assassin": return 1100;
      case "cities": case "winter": return 1000;
      case "end": return 1200;
      default: return 800;
    }
  }

  // ---- wiring -------------------------------------------------------------

  function setPayload(payload) {
    payloadRef = payload;
    if (payload && payload.powers) {
      var order = [0, 1, 2, 3, 4, 5];
      payload.powers.forEach(function (name, seat) {
        var power = powerIndexOf(name);
        if (power >= 0) order[power] = seat;
      });
      seatOfPower = order;
    } else if (payload && payload.seatOfPower) {
      seatOfPower = payload.seatOfPower;
    }
  }

  function setBeat(event, index) {
    beat = event;
    beatIndex = index;
  }

  window.CogiavelliChrome = {
    loadMap: loadMap,
    drawBoard: drawBoard,
    describeEvent: describeDucatEvent,
    extraLines: extraLines,
    feedClass: feedClass,
    blockHead: ducatBlockHead,
    clockText: clockText,
    scorebug: scorebug,
    endcard: endcard,
    animateEndcard: animateEndcard,
    buildDucatBar: buildDucatBar,
    markDucatBeat: markDucatBeat,
    stepMs: stepMs,
    setPayload: setPayload,
    setBeat: setBeat
  };
  window.CogiavelliRenderer = window.BabelRenderer;
})();
