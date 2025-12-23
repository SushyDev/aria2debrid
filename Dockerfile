# Stage 1: Build Stage
FROM hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.21.5 AS builder

RUN apk add --no-cache \
    git \
    build-base

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
COPY apps/config/mix.exs ./apps/config/
COPY apps/servarr_client/mix.exs ./apps/servarr_client/
COPY apps/media_validator/mix.exs ./apps/media_validator/
COPY apps/processing_queue/mix.exs ./apps/processing_queue/
COPY apps/aria2_api/mix.exs ./apps/aria2_api/

RUN mix deps.get --only prod
RUN mix deps.compile

COPY apps apps

RUN mix compile

RUN mix release

# Stage 2: Runtime Stage
FROM alpine:3.21.5

RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    libstdc++ \
    ffmpeg \
    wget \
    bash

RUN addgroup -g 1000 app && \
    adduser -D -u 1000 -G app app

WORKDIR /app

COPY --from=builder --chown=app:app /app/_build/prod/rel/aria2debrid ./

ENV HOME=/app
ENV MIX_ENV=prod
ENV RELEASE_COOKIE=change_me_in_production

USER app

EXPOSE 6800

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD wget -q --spider http://localhost:6800/health || exit 1

CMD ["/app/bin/aria2debrid", "start"]
