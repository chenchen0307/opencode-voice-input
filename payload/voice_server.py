# -*- coding: utf-8 -*-
"""OpenCode 语音输入常驻服务。

功能
----
1. 常驻内存加载 Qwen3-ASR-1.7B（CUDA），避免每次转写重新加载模型。
2. 持续采集麦克风到环形缓冲区，支持 pre-roll：长按回车判定成功时，
   会把"按下瞬间之前"的一段也包含进录音，避免吞掉第一个字。
3. 本地 HTTP 接口（仅监听 127.0.0.1）：

   GET  /health     -> {"ok":true,"ready":true,"recording":false,...}
   GET  /devices    -> 输入设备列表
   GET  /config     -> 当前配置（含生效的设备/采样率）
   GET  /partial    -> 录音期间的准实时识别结果（JSON）
   GET  /partial.txt-> 同上，纯文本（供 AutoHotkey 悬浮窗读取）
   POST /start      -> 开始录音（含 pre-roll）
   POST /stop       -> 停止录音并转写，成功返回 text/plain UTF-8 文本
   POST /cancel     -> 取消本次录音
   POST /config     -> 更新配置（JSON，形如 {"voice":{"device":"1"}}）
   POST /clipboard  -> 把请求体文本写入系统剪贴板
   POST /inject     -> 调试：下一次 /stop 直接转写指定 wav 文件

配置文件：与本脚本同目录的 voice.config.ini（缺失时使用内置默认值）。
环境变量仍可覆盖：OPENCODE_VOICE_PORT / DEVICE / LANG / PREROLL_MS / MODEL。
"""

from __future__ import annotations

import configparser
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

# pythonw.exe 下没有控制台，sys.stdout/stderr 为 None；部分库会直接写这两个流。
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")

CONFIG_PATH = os.path.join(HERE, "voice.config.ini")

DEFAULTS: dict[str, dict[str, str]] = {
    "voice": {
        "port": "17860",
        "device": "",
        "language": "",
        "preroll_ms": "500",
        "model_dir": "",
        "max_record_seconds": "60",
        "partial_enabled": "1",
        "partial_interval_ms": "280",
        "partial_min_growth_ms": "150",
        "partial_min_first_ms": "300",
        "segment_seconds": "5",
        "segment_overlap_ms": "600",
        "silence_rms_x10000": "10",
        "compute": "auto",
    },
    "hotkey": {
        "hold_ms": "350",
        "auto_submit": "0",
        "restore_clipboard": "1",
        "targets": "ahk_exe OpenCode.exe",
    },
    "overlay": {
        "enabled": "1",
        "offset_y": "120",
        "max_chars": "200",
        "poll_ms": "150",
    },
    "tasks": {
        "server_task": "OpenCodeVoiceServer",
        "hotkey_task": "OpenCodeVoiceHotkey",
    },
}

ENV_OVERRIDES = {
    ("voice", "port"): "OPENCODE_VOICE_PORT",
    ("voice", "device"): "OPENCODE_VOICE_DEVICE",
    ("voice", "language"): "OPENCODE_VOICE_LANG",
    ("voice", "preroll_ms"): "OPENCODE_VOICE_PREROLL_MS",
    ("voice", "model_dir"): "OPENCODE_VOICE_MODEL",
}

SAMPLE_RATE = 16000            # ASR 输入采样率
PREBUFFER_SECONDS = 2.5        # 环形缓冲区长度
BLOCK_MS = 100                 # 采集块大小
MIN_RECORD_MS = 250            # 太短则忽略
MAX_RECORD_SLACK = 5           # 采集缓冲比上限多留几秒，避免录音中回绕

# ---------------------------------------------------------------- 日志
logger = logging.getLogger("voice")
logger.setLevel(logging.INFO)
_handler = RotatingFileHandler(
    os.path.join(HERE, "voice_server.log"), maxBytes=1_000_000, backupCount=2, encoding="utf-8"
)
_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
logger.addHandler(_handler)


def log(msg: str) -> None:
    logger.info(msg)


