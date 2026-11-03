"""Generate Sessions' original short bell, shared by standalone and notification playback."""
from math import exp, pi, sin
from pathlib import Path
import struct
import wave

output = Path(__file__).resolve().parents[1] / "Sources/PomodoroApp/Resources/SessionsCompletion.wav"
output.parent.mkdir(parents=True, exist_ok=True)
sample_rate = 44100
duration = 0.85
partials = [(1, 0.70, 5), (2.01, 0.20, 7), (2.49, 0.07, 10), (3.96, 0.03, 13)]
frames = bytearray()
for index in range(round(sample_rate * duration)):
    time = index / sample_rate
    envelope = min(1, time / 0.006) * max(0, 1 - (time / duration) ** 8)
    value = sum(weight * exp(-decay * time) * sin(2 * pi * 1046.5 * ratio * time)
                for ratio, weight, decay in partials)
    frames.extend(struct.pack("<h", round(0.60 * 32767 * envelope * value)))
with wave.open(str(output), "wb") as sound:
    sound.setnchannels(1)
    sound.setsampwidth(2)
    sound.setframerate(sample_rate)
    sound.writeframes(frames)
print(output)
