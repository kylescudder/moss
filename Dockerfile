FROM oven/bun:1.4.3@sha256:ec06c3b6cea04192ae6770c434f668ca41d343ad19fa6472216c7b48be39c598 AS build
WORKDIR /app/Site
ENV CI=true BUN_CONFIG_MAX_HTTP_REQUESTS=16
COPY Site/package.json Site/bun.lock ./
RUN bun install --frozen-lockfile --network-concurrency=16
COPY Site/ ./
COPY deploy/check-site.mjs /app/deploy/check-site.mjs
RUN bun run build && bun run check:site

FROM caddy:2.11.7@sha256:36c24ad91a7ff7bc4c87fe22bfa8df3c4b18da0773d73fc12ee2c52b98c0bb7e
RUN setcap -r /usr/bin/caddy
COPY --from=build /app/Site/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
ARG MOSS_REVISION=development
ENV MOSS_REVISION=${MOSS_REVISION}
LABEL org.opencontainers.image.revision=${MOSS_REVISION}
USER 1000:1000
EXPOSE 8080
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
