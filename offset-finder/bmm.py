import librosa
import numpy as np
from scipy import signal
import argparse
import json

def main(within_file):
    find_file = "./bmm.wav"
    y_within, sr = librosa.load(within_file, sr=None)
    y_find, _ = librosa.load(find_file, sr=sr)
    peaks = []
    candidates = [(0, len(y_within))]

    for i in range(0, 5):
        new_candidates = []

        for candidate in candidates:
            start = candidate[0]
            end = candidate[1]

            if start < 0 or end < 0 or start > end:
                continue

            c = signal.correlate(y_within[start:end], y_find, mode='valid', method='fft')
            peak = np.argmax(c)
            peaks.append((peak + start, c))

            # for some reason, signal.correlate can return results outside the start..end bounds
            if peak > start and peak < end:
                new_candidates.append((start, peak - (1 * sr)))
                new_candidates.append((peak + (1 * sr), end))

        candidates = new_candidates

    peaks = [peak for peak in peaks if np.max(peak[1]) > 400]

    output = []

    for peak in peaks:
        offset = peak[0]
        c = peak[1]
        sec = round(offset / sr, 2)
        output.append({"offset": sec, "hr": hr(sec), "score": int(np.max(c))})

    print(json.dumps(output))

def hr(sec):
    m = sec // 60
    s = sec % 60
    return f"{int(m)}m{int(s)}s"

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--file', metavar='file', type=str, help='The file to process')
    args = parser.parse_args()
    main(args.file)
