# rtx_5060_ti profile

Setup for a 16 GB RTX 5060 Ti. `hardware.conf` matches GPUs named `RTX 5060 Ti` with at least 15000 MiB of VRAM.

## Defaults

- Strata `qwen / IQ3_S`, text only (vision off)
- 256K context (`LLM_CONTEXT=256k`)
- `k8v4` KV cache, single parallel slot
- `LLM_RESIDENT_BUDGET_GIB=41`
- `LLM_POOL_WORKERS=4` (measured power/speed knee; `auto` or `0` restores the engine default)

These are the settings the installer uses; override them with the `LLM_*` environment variables. The same Strata menu also offers DeepSeek-V4.1-Flash 1017 (`LLM_MODEL=IST-DAS-1.75bpw`, `IST-DAS-2.00bpw` or `IST-DAS-2.25bpw`), which uses its own engine, ignores `LLM_RESIDENT_BUDGET_GIB`, and takes `LLM_SPEED=auto|faster|full` (the default `auto` is 5 experts per word on this 16 GB card).

## Reference measurements

Measured on a test host with an RTX 5060 Ti 16 GB, driver 595, 52 GB RAM and 200 GB disk, with the model loaded and OpenWebUI running. Prompt processing and generation use 256 generated tokens for the long-context rows.

| Prompt | Prompt processing | Generation |
| ---: | ---: | ---: |
| ~1K tokens | 275–375 tok/s | 30–60 tok/s |
| ~8K tokens | 1230 tok/s | 53 tok/s |
| ~28K tokens | 1220 tok/s | 41 tok/s |
| ~212K tokens | 1231 tok/s | 41.5 tok/s |

The server reports `max_context: 262144` with these defaults. The first request after a start can sit near the low end while the coldest experts are read from the SSD; later requests warm up to the higher figure.

### Qwen CPU expert pool

The Qwen engine starts one CPU expert worker per logical processor (15 workers plus the host thread here). `LLM_POOL_WORKERS=N` caps the pool. Prompt processing is GPU-bound; token generation is the CPU-bound part. Measured with two 32K-token prompts, 256 generated tokens, OpenWebUI stopped, 256K context:

| Pool workers | PP tok/s | TG tok/s | TG CPU cores | TG GPU power |
| ---: | ---: | ---: | ---: | ---: |
| default (15) | 1135 | 46.0 | 12.7 | 53.0 W |
| 12 | 1135 | 54.0 | 11.0 | 57.6 W |
| 10 | 1134 | 50.0 | 9.6 | 59.3 W |
| **8** | **1134** | **59.8** | **7.3** | **59.6 W** |
| 6 | 1133 | 54.2 | 6.2 | 56.2 W |
| 4 | 1136 | 50.3 | 4.8 | 54.6 W |
| 2 | 1137 | 44.5 | 2.8 | 55.6 W |

PP stayed at roughly 1,130–1,140 tok/s and 1.1–1.6 CPU cores in every row: it is GPU-bound. Eight workers gave the highest TG at 32K; four is the power-saving knee, still beating the default at 32K (50.3 vs 46.0 tok/s) while using about half the CPU. Two loses too much generation speed.

Long-context validation (one warm 128K and one 241K prompt, 256 generated tokens):

| Workers | Prompt | Prompt tokens | PP tok/s | TG tok/s | TG CPU cores |
| ---: | ---: | ---: | ---: | ---: | ---: |
| default (15) | 128K | 129,062 | 1100.8 | 52.5 | 8.26 |
| 8 | 128K | 129,062 | 1101.4 | 54.9 | 8.21 |
| 6 | 128K | 129,062 | 1099.3 | 52.3 | 6.26 |
| **4** | **128K** | **129,062** | **1100.8** | **52.0** | **4.69** |
| default (15) | 241K | 241,184 | 1044.9 | 57.4 | 8.67 |
| 8 | 241K | 241,184 | 1045.2 | 57.8 | 7.23 |
| 6 | 241K | 241,184 | 1042.6 | 58.0 | 6.08 |
| **4** | **241K** | **241,184** | **1047.9** | **57.2** | **4.71** |

At long context PP is identical across worker counts. Four workers matches the default's TG (52.0 vs 52.5 at 128K, 57.2 vs 57.4 at 241K) while using 4.7 CPU cores instead of 8.3–8.7, and it still beats the default at 32K. That is the profile default. Eight workers is the fastest choice for short and medium prompts (59.8 tok/s at 32K); six is the middle. `LLM_POOL_WORKERS=auto` or `0` restores the engine's one-worker-per-logical-CPU default.

### DeepSeek V4.1-Flash

Measured on the same host with `LLM_MODEL=IST-DAS-2.00bpw`, OpenWebUI stopped, vision off, and the engine's default `Faster` mode (5 of 6 experts per word). The DeepSeek engine uses its own `fp4` KV cache; `LLM_KV` does not change it. DSpark reported `off` for these runs.

| Context | Prompt tokens | Prompt processing | Generation |
| ---: | ---: | ---: | ---: |
| 128K | 127,639 | 653.7 tok/s (195.3 s) | 7.5 tok/s (293 tokens) |
| 256K | 257,266 | 655.2 tok/s (392.6 s) | 7.4 tok/s (293 tokens) |

Prompt processing is roughly flat from 128K to 256K on this host. Generation is limited by the CPU/SSD expert path, as expected for a 16 GB card. At 256K the host used about 38 GB of RAM, left about 14 GB available (18 GB in buff/cache), and kept the GPU at 15.4 of 16.3 GB.

Reloading the already-downloaded model at 256K took **54 seconds** (container start at 23:52:58, serving at 23:53:52). The first install downloads 256.8 GB and stores about 240 GiB (257 GB) in the Strata volume; the 1.75 bpw and 2.25 bpw sets need 239 GB and 274 GB of disk and at least 34 GB and 44 GB of RAM.

## Startup

- Qwen model start at 256K: **58 seconds**
- DeepSeek V4.1-Flash reload at 256K (model already downloaded): **54 seconds**
- Full `./up.sh --with-webui` from stopped: **86 seconds**
- `./up.sh` with no changes: **under a second** (configuration signature match)

## Memory and disk

- Qwen at 256K with OpenWebUI running leaves about **4 GB** of RAM available; avoid other large programs on a 52 GB host.
- DeepSeek V4.1-Flash 2.00 bpw at 256K leaves about **14 GB** of RAM available (38 GB used, 18 GB buff/cache) with OpenWebUI stopped, and uses 15.4 of 16.3 GB of VRAM.
- For more headroom use `LLM_CONTEXT=128k LLM_KV=int8` (Qwen). DeepSeek uses its own `fp4` KV cache, so `LLM_KV` does not apply.
- The prepared Qwen model occupies about **140 GB**. The first install needs roughly that much free space; reinstalls detect the existing model and skip the check.
- DeepSeek 2.00 bpw downloads 256.8 GB and occupies about **240 GiB (257 GB)**. The 1.75 bpw and 2.25 bpw sets need 239 GB and 274 GB of disk, and at least 34 GB and 44 GB of RAM.
- Without the 41 GiB resident cap, Strata page-locks all Qwen experts on every start, which took 10–15 minutes here and could exceed its load timeout. The cap does not apply to DeepSeek.
