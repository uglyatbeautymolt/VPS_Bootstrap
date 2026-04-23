# Hermes Agent — custom image (NousResearch/hermes-agent hat kein offizielles Docker Image)
# Source: https://github.com/NousResearch/hermes-agent
FROM python:3.11-slim

RUN apt-get update -qq && apt-get install -y -qq \
    git build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Shallow clone ohne Submoduln — mini-swe-agent wird separat via pip installiert
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent .

# mini-swe-agent direkt am gepinnten Commit installieren (identisch zum Submodul-Pointer).
# Umgeht shallow-submodule Probleme mit historischen Commits.
RUN pip install --no-cache-dir \
    "git+https://github.com/SWE-agent/mini-swe-agent.git@07aa6a738556e44b30d7b5c3bbd5063dac871d25"

# Hermes installieren: messaging (Telegram), cron, cli, pty, mcp
# Kein voice-Extra — kein lokaler Whisper auf CX22 (kein GPU, wenig RAM)
RUN pip install --no-cache-dir -e ".[messaging,cron,cli,pty,mcp]"

VOLUME ["/root/.hermes"]

# Port fuer Telegram Webhook-Modus
EXPOSE 8443

CMD ["hermes", "gateway", "start"]
