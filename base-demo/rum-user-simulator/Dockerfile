# syntax=docker/dockerfile:1.7
#
# rum-user-simulator — Node + Playwright + Chromium, driving the NatWest
# Payments SPA to produce per-city RUM sessions on a 30 s cadence.
#
# We base off the Microsoft Playwright image so Chromium (and every OS
# dependency it needs — nss, libatk, libcups, fonts, ffmpeg…) is
# pre-installed at a version pinned to the Playwright client. Sticking
# to the same tag on both sides avoids the "browser was launched with an
# incompatible driver" class of failures at runtime.
FROM mcr.microsoft.com/playwright:v1.51.0-jammy

ENV NODE_ENV=production \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

WORKDIR /app

# Install dependencies as a separate layer so an edit to run.js / lib/*
# doesn't invalidate the (large) node_modules layer.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-progress \
 && npm cache clean --force

# App code. Small — mostly the session driver + city loop + chaos poll.
COPY run.js ./
COPY lib ./lib

# The base image ships a non-root `pwuser` (uid 1000) with the browser
# cache already chown'd to it. Use that so we never write to root-owned
# paths at runtime and Kubernetes' RunAsNonRoot policy is satisfied.
USER pwuser

# `dumb-init` isn't in the base; the base image's ENTRYPOINT is empty
# and node reaps its own children fine, so ENTRYPOINT stays as the plain
# node invocation. Signals from `kubectl scale --replicas=0` still reach
# node correctly.
ENTRYPOINT ["node", "run.js"]
