# Scene Director model endpoint — llama.cpp serving Gemma, OpenAI-compatible.
# Weights are pulled from HuggingFace at boot (HF_TOKEN env secret on Render).
FROM ghcr.io/ggml-org/llama.cpp:server-v0.4.1

# Render injects $PORT. -hf pulls the Q4_K_M quant of gemma-3-1b-it (~800 MB).
# -c 4096 ctx covers the scene-spec prompt comfortably; -t 2 threads.
ENTRYPOINT ["sh","-c","llama-server --host 0.0.0.0 --port ${PORT:-8080} -hf ggml-org/gemma-3-1b-it-GGUF:Q4_K_M -c 4096 -t 2"]