# ---------------------------------------------------------------- 配置
class Settings:
    """voice.config.ini 的读写（环境变量优先）。"""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        self.data: dict[str, dict[str, str]] = {}
        self.load()

    def load(self) -> None:
        cp = configparser.ConfigParser(interpolation=None)
        try:
            # utf-8-sig：容忍配置文件带 BOM（PowerShell 写文件时常见）
            cp.read(self.path, encoding="utf-8-sig")
        except Exception as exc:  # noqa: BLE001
            log(f"读取配置失败，使用默认值: {exc}")
        data = {section: dict(values) for section, values in DEFAULTS.items()}
        for section in cp.sections():
            data.setdefault(section, {})
            for key, value in cp[section].items():
                data[section][key] = value
        for (section, key), env in ENV_OVERRIDES.items():
            if os.environ.get(env):
                data[section][key] = os.environ[env]
        with self.lock:
            self.data = data

    def get(self, section: str, key: str, default: str = "") -> str:
        with self.lock:
            return str(self.data.get(section, {}).get(key, default))

    def get_int(self, section: str, key: str, default: int = 0) -> int:
        try:
            return int(float(self.get(section, key, str(default))))
        except (TypeError, ValueError):
            return default

    def get_bool(self, section: str, key: str, default: bool = False) -> bool:
        raw = self.get(section, key, "1" if default else "0").strip().lower()
        return raw in ("1", "true", "yes", "on")

    def snapshot(self) -> dict:
        with self.lock:
            return json.loads(json.dumps(self.data))

    def update(self, changes: dict) -> None:
        """按行更新 INI（保留注释与顺序），然后重新加载。"""
        try:
            with open(self.path, "r", encoding="utf-8-sig") as handle:
                lines = handle.read().splitlines()
        except FileNotFoundError:
            lines = []

        pending: dict[str, dict[str, str]] = {}
        for section, values in (changes or {}).items():
            if isinstance(values, dict):
                pending[section] = {str(k).lower(): ("" if v is None else str(v)) for k, v in values.items()}

        out: list[str] = []
        section: str | None = None
        section_re = re.compile(r"^\s*\[(.+?)\]\s*$")
        key_re = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*)$")
        for line in lines:
            match = section_re.match(line)
            if match:
                if section and section in pending:
                    for key, value in list(pending[section].items()):
                        out.append(f"{key}={value}")
                        pending[section].pop(key, None)
                section = match.group(1).strip()
                out.append(line)
                continue
            km = key_re.match(line)
            if km and section in pending:
                key = km.group(2)
                if key.lower() in pending[section]:
                    out.append(f"{km.group(1)}{key}{km.group(3)}{pending[section].pop(key.lower())}")
                    continue
            out.append(line)

        for sec, values in pending.items():
            if not values:
                continue
            out.append(f"[{sec}]")
            for key, value in values.items():
                out.append(f"{key}={value}")

        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(out) + "\n")
        self.load()
        log(f"配置已更新: {json.dumps(changes, ensure_ascii=False)}")


settings = Settings(CONFIG_PATH)
PORT = settings.get_int("voice", "port", 17860)
MODEL_DIR = settings.get("voice", "model_dir") or os.path.join(HERE, "models", "Qwen3-ASR-1.7B")


# ---------------------------------------------------------------- 剪贴板
def set_clipboard(text: str) -> None:
    """把文本写入 Windows 剪贴板（不依赖第三方库）。"""
    import ctypes

    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 0x0002
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    user32.SetClipboardData.restype = ctypes.c_void_p

    if not user32.OpenClipboard(None):
        raise OSError("OpenClipboard 失败")
    try:
        user32.EmptyClipboard()
        data = text.encode("utf-16-le") + b"\x00\x00"
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not handle:
            raise OSError("GlobalAlloc 失败")
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            kernel32.GlobalFree(ctypes.c_void_p(handle))
            raise OSError("GlobalLock 失败")
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(ctypes.c_void_p(handle))
        if not user32.SetClipboardData(CF_UNICODETEXT, ctypes.c_void_p(handle)):
            kernel32.GlobalFree(ctypes.c_void_p(handle))
            raise OSError("SetClipboardData 失败")
    finally:
        user32.CloseClipboard()


