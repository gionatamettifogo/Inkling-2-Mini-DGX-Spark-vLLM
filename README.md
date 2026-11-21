# Inkling 2 Mini on DGX Spark

This repository runs `thinkingmachines/Inkling-2-Mini` on a DGX Spark server with vLLM and exposes an authenticated OpenAI-compatible API. The Hugging Face checkpoint is already mixed NVFP4/MXFP8 (about 20 GB); do not quantize or convert it again. The API serves the exact model name `thinkingmachines/Inkling-2-Mini`.

The model supports image and text input, text output, and up to a 1M-token context in general. This DGX Spark configuration uses a 262,144-token context limit. The official [DGX Spark vLLM recipe](https://recipes.vllm.ai/thinkingmachines/Inkling-2-Mini?hardware=dgx_spark_gb10) specifies the model-specific `vllm/vllm-openai:inkling-2-mini` image because Inkling requires vLLM 0.35 or newer. See also the [Hugging Face model card](https://huggingface.co/thinkingmachines/Inkling-2-Mini).

## Requirements

- NVIDIA DGX Spark with its NVIDIA driver and container runtime configured.
- Docker Engine with the Docker Compose v2 plugin and GPU support (`docker compose version`, `docker info`).
- Network access to Hugging Face Hub and the vLLM container registry on first start.
- Free storage for the vLLM image and the roughly 20 GB checkpoint in the shared Hugging Face cache.
- Port 8896 available on the DGX Spark server. `start.sh` refuses to start if another process is listening there.

The Compose service uses host networking, all GPUs, shared IPC, and privileged mode as required by the model-specific upstream container recipe.

## Install

Clone this repository onto the DGX Spark server. The example uses `~/github`; another checkout directory is fine if you run the commands from that directory.

```bash
mkdir -p ~/github
cd ~/github
git clone https://github.com/gionatamettifogo/Inkling-2-Mini-DGX-Spark-vLLM.git
cd Inkling-2-Mini-DGX-Spark-vLLM
```

Create the ignored, mode-600 `.env` once. Reuse `LLM_API_KEY` from an existing model project's `.env`; copy only this key, not that project's entire environment file. In the example below, replace the source path with the path to an existing model project on this server. The key is written to `.env` without printing it:

```bash
set -a
. "$HOME/github/<existing-model-project>/.env"
set +a
umask 077
{
  printf 'LLM_API_KEY=%s\n' "$LLM_API_KEY"
  cat <<ENV
MODEL_ID=thinkingmachines/Inkling-2-Mini
PORT=8896
VLLM_IMAGE=vllm/vllm-openai:inkling-2-mini
HF_CACHE_DIRECTORY=$HOME/.cache/huggingface
VLLM_ENGINE_READY_TIMEOUT_S=1800
MAX_MODEL_LEN=262144
GPU_MEMORY_UTILIZATION=0.60
KV_CACHE_MEMORY=42949672960
ENV
} > .env
chmod 600 .env
unset LLM_API_KEY
```

If `.env` already exists, preserve it and confirm its settings instead of overwriting it. `HF_CACHE_DIRECTORY` should point to the existing shared Hugging Face cache when one is configured; otherwise the Compose default is `$HOME/.cache/huggingface`. Inkling weights are downloaded once to this cache.

## Start and verify

Start from the repository directory:

```bash
./start.sh
```

On first start Docker pulls the model-specific vLLM image and vLLM downloads the checkpoint. Allow several minutes for model loading, CUDA warmup, and graph capture. Follow progress with:

```bash
docker compose --env-file .env -f compose.yaml logs -f
```

Check container health and the served model catalog:

```bash
docker inspect inkling2-mini-inkling2-mini-1 \
  --format 'health={{.State.Health.Status}} restarts={{.RestartCount}}'

set -a; . ./.env; set +a
curl -fsS http://127.0.0.1:8896/v1/models \
  -H "Authorization: Bearer $LLM_API_KEY"
```

The catalog should contain `thinkingmachines/Inkling-2-Mini` with a 262,144-token maximum context. Then make a real authenticated completion:

```bash
curl -fsS http://127.0.0.1:8896/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"thinkingmachines/Inkling-2-Mini","messages":[{"role":"user","content":"Explain how a rainbow forms in two sentences."}],"max_tokens":128}'
```

From another Tailscale host, use `http://<dgx-spark-tailscale-ip>:8896/v1` as the API base URL with the same bearer key. The API requires authentication. For image input, send a user message containing a text item and an `image_url` item in the OpenAI chat-completions format.

Stop the service while retaining downloaded weights and caches:

```bash
./stop.sh
```

## Memory settings

Other vLLM services may share the DGX Spark's unified memory. This configuration sets GPU utilization to 0.60 and explicitly reserves 40 GiB for the KV cache (`KV_CACHE_MEMORY=42949672960`). The explicit KV-cache byte setting is the effective cache limit in this vLLM build; `GPU_MEMORY_UTILIZATION` alone is not a substitute. These values were validated on a shared DGX Spark installation and are starting values, not universal requirements. The current cache cap allows roughly 3.4 simultaneous maximum-context sessions according to the engine's startup report. Optional DSpark speculative decoding is disabled to reduce startup and runtime memory use.

If startup logs or `journalctl -k` show NVIDIA allocation failures (`NV_ERR_NO_MEMORY`), inspect current free GPU memory and co-located services first, then lower `KV_CACHE_MEMORY` to leave room for weights, CUDA graphs, and runtime allocations. Do not set the cache from total physical memory alone because other services may share it.

Useful diagnostics:

```bash
docker ps --filter name=inkling2-mini
docker compose --env-file .env -f compose.yaml logs --tail 100
journalctl -k --since '10 minutes ago' --no-pager | grep -Ei 'NV_ERR_NO_MEMORY|out of memory'
```

## Basic benchmark

Run benchmarks when the server is otherwise idle. Record the date, image tag, prompt set, requested output length, concurrency, and results. This small SPEED-Bench run measures time to first token (TTFT), request latency, and output throughput through the chat endpoint:

```bash
set -a; . ./.env; set +a
docker exec inkling2-mini-inkling2-mini-1 vllm bench serve \
  --backend openai-chat \
  --endpoint /v1/chat/completions \
  --host 127.0.0.1 \
  --port 8896 \
  --model thinkingmachines/Inkling-2-Mini \
  --dataset-name speed_bench \
  --speed-bench-dataset-subset throughput_1k \
  --speed-bench-output-len 256 \
  --max-concurrency 1 \
  --num-prompts 8 \
  --header "Authorization=Bearer $LLM_API_KEY"
```

Repeat with `--max-concurrency 4` for a small concurrent-load comparison. Report TTFT, end-to-end latency, and output tokens per second. Keep the prompt and output lengths fixed between runs. The benchmark dataset may need to download on the first run.

## Configuration summary

| Setting | Value |
| --- | --- |
| Model and served ID | `thinkingmachines/Inkling-2-Mini` |
| Container | `vllm/vllm-openai:inkling-2-mini` |
| Checkpoint precision | Mixed NVFP4/MXFP8, supplied by Hugging Face |
| Host port | `8896` |
| Maximum context | `262144` tokens |
| GPU utilization target | `0.60` |
| KV-cache memory cap | `40 GiB` |
| Hugging Face cache | `$HOME/.cache/huggingface` by default |
| API key variable | `LLM_API_KEY` |
