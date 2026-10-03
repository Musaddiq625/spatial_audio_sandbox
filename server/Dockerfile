# Scene Director model endpoint — llama.cpp serving Gemma, OpenAI-compatible.
# Weights are pulled from HuggingFace at boot (HF_TOKEN env secret on Render).
FROM ghcr.io/ggml-org/llama.cpp:server-v0.4.1

# Distroless image (no shell): ENTRYPOINT is llama-server itself, so we pass
# plain args via CMD. Render routes web traffic to port 10000 by default.
# -hf pulls the Q4_K_M quant of gemma-3-1b-it (~800 MB) from HF at boot.
EXPOSE 10000
CMD ["--host","0.0.0.0","--port","10000","-hf","ggml-org/gemma-3-1b-it-GGUF:Q4_K_M","-c","4096","-t","2"]