# ---------------------------------------------------------------- 麦克风采集
class Recorder:
    """持续采集 + 环形缓冲 + 录音。"""

    def __init__(self, device_spec: str):
        import sounddevice as sd

        self.sd = sd
        self.lock = threading.Lock()
        self.device_spec = device_spec
        self.device_index = self._resolve_device(device_spec)
        self.stream_rate = self._pick_rate()
        self.pre: deque[np.ndarray] = deque()
        self.pre_frames = 0
        self.max_pre_frames = int(PREBUFFER_SECONDS * self.stream_rate)
        self.buffer: np.ndarray | None = None      # 预分配采集缓冲（避免每轮拼接）
        self.buffer_capacity = 0
        self.write_pos = 0
        self.capture_frames = 0                    # 本次录音累计帧数
        self.recording = False
        self.injected: str | None = None   # 调试用：下一次 /stop 使用的 wav 路径
        self.frames_received = 0           # 采集到的总帧数（诊断用）
        self.last_frame_ts = 0.0           # 最近一次收到音频的时间
        self.level_rms = 0.0               # 输入电平（指数平滑 RMS）
        self.mic_error: str | None = None  # 采集异常信息（正常时为 None）
        self.recoveries = 0                # 自动恢复次数
        self._watchdog: threading.Thread | None = None
        self._watchdog_stop = threading.Event()

        info = self.sd.query_devices(self.device_index, "input")
        log(f"麦克风: [{self.device_index}] {info['name']} @ {self.stream_rate}Hz")
        self.stream = self._open_stream()

    # -- 设备 / 采样率 ---------------------------------------------
    def _open_stream(self, rate: int | None = None):
        rate = rate or self.stream_rate
        blocksize = max(int(rate * BLOCK_MS / 1000), 256)
        stream = self.sd.InputStream(
            device=self.device_index,
            channels=1,
            samplerate=rate,
            dtype="float32",
            blocksize=blocksize,
            callback=self._callback,
        )
        stream.start()
        return stream

    def _resolve_device(self, spec: str):
        if not spec:
            return None
        devices = self.sd.query_devices()
        inputs = [(i, d) for i, d in enumerate(devices) if d["max_input_channels"] > 0]
        if spec.isdigit():
            idx = int(spec)
            for i, _ in inputs:
                if i == idx:
                    return idx
            log(f"警告: 设备序号 {idx} 不是输入设备，改用系统默认")
            return None
        low = spec.lower()
        for i, d in inputs:
            if low in d["name"].lower():
                return i
        log(f"警告: 未找到名称包含 {spec!r} 的麦克风，改用系统默认")
        return None

    def _pick_rate(self) -> int:
        info = self.sd.query_devices(self.device_index, "input")
        default_rate = int(info["default_samplerate"] or 48000)
        for rate in (SAMPLE_RATE, default_rate):
            try:
                self.sd.check_input_settings(
                    device=self.device_index, channels=1, samplerate=rate, dtype="float32"
                )
                return rate
            except Exception:
                continue
        return default_rate

    def restart(self, device_spec: str) -> bool:
        """切换 / 重开麦克风。返回是否成功（失败时记录 mic_error，不抛异常）。"""
        old = self.stream
        try:
            old.stop()
            old.close()
        except Exception as exc:  # noqa: BLE001
            log(f"关闭旧采集流失败: {exc}")

        self.device_spec = device_spec
        self.device_index = self._resolve_device(device_spec)
        try:
            rate = self._pick_rate()
        except Exception as exc:  # noqa: BLE001
            self.mic_error = f"选择采样率失败: {exc}"
            log(self.mic_error)
            return False
        try:
            stream = self._open_stream(rate)
        except Exception as exc:  # noqa: BLE001
            self.mic_error = f"打开麦克风失败: {exc}"
            log(self.mic_error)
            return False

        with self.lock:
            self.stream_rate = rate
            self.stream = stream
            self.pre.clear()
            self.pre_frames = 0
            self.max_pre_frames = int(PREBUFFER_SECONDS * rate)
            self.capture = None
            self.capture_frames = 0
            self.recording = False
            self.mic_error = None
        try:
            name = self.sd.query_devices(self.device_index, "input")["name"]
        except Exception:  # noqa: BLE001
            name = "?"
        log(f"已重开麦克风: [{self.device_index}] {name} @ {rate}Hz")
        return True

    # -- 回调 ------------------------------------------------------
    def _callback(self, indata, frames, time_info, status):
        if status:
            logger.debug(f"采集状态: {status}")
        mono = indata.mean(axis=1) if indata.ndim > 1 else indata.copy()
        self.frames_received += int(frames)
        self.last_frame_ts = time.time()
        # 输入电平（指数平滑，约 0.3 秒时间常数）
        try:
            block_rms = float(np.sqrt(np.mean(np.square(mono, dtype=np.float32))))
            self.level_rms = self.level_rms * 0.7 + block_rms * 0.3
        except Exception:  # noqa: BLE001
            pass
        with self.lock:
            if self.recording and self.buffer is not None:
                self._write_buffer(mono)
            self.pre.append(mono)
            self.pre_frames += mono.size
            while self.pre and self.pre_frames - self.pre[0].size >= self.max_pre_frames:
                self.pre_frames -= self.pre.popleft().size

    def _write_buffer(self, mono: np.ndarray) -> None:
        """写入预分配缓冲；写满后从最旧处覆盖。调用方需持有锁。"""
        n = mono.size
        capacity = self.buffer_capacity
        if n >= capacity:
            self.buffer[:] = mono[-capacity:]
            self.write_pos = 0
        else:
            end = self.write_pos + n
            if end <= capacity:
                self.buffer[self.write_pos:end] = mono
            else:
                first = capacity - self.write_pos
                self.buffer[self.write_pos:] = mono[:first]
                self.buffer[: n - first] = mono[first:]
            self.write_pos = end % capacity
        self.capture_frames += n

    def _read_buffer_locked(self) -> tuple[np.ndarray, int]:
        """读取当前录音数据（连续副本）。调用方需持有锁。"""
        if self.buffer is None or self.capture_frames == 0:
            return np.zeros(0, dtype=np.float32), self.stream_rate
        count = min(self.capture_frames, self.buffer_capacity)
        if count < self.buffer_capacity:
            return self.buffer[:count].copy(), self.stream_rate
        return np.concatenate((self.buffer[self.write_pos:], self.buffer[: self.write_pos])), self.stream_rate

    # -- 录音控制 --------------------------------------------------
    def start(self) -> None:
        preroll_frames = int(settings.get_int("voice", "preroll_ms", 500) / 1000 * self.stream_rate)
        max_seconds = max(settings.get_int("voice", "max_record_seconds", 60), 5)
        with self.lock:
            self.buffer_capacity = int((max_seconds + MAX_RECORD_SLACK) * self.stream_rate)
            self.buffer = np.zeros(self.buffer_capacity, dtype=np.float32)
            self.write_pos = 0
            self.capture_frames = 0
            chunks: list[np.ndarray] = []
            need = preroll_frames
            for chunk in reversed(self.pre):
                if need <= 0:
                    break
                if chunk.size >= need:
                    chunks.append(chunk[-need:])
                    need = 0
                else:
                    chunks.append(chunk)
                    need -= chunk.size
            chunks.reverse()
            if chunks:
                self._write_buffer(np.concatenate(chunks))
            self.recording = True
        log(f"开始录音 (pre-roll {self.capture_frames / self.stream_rate * 1000:.0f}ms)")

    def stop(self) -> np.ndarray | None:
        injected = self.take_injected()
        with self.lock:
            self.recording = False
            data, rate = self._read_buffer_locked()
            self.buffer = None
            self.buffer_capacity = 0
            self.write_pos = 0
            self.capture_frames = 0
        if injected is not None:
            log(f"使用注入音频 ({injected.size / SAMPLE_RATE:.2f}s)")
            return injected
        if data.size == 0:
            return None
        duration_ms = data.size / rate * 1000
        if duration_ms < MIN_RECORD_MS:
            log(f"录音过短 ({duration_ms:.0f}ms)，忽略")
            return None
        log(f"停止录音 ({duration_ms:.0f}ms)")
        return self._to_16k(data, rate)

    def cancel(self) -> None:
        with self.lock:
            self.recording = False
            self.buffer = None
            self.buffer_capacity = 0
            self.write_pos = 0
            self.capture_frames = 0
        self.injected = None
        log("取消录音")

    def snapshot(self) -> tuple[np.ndarray, int]:
        """返回当前录音的音频副本（float32 单声道，采集采样率）与采样率。"""
        with self.lock:
            return self._read_buffer_locked()

    # -- 看门狗：采集流卡死时自动重开麦克风 ------------------------
    def start_watchdog(self) -> None:
        if self._watchdog and self._watchdog.is_alive():
            return
        self._watchdog_stop.clear()
        self._watchdog = threading.Thread(target=self._watchdog_run, name="mic-watchdog", daemon=True)
        self._watchdog.start()

    def stop_watchdog(self) -> None:
        self._watchdog_stop.set()

    def _watchdog_run(self) -> None:
        last_frames = -1
        stale = 0
        failures = 0
        delay = 5.0
        while not self._watchdog_stop.wait(delay):
            frames = self.frames_received
            if frames != last_frames:
                stale = 0
                failures = 0
                delay = 5.0
                last_frames = frames
                continue
            last_frames = frames
            stale += 1
            if stale < 2:                      # 约 10 秒没有新音频
                continue
            stale = 0
            log(f"采集流疑似卡死（第 {failures + 1} 次尝试恢复），正在重开麦克风 ...")
            if self._recover():
                failures = 0
                delay = 5.0
                self.recoveries += 1
                log("采集流已恢复")
            else:
                failures += 1
                delay = min(5.0 * (2 ** min(failures, 4)), 60.0)
                if failures >= 5:
                    log("麦克风连续恢复失败，退出服务以便被自动拉起（助手/计划任务会重启）")
                    try:
                        self._watchdog_stop.set()
                    except Exception:  # noqa: BLE001
                        pass
                    os._exit(3)

    def _recover(self, timeout: float = 20.0) -> bool:
        """在带超时的子线程里重开麦克风，避免驱动卡住时拖死看门狗。"""
        result = {"ok": False}

        def run() -> None:
            try:
                result["ok"] = self.restart(self.device_spec)
            except Exception as exc:  # noqa: BLE001
                log(f"重开麦克风异常: {exc}")

        thread = threading.Thread(target=run, name="mic-recover", daemon=True)
        thread.start()
        thread.join(timeout)
        if thread.is_alive():
            log(f"重开麦克风超时（>{timeout:.0f}s），稍后继续尝试")
            return False
        return bool(result["ok"])

    def inject(self, path: str) -> None:
        """调试用：让下一次 /stop 直接转写指定 wav 文件（用于自动化测试）。"""
        self.injected = path
        log(f"注入测试音频: {path}")

    def take_injected(self) -> np.ndarray | None:
        path = self.injected
        self.injected = None
        if not path:
            return None
        import soundfile as sf

        audio, sr = sf.read(path, dtype="float32", always_2d=True)
        audio = audio.mean(axis=1)
        if sr != SAMPLE_RATE:
            import librosa

            audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE).astype(np.float32)
        return audio

    def _to_16k(self, audio: np.ndarray, rate: int | None = None) -> np.ndarray:
        rate = rate or self.stream_rate
        if rate == SAMPLE_RATE:
            return audio
        import librosa

        return librosa.resample(audio, orig_sr=rate, target_sr=SAMPLE_RATE)


