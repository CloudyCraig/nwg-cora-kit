# syntax=docker/dockerfile:1.7

# -----------------------------------------------------------------------------
# Stage 1: build the Vite + React SPA. Pinned digests on the upstream
# images would be ideal here; for the demo we pin tags to the latest
# Alpine-based LTS line and rely on `--platform=$BUILDPLATFORM` so the
# arm64 darwin laptop can cross-build for amd64 EKS nodes.
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM node:20-alpine AS build

WORKDIR /app

# Copy manifests first so a clean dependency layer is cached even when
# only source files change.
COPY package.json package-lock.json* ./
# Lockfile is optional in the repo; install with npm ci when present,
# otherwise fall back to npm install. The CI image will populate the
# lockfile on first build.
RUN if [ -f package-lock.json ]; then \
      npm ci --no-audit --no-fund; \
    else \
      npm install --no-audit --no-fund; \
    fi

COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
# `public/` holds static assets that Vite copies verbatim into dist/
# (favicons, brand images, robots.txt, etc.). Multi-stage builds compute
# `dist` inside the container, so the local dist/ on the host is
# irrelevant - what matters is that public/ reaches /app here. Without
# this COPY, anything the SPA references via absolute paths like
# /natwest-logo.png will 404 inside the container and the SPA fallback
# will hand back index.html instead.
COPY public ./public

ENV NODE_ENV=production
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2: minimal nginx runtime. envsubst comes from the gettext
# package; we drop privileges to nginx (uid 101) and disable the daemon
# fork so Kubernetes can supervise the process directly.
# -----------------------------------------------------------------------------
FROM nginx:1.27-alpine AS runtime

RUN apk add --no-cache gettext tini && \
    rm -rf /etc/nginx/conf.d/default.conf

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx/default.conf.template /etc/web-frontend/default.conf.template
COPY nginx/config.js.template    /etc/web-frontend/config.js.template
COPY nginx/docker-entrypoint.sh  /usr/local/bin/docker-entrypoint.sh
# JSON access-log format for the OTel filelog -> Splunk Enterprise
# pipeline. Lives in /etc/web-frontend/ (read-only baked into the image)
# so the entrypoint can install it into the writable conf.d emptyDir
# alongside the rendered default.conf at startup. The log_format
# directive must load (in http {} context) BEFORE default.conf
# references it, hence the 00- prefix on the rendered filename.
COPY nginx/log_format.conf       /etc/web-frontend/log_format.conf

# nginx:alpine ships with worker user `nginx` (uid 101). Make sure the
# entrypoint can render templates into /usr/share/nginx/html and write
# /etc/nginx/conf.d/default.conf as that user.
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh && \
    chown -R nginx:nginx /usr/share/nginx/html /etc/nginx /var/cache/nginx /var/log/nginx /etc/web-frontend && \
    # PID file location used when running as non-root.
    mkdir -p /var/run/nginx && chown nginx:nginx /var/run/nginx && \
    # Listen on 8080 so the container can run unprivileged (no NET_BIND
    # capability needed). Replace the default 80 listener if any
    # references survived.
    sed -i 's/listen\s*80;/listen 8080;/g' /etc/nginx/nginx.conf || true

USER nginx
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
