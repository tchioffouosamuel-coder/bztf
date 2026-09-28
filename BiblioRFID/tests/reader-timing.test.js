import test from "node:test";
import assert from "node:assert/strict";
import { bridgeSettingsSource, isTagRearmReady, isTagVisuallyReleased, normalizeReaderTiming, storedRearmDelayMs } from "../lib/reader-timing.js";

test("valide les délais configurables du lecteur", () => {
  assert.deepEqual(normalizeReaderTiming({ beepMode: "native", beepDurationMs: 75, rearmDelayMs: 30000 }), {
    beepMode: "native",
    beepDurationMs: 75,
    rearmDelayMs: 30000
  });
  assert.throws(() => normalizeReaderTiming({ beepDurationMs: 10, rearmDelayMs: 30000 }), /20 et 1000/);
  assert.throws(() => normalizeReaderTiming({ beepDurationMs: 75, rearmDelayMs: 999 }), /1 et 3600 secondes/);
  assert.equal(normalizeReaderTiming({ beepDurationMs: 75, rearmDelaySeconds: 30 }).rearmDelayMs, 30000);
});

test("migre les anciens délais courts saisis en secondes", () => {
  assert.equal(storedRearmDelayMs("10", "1"), 10000);
  assert.equal(storedRearmDelayMs("30000", "1"), 30000);
  assert.equal(storedRearmDelayMs("", "15"), 15000);
  assert.equal(storedRearmDelayMs("invalide", ""), 30000);
});

test("génère les constantes C# compilées dans le pont", () => {
  const source = bridgeSettingsSource({ beepMode: "controlled", beepDurationMs: 90, rearmDelayMs: 12000 });
  assert.match(source, /UseControlledBuzzerPulse = true/);
  assert.match(source, /BuzzerPulseMilliseconds = 90/);
  assert.match(source, /BeepRearmMilliseconds = 12000/);
});

test("compile le mode natif sans impulsion contrôlée", () => {
  const source = bridgeSettingsSource({ beepMode: "native", beepDurationMs: 90, rearmDelayMs: 12000 });
  assert.match(source, /UseControlledBuzzerPulse = false/);
});

test("ne réarme le bip qu'après une disparition visuelle confirmée", () => {
  const timing = { lastSeen: 1000, rearmDelayMs: 30000, presenceTimeoutMs: 450, visualReleaseDelayMs: 200 };
  assert.equal(isTagVisuallyReleased({ ...timing, now: 1649 }), false);
  assert.equal(isTagVisuallyReleased({ ...timing, now: 1650 }), true);
  assert.equal(isTagRearmReady({ ...timing, now: 1650 }), false);
  assert.equal(isTagRearmReady({ ...timing, now: 31650 }), true);
});
