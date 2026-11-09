FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS build
WORKDIR /app/Site
# Never run the Husky hook in image builds.
ENV CI=true HUSKY=0 ASTRO_TELEMETRY_DISABLED=1 BUN_CONFIG_MAX_HTTP_REQUESTS=16
COPY Site/package.json Site/bun.lock ./
RUN bun install --frozen-lockfile --network-concurrency=16
COPY Site/ ./
RUN bun run build && bun run check:site

FROM caddy:2.11.7@sha256:8dc9fa87b36b25303d1c67d2a09f5824b7f3bfd72cb052f246e5da2133fe29a8
RUN setcap -r /usr/bin/caddy
COPY --from=build /app/Site/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
ARG MOSS_REVISION=development
ENV MOSS_REVISION=${MOSS_REVISION}
LABEL org.opencontainers.image.revision=${MOSS_REVISION}
USER 1000:1000
EXPOSE 8080
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