# ---------------------------------------------------------------- 语音识别
def resolve_device(spec: str) -> str:
    """解析计算设备。cpu 模式绝不触碰 torch.cuda（保证显存占用为 0）。"""
    spec = (spec or "auto").strip().lower()
    if spec == "cpu":
        return "cpu"
    try:
        import torch

        if torch.cuda.is_available():
            return "cuda:0"
        if spec == "cuda":
            log("未检测到可用的 CUDA，已回退到 CPU")
    except Exception as exc:  # noqa: BLE001
        log(f"检测 CUDA 失败，使用 CPU: {exc}")
    return "cpu"


class Transcriber:
    def __init__(self, model_dir: str, compute: str = "auto"):
        import torch

        self.torch = torch
        self.model_dir = model_dir
        self.device = resolve_device(compute)
        if self.device.startswith("cuda"):
            dtype = torch.bfloat16
        else:
            dtype = torch.float32
            try:
                torch.set_num_threads(max(1, (os.cpu_count() or 4)))
            except Exception:  # noqa: BLE001
                pass
        log(f"加载模型 {model_dir} (device={self.device}, dtype={dtype}) ...")
        t0 = time.time()
        from qwen_asr import Qwen3ASRModel

        self.model = Qwen3ASRModel.from_pretrained(
            model_dir,
            dtype=dtype,
            device_map=self.device,
            max_new_tokens=2048,
        )
        log(f"模型加载完成，用时 {time.time() - t0:.1f}s")
        self.lock = threading.Lock()
        self._warmup()

    @property
    def device_kind(self) -> str:
        return "cuda" if self.device.startswith("cuda") else "cpu"

    def _warmup(self) -> None:
        """按常见音频长度预热，避免首次长音频多花时间。"""
        for seconds in (1, 3, 8):
            try:
                noise = (np.random.rand(int(SAMPLE_RATE * seconds)).astype(np.float32) - 0.5) * 0.001
                t0 = time.time()
                self.transcribe(noise, SAMPLE_RATE, max_new_tokens=32)
                log(f"预热 {seconds}s 完成，用时 {time.time() - t0:.2f}s")
            except Exception as exc:  # noqa: BLE001
                log(f"预热 {seconds}s 失败（不影响使用）: {exc}")

    def transcribe(
        self,
        audio: np.ndarray,
        rate: int = SAMPLE_RATE,
        max_new_tokens: int | None = None,
    ) -> tuple[str, str]:
        """转写一段 float32 单声道音频；rate 为音频采样率（内部会自动重采样）。"""
        language = settings.get("voice", "language").strip() or None
        with self.lock:
            previous = self.model.max_new_tokens
            if max_new_tokens:
                self.model.max_new_tokens = max_new_tokens
            try:
                t0 = time.time()
                results = self.model.transcribe(audio=(audio, rate), language=language)
                cost = time.time() - t0
            finally:
                self.model.max_new_tokens = previous
        text = (results[0].text or "").strip()
        lang = getattr(results[0], "language", "") or ""
        log(f"转写完成 ({cost:.2f}s, lang={lang}): {text[:80]!r}")
        return text, lang


