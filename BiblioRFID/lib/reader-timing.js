export const DEFAULT_READER_TIMING = Object.freeze({
  beepMode: "controlled",
  beepDurationMs: 75,
  rearmDelayMs: 30000
});

const MIN_REARM_DELAY_MS = 1000;
const MAX_REARM_DELAY_MS = 3600000;

export function storedRearmDelayMs(
  storedMilliseconds,
  legacySeconds,
  fallback = DEFAULT_READER_TIMING.rearmDelayMs,
) {
  const stored = Number(storedMilliseconds);
  if (Number.isInteger(stored) && stored >= MIN_REARM_DELAY_MS && stored <= MAX_REARM_DELAY_MS)
    return stored;
  if (Number.isInteger(stored) && stored >= 1 && stored < MIN_REARM_DELAY_MS)
    return stored * 1000;
  const legacy = Number(legacySeconds);
  if (Number.isInteger(legacy) && legacy >= 1 && legacy <= 3600)
    return legacy * 1000;
  return fallback;
}

export function isTagVisuallyReleased({ lastSeen, now, presenceTimeoutMs, visualReleaseDelayMs }) {
  return now - lastSeen >= presenceTimeoutMs + visualReleaseDelayMs;
}

export function isTagRearmReady({ lastSeen, now, rearmDelayMs, presenceTimeoutMs, visualReleaseDelayMs }) {
  return isTagVisuallyReleased({ lastSeen, now, presenceTimeoutMs, visualReleaseDelayMs }) &&
    now - lastSeen >= presenceTimeoutMs + visualReleaseDelayMs + rearmDelayMs;
}

export function normalizeReaderTiming(input = {}, fallback = DEFAULT_READER_TIMING) {
  const beepMode = ["native", "controlled"].includes(input.beepMode) ? input.beepMode : fallback.beepMode;
  const beepDurationMs = Number(input.beepDurationMs ?? fallback.beepDurationMs);
  const legacyRearmMs = input.rearmDelaySeconds == null ? undefined : Number(input.rearmDelaySeconds) * 1000;
  const rearmDelayMs = Number(input.rearmDelayMs ?? legacyRearmMs ?? fallback.rearmDelayMs);
  if (!Number.isInteger(beepDurationMs) || beepDurationMs < 20 || beepDurationMs > 1000) {
    throw new Error("La durée du bip doit être un entier compris entre 20 et 1000 ms.");
  }
  if (!Number.isInteger(rearmDelayMs) || rearmDelayMs < MIN_REARM_DELAY_MS || rearmDelayMs > MAX_REARM_DELAY_MS) {
    throw new Error("Le délai de réarmement doit être compris entre 1 et 3600 secondes.");
  }
  return { beepMode, beepDurationMs, rearmDelayMs };
}

export function bridgeSettingsSource(timing) {
  const value = normalizeReaderTiming(timing);
  return `namespace BiblioRfid.ReaderBridge
{
    internal static class BridgeSettings
    {
        internal static readonly bool UseControlledBuzzerPulse = ${value.beepMode === "controlled" ? "true" : "false"};
        internal const int BuzzerPulseMilliseconds = ${value.beepDurationMs};
        internal const int BeepRearmMilliseconds = ${value.rearmDelayMs};
    }
}
`;
}
