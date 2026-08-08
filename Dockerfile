FROM node:20-slim

WORKDIR /app/server

# The image is the WebSocket server and nothing else — no asset tree, and so no sharp and no
# pre-build step. `assets/` is packaged into the apps by `tools/assets/stage.sh` instead.
COPY server/package*.json ./
RUN npm ci --omit=dev

COPY server/ ./
# The authored world moved to the repository root when the apps started bundling it; the
# server still reads and watches it. `server/paths.js` resolves it at ../data.
COPY data/ ../data/

# Cloud Run sets PORT; server.js honours it.
EXPOSE 8080

CMD ["npm", "run", "server"]