# ---------------------------------------------------------------- 分段增量识别
_PUNCT_RE = re.compile(r"[\s，。！？、；：,.!?;:\"'“”‘’（）()【】\[\]…—\-~]")

SILENCE_RMS = 0.0015         # 低于此 RMS 视为静音（约 -56dBFS，可配置）


def is_silent(audio: np.ndarray, threshold: float | None = None) -> bool:
    """判断音频是否基本无声，避免对静音产生幻觉文本。"""
    if audio is None or audio.size == 0:
        return True
    if threshold is None:
        threshold = max(settings.get_int("voice", "silence_rms_x10000", 10) / 10000, 0.0002)
    rms = float(np.sqrt(np.mean(np.square(audio.astype(np.float32)))))
    return rms < threshold


def rms_of(audio: np.ndarray) -> float:
    if audio is None or audio.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(audio.astype(np.float32)))))


def db_of(rms: float) -> float:
    """转成 dBFS（-inf 用 -100 表示）。"""
    if rms <= 1e-6:
        return -100.0
    import math

    return round(20 * math.log10(rms), 1)


def merge_overlap(prefix: str, addition: str, max_overlap: int = 80) -> str:
    """把 addition 接到 prefix 后，去掉重叠部分（用于段落拼接）。"""
    if not prefix:
        return addition
    if not addition:
        return prefix
    limit = min(len(prefix), len(addition), max_overlap)
    for k in range(limit, 1, -1):
        if prefix[-k:] == addition[:k]:
            return prefix + addition[k:]
    # 标点可能略有差异：去掉标点后再匹配一次，并映射回原串位置
    ps = _PUNCT_RE.sub("", prefix)
    as_ = _PUNCT_RE.sub("", addition)
    for k in range(min(len(ps), len(as_), max_overlap), 1, -1):
        if ps[-k:] == as_[:k]:
            count = 0
            for i, ch in enumerate(addition):
                if not _PUNCT_RE.match(ch):
                    count += 1
                    if count == k:
                        return prefix + addition[i + 1:]
            break
    return prefix + addition


