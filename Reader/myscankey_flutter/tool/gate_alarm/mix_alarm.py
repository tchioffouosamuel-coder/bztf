"""Mixe le message vocal du portail sur une sirène douce (balayage sinusoïdal).

Pas de signal carré ni de bip aigu : la sirène « wail » monte et descend
lentement entre 620 et 980 Hz, reste forte seule en introduction puis
s'efface sous la voix (ducking) pour que le message reste intelligible.
"""
import sys
import wave

import numpy as np

voice_path, out_path = sys.argv[1], sys.argv[2]
with wave.open(voice_path, "rb") as source:
    rate = source.getframerate()
    assert source.getnchannels() == 1 and source.getsampwidth() == 2
    voice = np.frombuffer(source.readframes(source.getnframes()), dtype=np.int16).astype(np.float64) / 32768.0

# Retire les silences de début et de fin du synthétiseur.
level = np.abs(voice)
active = np.where(level > 0.01)[0]
voice = voice[max(0, active[0] - int(0.05 * rate)): active[-1] + int(0.15 * rate)]
voice = voice / np.max(np.abs(voice)) * 0.92

intro = 1.6  # secondes de sirène seule
tail = 0.8
total = int((intro + len(voice) / rate + tail) * rate)
t = np.arange(total) / rate

# Sirène « wail » : fréquence qui oscille doucement (période 1,6 s).
period = 1.6
low, high = 620.0, 980.0
frequency = low + (high - low) * (0.5 - 0.5 * np.cos(2 * np.pi * t / period))
phase = 2 * np.pi * np.cumsum(frequency) / rate
siren = np.sin(phase) + 0.18 * np.sin(2 * phase)  # légère harmonique, timbre plus rond
siren /= np.max(np.abs(siren))

# Enveloppe : fondu d'entrée, niveau plein pendant l'intro, puis sous la voix.
envelope = np.full(total, 0.16)
fade_in = int(0.25 * rate)
intro_end = int(intro * rate)
envelope[:intro_end] = 0.5
envelope[:fade_in] *= np.linspace(0, 1, fade_in)
duck = int(0.35 * rate)
envelope[intro_end - duck: intro_end] = np.linspace(0.5, 0.16, duck)
fade_out = int(0.6 * rate)
envelope[-fade_out:] *= np.linspace(1, 0, fade_out)
mix = siren * envelope

start = intro_end
mix[start: start + len(voice)] += voice
mix /= max(1.0, np.max(np.abs(mix)) / 0.97)

with wave.open(out_path, "wb") as target:
    target.setnchannels(1)
    target.setsampwidth(2)
    target.setframerate(rate)
    target.writeframes((mix * 32767).astype(np.int16).tobytes())
print(f"{out_path}: {total / rate:.1f} s, {rate} Hz")
