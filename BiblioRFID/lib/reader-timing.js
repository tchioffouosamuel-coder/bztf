export const DEFAULT_READER_TIMING = Object.freeze({
  beepMode: "controlled",
  beepDurationMs: 75,
  rearmDelayMs: 30000
});

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
  if (!Number.isInteger(rearmDelayMs) || rearmDelayMs < 1 || rearmDelayMs > 3600000) {
    throw new Error("Le délai de réarmement doit être un entier compris entre 1 et 3600000 ms.");
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