class Streamer:
    """分段增量识别：已提交前缀 + 当前段实时预览。

    - 每 segment_seconds 秒把当前段"定稿"提交到前缀，之后不再重复识别
    - 预览只识别"当前段（含重叠）"，单次耗时恒定，长语音不退化
    - 显示内容 = 已提交前缀 + 当前段
    """

    def __init__(self, recorder: Recorder, asr: Transcriber):
        self.recorder = recorder
        self.asr = asr
        self.thread: threading.Thread | None = None
        self.stop_event = threading.Event()
        self.final_pending = threading.Event()
        self.lock = threading.Lock()
        self.committed_text = ""
        self.preview_text = ""
        self.seq = 0
        self.last_cost = 0.0
        self.last_pass_ts = 0.0
        self.covered_ms = 0
        self.segment_start_frame = 0
        self.segments = 0

    # -- 生命周期 --------------------------------------------------
    def start(self) -> None:
        self.stop()
        with self.lock:
            self.committed_text = ""
            self.preview_text = ""
            self.seq = 0
            self.last_cost = 0.0
            self.last_pass_ts = 0.0
            self.covered_ms = 0
            self.segment_start_frame = 0
            self.segments = 0
        self.stop_event.clear()
        self.final_pending.clear()
        self.thread = threading.Thread(target=self._run, name="streamer", daemon=True)
        self.thread.start()

    def begin_final(self) -> None:
        """最终结果优先：预览线程不再开始新的识别。"""
        self.final_pending.set()
        self.stop_event.set()

    def stop(self) -> None:
        self.stop_event.set()
        thread = self.thread
        self.thread = None
        if thread and thread.is_alive() and thread is not threading.current_thread():
            thread.join(timeout=5)

    def state(self) -> dict:
        with self.lock:
            return {
                "text": self.preview_text,
                "seq": self.seq,
                "audio_ms": self.covered_ms,
                "last_cost_ms": int(self.last_cost * 1000),
                "last_pass_ts": self.last_pass_ts,
                "committed_chars": len(self.committed_text),
                "segments": self.segments,
            }

    # -- 定稿（/stop 调用，必须在 recorder.stop() 之前） -----------
    def finalize(self) -> tuple[str, float]:
        audio, rate = self.recorder.snapshot()
        with self.lock:
            committed = self.committed_text
            start_frame = self.segment_start_frame
        if audio.size == 0:
            return committed, 0.0
        overlap_ms = max(settings.get_int("voice", "segment_overlap_ms", 600), 0)
        begin = max(0, start_frame - int(overlap_ms / 1000 * rate))
        chunk = audio[begin:]
        if chunk.size == 0:
            return committed, 0.0
        t0 = time.time()
        text = self._transcribe(chunk, rate)
        cost = time.time() - t0
        with self.lock:
            self.committed_text = merge_overlap(committed, text)
            self.preview_text = self.committed_text
            return self.committed_text, cost

    # -- 内部 ------------------------------------------------------
    def _transcribe(self, audio: np.ndarray, rate: int, max_new_tokens: int = 256) -> str:
        if is_silent(audio):
            log(f"音频电平过低（{db_of(rms_of(audio))}dBFS），跳过识别")
            return ""
        try:
            text, _ = self.asr.transcribe(audio, rate, max_new_tokens=max_new_tokens)
            return text
        except Exception as exc:  # noqa: BLE001
            log(f"预览转写失败: {exc}")
            return ""

    def _run(self) -> None:
        if not settings.get_bool("voice", "partial_enabled", True):
            log("实时预览已禁用")
            return
        interval = max(settings.get_int("voice", "partial_interval_ms", 280), 100) / 1000
        segment_ms = max(settings.get_int("voice", "segment_seconds", 5), 1) * 1000
        overlap_ms = max(settings.get_int("voice", "segment_overlap_ms", 600), 0)
        growth_ms = max(settings.get_int("voice", "partial_min_growth_ms", 150), 0)
        min_first = max(settings.get_int("voice", "partial_min_first_ms", 300), 100)
        log(f"分段识别已启动 (间隔 {interval * 1000:.0f}ms, 段落 {segment_ms / 1000:.0f}s, 重叠 {overlap_ms}ms)")
        last_covered = 0
        while not self.stop_event.is_set():
            started = time.time()
            if not self.recorder.recording:
                break
            if not self.final_pending.is_set():
                audio, rate = self.recorder.snapshot()
                total_ms = int(audio.size / rate * 1000) if rate else 0
                if total_ms > 0 and (total_ms - last_covered) >= growth_ms:
                    finalized = self._advance_segments(audio, rate, total_ms, segment_ms, overlap_ms)
                    if finalized:
                        # 定稿已经把文字推进到段落末尾，本轮无需再跑一次尾部识别
                        with self.lock:
                            self.preview_text = self.committed_text
                            self.seq += 1
                            self.covered_ms = int(self.segment_start_frame / rate * 1000)
                            self.last_pass_ts = started
                        last_covered = total_ms
                    else:
                        published = self._publish_tail(audio, rate, total_ms, overlap_ms, min_first)
                        last_covered = total_ms      # 无论是否出字都推进进度，避免空转
                        if published:
                            with self.lock:
                                self.last_pass_ts = started
            cost = time.time() - started
            with self.lock:
                self.last_cost = cost
            self.stop_event.wait(max(interval - cost, 0.03))
        log("分段识别已停止")

    def _advance_segments(self, audio, rate, total_ms, segment_ms, overlap_ms) -> bool:
        """把已经攒满的段落定稿并提交；返回是否至少定稿了一段。"""
        did = False
        while True:
            with self.lock:
                start_frame = self.segment_start_frame
                committed = self.committed_text
            start_ms = start_frame / rate * 1000
            if total_ms - start_ms < segment_ms:
                return did
            end_frame = int((start_ms + segment_ms) / 1000 * rate)
            begin = max(0, start_frame - int(overlap_ms / 1000 * rate))
            chunk = audio[begin:end_frame]
            if chunk.size == 0:
                return did
            text = self._transcribe(chunk, rate)
            with self.lock:
                self.committed_text = merge_overlap(committed, text)
                self.segment_start_frame = end_frame
                self.segments += 1
            did = True
            log(f"段落 {self.segments} 定稿 ({chunk.size / rate:.1f}s): {text[:40]!r}")

    def _publish_tail(self, audio, rate, total_ms, overlap_ms, min_first) -> bool:
        with self.lock:
            start_frame = self.segment_start_frame
            committed = self.committed_text
        tail_ms = total_ms - start_frame / rate * 1000
        if tail_ms < min_first:
            return False
        begin = max(0, start_frame - int(overlap_ms / 1000 * rate))
        chunk = audio[begin:]
        if chunk.size == 0:
            return False
        text = self._transcribe(chunk, rate)
        if text == "":
            return False
        with self.lock:
            self.preview_text = merge_overlap(committed, text)
            self.seq += 1
            self.covered_ms = total_ms
        return True


