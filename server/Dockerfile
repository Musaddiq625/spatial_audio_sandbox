# Scene Director model endpoint — llama.cpp serving Gemma, OpenAI-compatible.
# Weights are pulled from HuggingFace at boot (HF_TOKEN env secret on Render).
FROM ghcr.io/ggml-org/llama.cpp:server

# Render injects $PORT. -hf pulls ggml-org/gemma-3-1b-it-GGUF (Q4_K_M default).
# -c 4096 ctx covers the scene-spec prompt comfortably; -t 2 threads.
ENTRYPOINT ["sh","-c","llama-server --host 0.0.0.0 --port ${PORT:-8080} -hf ggml-org/gemma-3-1b-it-GGUF -c 4096 -t 2"]
