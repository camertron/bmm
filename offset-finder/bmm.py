import librosa
import numpy as np
from scipy import signal
import argparse
import json


def find_best_peak(y_within, y_find, first_chunk, second_chunk):
    first_start_at, first_end_at = first_chunk
    c1 = signal.correlate(y_within[first_start_at:first_end_at], y_find, mode='valid', method='fft')

    second_start_at, second_end_at = second_chunk
    c2 = signal.correlate(y_within[second_start_at:second_end_at], y_find, mode='valid', method='fft')

    if np.max(c1) > np.max(c2):
        return np.argmax(c1) + first_start_at
    else:
        return np.argmax(c2) + second_start_at


def find_peak(y_within, y_find, start_at=None, end_at=None):
    c = signal.correlate(y_within[start_at:end_at], y_find, mode='valid', method='fft')
    peak = np.argmax(c)

    return peak + start_at


def hr(sec):
    m = sec // 60
    s = sec % 60
    return f"{int(m)}m{int(s)}s"


def main(within_file):
    find_file = "/app/bmm.wav"
    y_within, sr = librosa.load(within_file, sr=None)
    y_find, _ = librosa.load(find_file, sr=sr)

    first_peak = None
    second_peak = None

    try:
        first_peak = find_peak(y_within, y_find, 0, -1)
    except:
        pass

    if first_peak:
        try:
            first_chunk = (0, first_peak - (5 * sr))
            second_chunk = (first_peak + (5 * sr), -1)
            second_peak = find_best_peak(y_within, y_find, first_chunk, second_chunk)
        except:
            pass

    results = []

    if first_peak:
        sec = round(first_peak / sr, 2)
        results.append({"offset": sec, "hr": hr(sec)})

        if second_peak:
            sec = round(second_peak / sr, 2)
            results.append({"offset": sec, "hr": hr(sec)})

    print(json.dumps(results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--file', metavar='file', type=str, help='The file to process')
    args = parser.parse_args()
    main(args.file)