# ---------------------------------------------------------------- HTTP 服务
recorder: Recorder | None = None
asr: Transcriber | None = None
streamer: Streamer | None = None
ready = threading.Event()
last_error: str | None = None      # 最近一次转写错误（诊断用）


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OpenCodeVoice/1.0"

    def log_message(self, fmt, *args):  # noqa: A003
        logger.debug("http %s", fmt % args)

    # -- 工具 ------------------------------------------------------
    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _text(self, code: int, text: str) -> None:
        self._send(code, text.encode("utf-8"), "text/plain; charset=utf-8")

    def _json(self, code: int, obj: dict) -> None:
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _html(self, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_settings(self) -> None:
        path = os.path.join(HERE, "settings.html")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                self._html(handle.read())
        except FileNotFoundError:
            self._text(404, "settings.html not found")

    def _config_view(self) -> dict:
        return {
            "config": settings.snapshot(),
            "effective": {
                "port": PORT,
                "device_index": getattr(recorder, "device_index", None),
                "device_name": None,
                "rate": getattr(recorder, "stream_rate", None),
                "model_dir": MODEL_DIR,
            },
        }

    # -- GET -------------------------------------------------------
    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path in ("/settings", "/settings.html", "/"):
            self._serve_settings()
            return
        if path == "/health":
            now = time.time()
            level_db = db_of(getattr(recorder, "level_rms", 0.0))
            self._json(200, {
                "ok": True,
                "ready": ready.is_set(),
                "recording": bool(recorder and recorder.recording),
                "device": getattr(recorder, "device_index", None),
                "rate": getattr(recorder, "stream_rate", None),
                "frames": getattr(recorder, "frames_received", 0),
                "audio_flowing": bool(recorder and (now - recorder.last_frame_ts) < 2.0),
                "input_db": level_db,
                "device_kind": asr.device_kind if asr else None,
                "compute": settings.get("voice", "compute", "auto"),
                "mic_error": getattr(recorder, "mic_error", None),
                "recoveries": getattr(recorder, "recoveries", 0),
                "last_error": last_error,
                "partial": bool(streamer and streamer.thread and streamer.thread.is_alive()),
                "segments": getattr(streamer, "segments", 0),
                "committed_chars": len(streamer.committed_text) if streamer else 0,
                "last_partial_ms": int(streamer.last_cost * 1000) if streamer else 0,
            })
        elif path == "/devices":
            try:
                devs = recorder.sd.query_devices() if recorder else []
                items = [
                    {"index": i, "name": d["name"], "channels": d["max_input_channels"]}
                    for i, d in enumerate(devs) if d["max_input_channels"] > 0
                ]
                self._json(200, {"devices": items})
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"error": str(exc)})
        elif path == "/devices.txt":
            try:
                devs = recorder.sd.query_devices() if recorder else []
                lines = [
                    f"{i}|{d['name']}"
                    for i, d in enumerate(devs)
                    if d["max_input_channels"] > 0
                ]
                self._text(200, "\n".join(lines))
            except Exception as exc:  # noqa: BLE001
                self._text(500, f"error: {exc}")
        elif path == "/config":
            self._json(200, self._config_view())
        elif path == "/partial":
            ensure_streamer_alive()
            state = streamer.state() if streamer else {"text": "", "seq": 0, "audio_ms": 0}
            self._json(200, {
                "ok": True,
                "ready": ready.is_set(),
                "recording": bool(recorder and recorder.recording),
                **state,
            })
        elif path == "/partial.txt":
            ensure_streamer_alive()
            text = streamer.state()["text"] if streamer else ""
            self._text(200, text)
        elif path == "/level.txt":
            self._text(200, str(db_of(getattr(recorder, "level_rms", 0.0))))
        elif path == "/device.txt":
            self._text(200, asr.device_kind if asr else "")
        elif path == "/audio.txt":
            ms = 0
            if recorder and recorder.recording:
                with recorder.lock:
                    frames = recorder.capture_frames
                ms = int(frames / (recorder.stream_rate or 1) * 1000)
            self._text(200, str(ms))
        else:
            self._text(404, "not found")

    # -- POST ------------------------------------------------------
    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if path == "/clipboard":
            try:
                set_clipboard(body.decode("utf-8", "replace"))
                self._text(200, "ok")
            except Exception as exc:  # noqa: BLE001
                log(f"写剪贴板失败: {exc}")
                self._text(500, f"error: {exc}")
            return

        if path == "/preview":
            # 通过命令文件让助手显示悬浮窗预览
            try:
                with open(os.path.join(HERE, "voice.command"), "w", encoding="utf-8") as handle:
                    handle.write("preview")
                self._text(200, "ok")
            except Exception as exc:  # noqa: BLE001
                self._text(500, f"error: {exc}")
            return

        if not ready.is_set():
            self._text(503, "model not ready")
            return

        assert recorder is not None and asr is not None
        if path == "/start":
            recorder.start()
            if streamer:
                streamer.start()
            self._text(200, "ok")
        elif path == "/stop":
            global last_error
            try:
                text = ""
                injected = bool(recorder.injected)
                if streamer and not injected:
                    streamer.begin_final()      # 最终结果优先
                    streamer.stop()             # 等预览线程退出
                    text, _ = streamer.finalize()   # 只用最后一段做定稿（前缀已提交）
                audio = recorder.stop()
                if not text:
                    # 兜底：对整段音频完整转写（例如录音很短、被禁用或调试注入）
                    if audio is None or audio.size == 0:
                        self._text(200, "")
                        return
                    if is_silent(audio):
                        log("音频近似静音，跳过转写")
                        self._text(200, "")
                        return
                    for attempt in (1, 2):
                        try:
                            text, _ = asr.transcribe(audio, SAMPLE_RATE, max_new_tokens=512)
                            last_error = None
                            break
                        except Exception as exc:  # noqa: BLE001
                            last_error = str(exc)
                            log(f"转写失败（第 {attempt}/2 次）: {exc}")
                            if attempt == 2:
                                raise
                            time.sleep(0.4)
                self._text(200, text)
            except Exception as exc:  # noqa: BLE001
                log(f"转写失败: {exc}")
                self._text(500, f"error: {exc}")
        elif path == "/cancel":
            recorder.cancel()
            if streamer:
                streamer.stop()
            self._text(200, "ok")
        elif path == "/config":
            try:
                changes = json.loads(body.decode("utf-8", "replace") or "{}")
                if not isinstance(changes, dict):
                    changes = {}
                voice_changes = changes.get("voice")
                if not isinstance(voice_changes, dict):
                    voice_changes = {}

                old_port = PORT
                old_device = settings.get("voice", "device")
                old_compute = settings.get("voice", "compute", "auto")
                new_compute = str(voice_changes.get("compute", old_compute)).strip().lower()
                if new_compute not in ("auto", "cuda", "cpu"):
                    new_compute = old_compute
                compute_changed = new_compute != old_compute

                if compute_changed and recorder and recorder.recording:
                    self._json(409, {"error": "正在录音，请先结束录音再切换计算设备"})
                    return
                if compute_changed:
                    # 切到 CPU 时自动关闭实时预览（省 CPU）；切回时恢复
                    voice_changes["partial_enabled"] = "0" if new_compute == "cpu" else "1"
                    changes["voice"] = voice_changes

                settings.update(changes)
                new_port = settings.get_int("voice", "port", old_port)
                new_device = settings.get("voice", "device")
                view = self._config_view()
                if new_device != old_device and not compute_changed:
                    if not recorder.restart(new_device):
                        view["warning"] = recorder.mic_error or "切换麦克风失败"
                restart_required = compute_changed or (new_port != old_port)
                view["restart_required"] = restart_required
                self._json(200, view)
                if restart_required:
                    schedule_restart()
            except Exception as exc:  # noqa: BLE001
                log(f"更新配置失败: {exc}")
                self._json(500, {"error": str(exc)})
        elif path == "/inject":
            file_path = body.decode("utf-8", "replace").strip()
            if not file_path or not os.path.isfile(file_path):
                self._text(400, "wav path required")
                return
            recorder.inject(file_path)
            self._text(200, "ok")
        else:
            self._text(404, "not found")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # Windows 下 SO_REUSEADDR 会让多个实例同时绑定同一端口，必须关闭
    allow_reuse_address = False


