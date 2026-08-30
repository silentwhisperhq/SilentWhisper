// The blob, driven the same way the app drives it: a smoothed level feeds one CSS
// variable, and every size, glow and throw is derived from that. In the app the level
// comes from the microphone; here it comes from a synthetic speech envelope.
(function () {
  var mark = document.getElementById("mark");
  var hint = document.getElementById("hint");
  if (!mark) return;

  var STATES = ["rec", "think", "ai", "done", "idle"];
  var LABEL = {
    rec: "listening",
    think: "transcribing",
    ai: "polishing",
    done: "pasted",
    idle: "idle"
  };

  function set(state) {
    mark.dataset.state = state;
    if (hint) hint.textContent = LABEL[state];
    mark.setAttribute("aria-label", "The Silent Whisper blob, " + LABEL[state]);
  }
  set("rec");

  mark.addEventListener("click", function () {
    set(STATES[(STATES.indexOf(mark.dataset.state) + 1) % STATES.length]);
  });

  var calm = matchMedia("(prefers-reduced-motion: reduce)");
  if (calm.matches) { mark.style.setProperty("--amp", "0.45"); return; }

  // Two sines plus a little jitter reads as speech; a single sine reads as a metronome.
  var amp = 0, t = Math.random() * 100;
  (function frame() {
    t += 0.055;
    var state = mark.dataset.state, target;
    if (state === "rec") {
      target = 0.45 + 0.4 * Math.sin(t) + 0.28 * Math.sin(t * 2.7 + 1) + (Math.random() - 0.5) * 0.18;
    } else if (state === "think") {
      target = 0.3 + 0.25 * Math.sin(t * 3.4);
    } else if (state === "ai") {
      target = 0.32 + 0.2 * Math.sin(t * 2.6);
    } else if (state === "done") {
      target = 0.2;
    } else {
      target = 0.1 + 0.08 * Math.sin(t * 0.4);
    }
    amp += (Math.min(1, Math.max(0, target)) - amp) * 0.18;   // same easing as the app
    mark.style.setProperty("--amp", amp.toFixed(3));
    requestAnimationFrame(frame);
  })();
})();
