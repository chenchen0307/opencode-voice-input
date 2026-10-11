# -*- coding: utf-8 -*-
"""性能基线：测量 Qwen3-ASR 在不同音频长度下的单次转写耗时。

用法：python bench.py [--runs 3]
"""
import argparse
import os
import statistics
import sys
import time

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from voice_server import SAMPLE_RATE, Transcriber, settings  # noqa: E402

MODEL = settings.get("voice", "model_dir") or os.path.join(HERE, "models", "Qwen3-ASR-1.7B")
SAMPLE = os.path.join(HERE, "sample_zh.wav")

LENGTHS = [1, 3, 5, 8, 12, 20, 30, 60]


def load_sample() -> np.ndarray:
    if not os.path.exists(SAMPLE):
        raise SystemExit(f"缺少测试音频: {SAMPLE}")
    audio, sr = sf.read(SAMPLE, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        import librosa

        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE).astype(np.float32)
    return audio


def make_audio(base: np.ndarray, seconds: int) -> np.ndarray:
    need = int(seconds * SAMPLE_RATE)
    if need <= base.size:
        return base[:need]
    reps = need // base.size + 1
    return np.tile(base, reps)[:need]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--device", choices=["cuda", "cpu"], default="cuda", help="计算设备")
    args = parser.parse_args()

    print(f"模型: {MODEL}  设备: {args.device}")
    tr = Transcriber(MODEL, args.device)
    base = load_sample()

    print(f"\n{'长度':>6} {'中位耗时':>10} {'最快':>9} {'每秒钟音频':>12}")
    print("-" * 44)
    for seconds in LENGTHS:
        audio = make_audio(base, seconds)
        times = []
        for _ in range(args.runs):
            t0 = time.time()
            tr.transcribe(audio, SAMPLE_RATE, max_new_tokens=192)
            times.append(time.time() - t0)
        med = statistics.median(times)
        print(f"{seconds:>4}s {med:>9.3f}s {min(times):>8.3f}s {med / seconds:>11.3f}s")


if __name__ == "__main__":
    main()
