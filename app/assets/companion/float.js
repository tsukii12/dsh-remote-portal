// Float-only contracts, shared by the real stage and its Node tests.
// No model assets, browser emulation or GPU claims in the pure tests.
(() => {
  'use strict';

  class FrameGate {
    constructor() { this.last = -Infinity; }
    take(time) {
      // The 2ms slack is for rAF jitter: on 60, 90 and 120 Hz a 30 fps frame is a whole
      // number of refreshes, and a timestamp a hair early would otherwise skip to the next
      // one and land at 20–24 fps. Same allowance as the room's render loop.
      if (!Number.isFinite(time) || time - this.last < 1000 / 30 - 2) return false;
      this.last = time;
      return true;
    }
  }

  // readPixels starts at the bottom-left; the native window uses top-left.
  // Even alpha=1 counts. A mesh's vertices do not prove pixel opacity.
  function opaqueBounds(rgba, width, height) {
    let left = width, bottom = height, right = 0, top = 0;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        if (rgba[(y * width + x) * 4 + 3] === 0) continue;
        left = Math.min(left, x);
        right = Math.max(right, x + 1);
        bottom = Math.min(bottom, y);
        top = Math.max(top, y + 1);
      }
    }
    return right > left ? { left, top: height - top, right, bottom: height - bottom } : null;
  }

  const states = {
    idle: ['calm', null], thinking: ['confused', 'tilt'],
    working: ['calm', 'nodSmall'], juggling: ['calm', 'nodSmall'],
    sweeping: ['calm', 'nodSmall'], carrying: ['calm', 'nodSmall'],
    attention: ['happy', 'nod'], notification: ['worried', 'lookUp'],
    error: ['sad', 'shake'], sleeping: ['sleepy', 'yawn'], waking: ['calm', 'stretch'],
  };

  // Only the character/adapter's authored mappings opt a state into effects.
  // The room's generic ACTIONS/DEFAULT_EMOTIONS are deliberately not evidence.
  function stateEffect(state, emotions, actions) {
    const owns = (object, key) => object != null && Object.prototype.hasOwnProperty.call(object, key);
    const mappedEmotion = name => owns(emotions, name) && emotions[name] != null &&
      typeof emotions[name] === 'object' && !Array.isArray(emotions[name]);
    const mappedAction = name => owns(actions, name) && actions[name] != null &&
      typeof actions[name] === 'object' &&
      (typeof actions[name].motion === 'string' && actions[name].motion.length > 0 ||
       actions[name].tracks && typeof actions[name].tracks === 'object' &&
       Number.isFinite(actions[name].ms) && actions[name].ms > 0);
    const [emotion, action] = owns(states, state) ? states[state] : states.idle;
    return {
      emotion: mappedEmotion(emotion) ? emotion : 'calm',
      action: action && mappedAction(action) ? action : null,
      mood: state === 'sleeping' && mappedEmotion('sleepy') ? 'sleeping' : 'idle',
    };
  }

  const api = { FrameGate, opaqueBounds, stateEffect };
  if (typeof module !== 'undefined') module.exports = api;
  if (typeof window !== 'undefined') {
    window.CompanionFloat = api;
    if (new URLSearchParams(location.search).get('mode') === 'float') {
      document.documentElement.dataset.mode = 'float';
    }
  }
})();
