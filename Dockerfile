# **The consultant, as a client with a model credential and nothing else.**
#
# The image deliberately has no database driver, no Docker CLI, no Rails and no gems beyond the
# standard library. The service it talks to is another container; the only secret it holds is the
# agent key compose gives it, and the model provider's credential is mounted in its home rather than
# baked into a layer.
FROM ruby:4.0.0-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git nodejs npm \
  && rm -rf /var/lib/apt/lists/*

# `opencode` is the model process. It is installed only when the image is built with the agent; a
# build without it is still a valid client that refuses a task with a sentence rather than running
# a missing binary.
ARG WITH_AGENT=1
RUN if [ "$WITH_AGENT" = "1" ]; then npm install -g opencode-ai; fi

RUN useradd --create-home --uid 10001 consultant
WORKDIR /app
COPY . /app
RUN chmod 0755 /app/entrypoint.sh /app/bin/agents-consultant \
  && mkdir -p /home/consultant/state /home/consultant/records /home/consultant/scratch \
  && chown -R consultant:consultant /home/consultant /app

USER consultant
ENV CONSULTANT_HOME=/home/consultant \
    HOME=/home/consultant

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["--cycles", "1"]
