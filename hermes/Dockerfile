# Hermes Agent — custom image (NousResearch/hermes-agent hat kein offizielles Docker Image)
# Source: https://github.com/NousResearch/hermes-agent
FROM python:3.11-slim

RUN apt-get update -qq && apt-get install -y -qq \
    git build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Shallow clone + Submodul mini-swe-agent (required terminal backend)
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent . && \
    git submodule update --init mini-swe-agent

# mini-swe-agent als lokales Package installieren (nicht in pyproject dependencies)
RUN pip install --no-cache-dir -e "mini-swe-agent"

# Hermes installieren: messaging (Telegram), cron, cli, pty, mcp
# Kein voice-Extra — kein lokaler Whisper auf CX22 (kein GPU, wenig RAM)
RUN pip install --no-cache-dir -e ".[messaging,cron,cli,pty,mcp]"

VOLUME ["/root/.hermes"]

# Port fuer Telegram Webhook-Modus
EXPOSE 8443

CMD ["hermes", "gateway", "start"]
