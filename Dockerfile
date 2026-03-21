FROM node:20-slim

WORKDIR /app

# Copy package configurations for server
COPY server/package*.json ./server/
WORKDIR /app/server
RUN npm ci --only=production

# Copy the rest of the application (both client and server)
WORKDIR /app
COPY . .

# Pre-generate map chunks and overlays during the Docker build
WORKDIR /app/server
RUN npm run build

# Expose the port Cloud Run uses
EXPOSE 8080

# Start the application
CMD ["npm", "run", "server"]