def ensure_streamer_alive() -> None:
    """录音中若预览线程已停止，自动重启（助手会持续轮询，可快速自愈）。"""
    if recorder and recorder.recording and streamer:
        alive = bool(streamer.thread and streamer.thread.is_alive())
        if not alive:
            log("检测到预览线程已停止，正在重启")
            try:
                streamer.start()
            except Exception as exc:  # noqa: BLE001
                log(f"重启预览线程失败: {exc}")


def schedule_restart() -> None:
    """先应答请求，然后启动一个分离的新进程并退出自身。

    进程级切换可保证显存完全释放（切到 CPU 时新进程不初始化 CUDA）。
    """
    log("配置需要重启服务，正在自重启 ...")

    def run() -> None:
        time.sleep(0.6)
        try:
            flags = 0
            if os.name == "nt":
                flags = 0x00000008 | 0x00000200      # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
            subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "--restart-delay", "2"],
                cwd=HERE,
                creationflags=flags,
                close_fds=True,
            )
        except Exception as exc:  # noqa: BLE001
            log(f"自重启失败: {exc}")
        os._exit(0)

    threading.Thread(target=run, daemon=True).start()


def existing_instance_alive(timeout: float = 1.5) -> bool:
    """端口上是否已有健康的语音服务在运行。"""
    import urllib.request

    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=timeout) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001
        return False


def main() -> None:
    global recorder, asr, streamer
    log("=" * 60)

    # 单实例保护：端口上已有健康实例就不再启动（避免抢麦克风/抢请求）
    if existing_instance_alive():
        log(f"检测到端口 {PORT} 上已有语音服务在运行，本实例退出")
        return
    log(
        f"启动: model={MODEL_DIR} port={PORT} "
        f"device={settings.get('voice', 'device') or 'default'} "
        f"preroll={settings.get_int('voice', 'preroll_ms', 500)}ms"
    )

    asr = Transcriber(MODEL_DIR, settings.get("voice", "compute", "auto"))
    try:
        recorder = Recorder(settings.get("voice", "device"))
    except Exception as exc:  # noqa: BLE001
        log(f"麦克风初始化失败: {exc}")
        raise

    ready.set()
    streamer = Streamer(recorder, asr)
    recorder.start_watchdog()
    try:
        httpd = Server(("127.0.0.1", PORT), Handler)
    except OSError as exc:
        log(f"端口 {PORT} 无法绑定（可能已有实例在运行）: {exc}")
        sys.exit(0)
    log(f"服务就绪: http://127.0.0.1:{PORT}/health")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    except Exception as exc:  # noqa: BLE001
        log(f"HTTP 服务异常退出: {exc}")
        sys.exit(4)
    finally:
        httpd.server_close()
        try:
            if recorder:
                recorder.stream.stop()
                recorder.stream.close()
        except Exception:  # noqa: BLE001
            pass
        log("已退出")


if __name__ == "__main__":
    # 支持自重启：--restart-delay <秒>（用于切换计算设备时进程级重启，保证显存完全释放）
    argv = sys.argv[1:]
    if "--restart-delay" in argv:
        try:
            delay = float(argv[argv.index("--restart-delay") + 1])
        except (IndexError, ValueError):
            delay = 2.0
        time.sleep(max(delay, 0.5))
    try:
        main()
    except Exception:  # noqa: BLE001
        logger.exception("启动失败")
        sys.exit(1)
