#!/usr/bin/env python3
"""Measure prompt processing (PP) and token generation (TG) on a Strata server.

It reads the server's own `timings` block (the same numbers `/metrics` shows)
and samples system CPU busy and NVIDIA GPU power/utilization while the request
runs.  Use it for long, agentic-coding-sized prompts:

    ./bench.py --tokens 32768 131072 245000 --generate 256

For a thread sweep, change `LLM_POOL_WORKERS`, reinstall the service, then run
this again with `--label`; the JSON line records the label.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_KEY = Path.home() / ".config/llm-server/api-key"

PROSE = (
    "The repository keeps a long migration log. Each entry names the change, "
    "the reason, the measurement that justified it, and the rollback plan. "
    "The notes are deliberately verbose so a later reader can reconstruct the "
    "decision without opening the original ticket. Numbers carry their units, "
    "dates are written in full, and every experiment names the hardware it ran "
    "on. When a result was surprising, the entry records what was ruled out. "
)
CODE = (
    "def apply_plan(plan, state):\n"
    "    for step in plan:\n"
    "        if step.skip:\n"
    "            continue\n"
    "        state = step.apply(state)\n"
    "        assert state.valid, step.name\n"
    "    return state\n"
    "\n"
    "# The retry path keeps the previous checkpoint so a failed step can be\n"
    "# replayed without reading the whole document again.\n"
    "def retry(plan, state, checkpoint):\n"
    "    try:\n"
    "        return apply_plan(plan, state)\n"
    "    except TransientError:\n"
    "        return apply_plan(plan, checkpoint)\n"
)


def cpu_times() -> tuple[int, int]:
    with open("/proc/stat", encoding="ascii") as fh:
        parts = fh.readline().split()[1:]
    values = [int(x) for x in parts]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def gpu_sample() -> tuple[float | None, float | None, float | None]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=utilization.gpu,power.draw,memory.used",
             "--format=csv,noheader,nounits"],
            text=True, timeout=5, stderr=subprocess.DEVNULL,
        ).strip().splitlines()
    except (OSError, subprocess.SubprocessError):
        return None, None, None
    if not out:
        return None, None, None
    fields = [x.strip() for x in out[0].split(",")]
    try:
        util = float(fields[0])
    except (ValueError, IndexError):
        util = None
    try:
        power = float(fields[1])
    except (ValueError, IndexError):
        power = None
    try:
        mem = float(fields[2])
    except (ValueError, IndexError):
        mem = None
    return util, power, mem


class Sampler(threading.Thread):
    def __init__(self, interval: float = 1.0):
        super().__init__(daemon=True)
        self.interval = interval
        self.samples: list[tuple[float, float, float | None, float | None, float | None]] = []
        self._stop = threading.Event()

    def run(self) -> None:
        last_total, last_idle = cpu_times()
        while not self._stop.wait(self.interval):
            now = time.monotonic()
            total, idle = cpu_times()
            delta = total - last_total
            busy = 0.0 if delta <= 0 else 100.0 * (1.0 - (idle - last_idle) / delta)
            util, power, mem = gpu_sample()
            self.samples.append((now, busy, util, power, mem))
            last_total, last_idle = total, idle

    def stop(self) -> None:
        self._stop.set()
        self.join(timeout=2)


def window(samples, start: float, end: float) -> dict:
    picked = [s for s in samples if start <= s[0] <= end]
    if not picked and samples:
        picked = [min(samples, key=lambda s: abs(s[0] - (start + end) / 2))]
    if not picked:
        return {}
    def mean(index):
        vals = [s[index] for s in picked if s[index] is not None]
        return round(sum(vals) / len(vals), 2) if vals else None
    return {
        "cpu_busy_pct": mean(1),
        "cpu_cores": round(mean(1) / 100.0 * (os.cpu_count() or 1), 2) if mean(1) is not None else None,
        "gpu_util_pct": mean(2),
        "gpu_power_w": mean(3),
        "gpu_mem_mib": mean(4),
        "samples": len(picked),
    }


def request(url: str, payload: dict, key: str, timeout: int) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def models(base: str, key: str) -> list[str]:
    req = urllib.request.Request(base + "/v1/models", headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.load(resp)
    return [m["id"] for m in body.get("data", [])]


def make_text(chars: int, nonce: str) -> str:
    head = (
        f"Benchmark run {nonce}. You are reviewing a repository. Read the notes and code, "
        "then state the three highest-risk changes and why.\n\n"
    )
    block = (PROSE + "\n" + CODE + "\n") * 8
    body = block * (chars // len(block) + 1)
    return head + body[: max(0, chars - len(head))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("LLM_BASE", "http://127.0.0.1:8080"))
    parser.add_argument("--key-file", default=str(DEFAULT_KEY))
    parser.add_argument("--model")
    parser.add_argument("--tokens", type=int, nargs="+", default=[32768, 131072, 245000],
                        help="target prompt sizes in tokens")
    parser.add_argument("--generate", type=int, default=256)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--label", default="")
    parser.add_argument("--out", help="append JSON lines here")
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--calibrate-chars", type=int, default=16000)
    args = parser.parse_args()

    key = Path(args.key_file).read_text().strip()
    model = args.model or models(args.base, key)[0]
    nonce = str(int(time.time()))
    print(f"model={model} label={args.label or '-'}", flush=True)

    cal_text = make_text(args.calibrate_chars, nonce + "-cal")
    cal = request(args.base + "/v1/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": cal_text}],
        "max_tokens": 4,
        "temperature": 0,
    }, key, args.timeout)
    cal_tokens = cal["usage"]["prompt_tokens"]
    ratio = len(cal_text) / cal_tokens
    print(f"calibration={cal_tokens} tokens ratio={ratio:.3f} chars/token", flush=True)

    for target in args.tokens:
        for run in range(args.repeat):
            chars = int(target * ratio)
            for attempt in range(5):
                text = make_text(chars, f"{nonce}-{target}-{run}-{attempt}")
                sampler = Sampler()
                sampler.start()
                time.sleep(1.1)  # let the sampler take its first interval
                started = time.monotonic()
                try:
                    body = request(args.base + "/v1/chat/completions", {
                        "model": model,
                        "messages": [{"role": "user", "content": text}],
                        "max_tokens": args.generate,
                        "temperature": 0,
                    }, key, args.timeout)
                    break
                except urllib.error.HTTPError as exc:
                    sampler.stop()
                    detail = exc.read().decode(errors="replace")
                    if exc.code == 400 and attempt < 4:
                        print(f"target={target}: rejected at {chars} chars; retrying smaller: {detail[:160]}",
                              flush=True)
                        chars = int(chars * 0.95)
                        continue
                    raise
                finally:
                    if sampler.is_alive():
                        sampler.stop()
            ended = time.monotonic()
            timings = body.get("timings") or {}
            usage = body.get("usage") or {}
            prompt_ms = float(timings.get("prompt_ms") or 0)
            pp_end = started + prompt_ms / 1000.0
            pp_stats = window(sampler.samples, started, pp_end)
            tg_stats = window(sampler.samples, pp_end, ended)
            row = {
                "label": args.label,
                "model": model,
                "target_tokens": target,
                "prompt_tokens": usage.get("prompt_tokens"),
                "completion_tokens": usage.get("completion_tokens"),
                "pp_tok_s": timings.get("prompt_per_second"),
                "pp_s": round(prompt_ms / 1000.0, 3),
                "tg_tok_s": timings.get("predicted_per_second"),
                "tg_s": round(float(timings.get("predicted_ms") or 0) / 1000.0, 3),
                "predicted_n": timings.get("predicted_n"),
                "finish_reason": (body.get("choices") or [{}])[0].get("finish_reason"),
                "pp_cpu_pct": pp_stats.get("cpu_busy_pct"),
                "pp_cpu_cores": pp_stats.get("cpu_cores"),
                "pp_gpu_util_pct": pp_stats.get("gpu_util_pct"),
                "pp_gpu_power_w": pp_stats.get("gpu_power_w"),
                "pp_cpu_core_s_per_token": (
                    round(pp_stats["cpu_cores"] / timings["prompt_per_second"], 4)
                    if pp_stats.get("cpu_cores") and timings.get("prompt_per_second") else None
                ),
                "pp_gpu_j_per_token": (
                    round(pp_stats["gpu_power_w"] / timings["prompt_per_second"], 3)
                    if pp_stats.get("gpu_power_w") and timings.get("prompt_per_second") else None
                ),
                "tg_cpu_pct": tg_stats.get("cpu_busy_pct"),
                "tg_cpu_cores": tg_stats.get("cpu_cores"),
                "tg_gpu_util_pct": tg_stats.get("gpu_util_pct"),
                "tg_gpu_power_w": tg_stats.get("gpu_power_w"),
                "tg_cpu_core_s_per_token": (
                    round(tg_stats["cpu_cores"] / timings["predicted_per_second"], 4)
                    if tg_stats.get("cpu_cores") and timings.get("predicted_per_second") else None
                ),
                "tg_gpu_j_per_token": (
                    round(tg_stats["gpu_power_w"] / timings["predicted_per_second"], 3)
                    if tg_stats.get("gpu_power_w") and timings.get("predicted_per_second") else None
                ),
            }
            line = json.dumps(row)
            print(line, flush=True)
            if args.out:
                with open(args.out, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
