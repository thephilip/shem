# ── Builder ────────────────────────────────────────────────────────────────────
FROM docker.io/elixir:1.19-slim AS builder

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git python3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# priv/ must be copied before deps.get so the waf patch alias
# (which copies priv/waf into ex_termbox) can fire after deps download.
COPY mix.exs mix.lock ./
COPY priv/ ./priv/

RUN MIX_ENV=prod mix deps.get --only prod

# config/ before deps.compile — compile-time config is read during compilation
COPY config/ ./config/

RUN MIX_ENV=prod mix deps.compile

COPY lib/ ./lib/

RUN MIX_ENV=prod mix release

# ── Runtime ────────────────────────────────────────────────────────────────────
FROM docker.io/debian:trixie-slim AS runtime

WORKDIR /app

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends libncurses6 libssl3 libstdc++6 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build/prod/rel/shem ./

# Always headless in a container; data goes in /data/shem (mount a volume here)
ENV SHEM_NO_TUI=1
ENV SHEM_DATA_DIR=/data/shem

VOLUME ["/data/shem"]

ENTRYPOINT ["/app/bin/shem", "start"]
