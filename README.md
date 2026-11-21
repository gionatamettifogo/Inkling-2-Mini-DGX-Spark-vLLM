# Inkling 2 Mini on DGX Spark

Runs `thinkingmachines/Inkling-2-Mini` using the official vLLM recipe for DGX Spark. The Hugging Face checkpoint is already mixed NVFP4/MXFP8 (about 20 GB); no extra quantization step is needed. The server uses a 262,144-token context limit and the Inkling reasoning parser. GPU memory utilization is capped at 0.60 and KV cache at 40 GiB to leave room for the other vLLM services sharing Sparky. Optional DSpark speculative decoding is disabled in this initial deployment.

## Setup and service control

This repo is installed at `/home/developer/github/Inkling-2-Mini-DGX-Spark-vLLM` on Sparky. `.env` is ignored by Git and contains the same `LLM_API_KEY` as the other Sparky model projects; keep it mode 600.

```bash
cd /home/developer/github/Inkling-2-Mini-DGX-Spark-vLLM
./start.sh
./stop.sh
```

The first start pulls the vLLM image and downloads the checkpoint into `/home/developer/.cache/huggingface`. Startup can take several minutes. Follow progress with:

```bash
docker compose --env-file .env -f compose.yaml logs -f
```

The service listens on port **8896** on Sparky. The API key is required for every request.

## OpenAI-compatible API

```bash
cd /home/developer/github/Inkling-2-Mini-DGX-Spark-vLLM
set -a; source .env; set +a
curl -sS http://127.0.0.1:8896/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"thinkingmachines/Inkling-2-Mini","messages":[{"role":"user","content":"Explain how a rainbow forms in two sentences."}],"max_tokens":128}'
```

For image input, send a user message with text and an `image_url` content item following the OpenAI chat-completions format. Use the exact model name `thinkingmachines/Inkling-2-Mini`.

## Basic benchmark

Run benchmarks while the server is otherwise idle. Record the date, image tag, prompt, requested output length, concurrency, and results so later comparisons use the same conditions. The vLLM benchmark CLI can measure time to first token (TTFT), request latency, and output throughput against the chat endpoint:

```bash
cd /home/developer/github/Inkling-2-Mini-DGX-Spark-vLLM
set -a; source .env; set +a
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

Repeat with `--max-concurrency 4` to compare a small amount of load. Report TTFT, end-to-end latency, and output tokens per second;  `nvidia-smi` can be used alongside the run to observe device utilization and memory if exposed by the Spark driver.
