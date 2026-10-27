#!/bin/sh
# **The consultant's entrypoint.** It has no database, no admin token and no Docker socket; the only
# credential it holds is the agent key in its own environment, and the model's credential lives in
# the mounted agent home rather than in an image layer.
set -eu

# **The consultant's agent is part of the image, and the home is a volume.** The denied-tools
# agent is written on first boot because the volume hides an image path at /home/consultant; the
# file is copied, never overwritten, so an operator can pin a different one deliberately.
mkdir -p "$HOME/.config/opencode/agents"
for agent in consultant reviewer presenter; do
  if [ ! -f "$HOME/.config/opencode/agents/$agent.md" ]; then
    cp "/app/agent/$agent.md" "$HOME/.config/opencode/agents/$agent.md"
  fi
done

exec /app/bin/agents-consultant "$@"
