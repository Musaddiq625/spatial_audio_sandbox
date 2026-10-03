# Scene Director model endpoint — llama.cpp serving Gemma, OpenAI-compatible.
# Weights are baked in at build time (ggml-org mirror isn't gated): no runtime
# download, no token, no dependence on a writable home/cache dir.
FROM ghcr.io/ggml-org/llama.cpp:server-v0.4.1

RUN mkdir -p /models && \
    curl -fL -o /models/gemma.gguf \
      "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf" && \
    chmod -R a+r /models

# ENTRYPOINT is /app/llama-server — plain args via CMD.
# Render routes web traffic to port 10000 by default.
EXPOSE 10000
CMD ["-m","/models/gemma.gguf","--host","0.0.0.0","--port","10000","-c","4096","-t","2"]
