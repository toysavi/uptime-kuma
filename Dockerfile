# Dockerfile (in repo root)
FROM node:18-alpine

WORKDIR /app

# Copy package.json and package-lock.json from subfolder
COPY uptime-kuma/package.json uptime-kuma/package-lock.json ./

# Install dependencies
RUN npm ci --omit=dev --legacy-peer-deps

# Copy all source code
COPY uptime-kuma/ ./

# Build frontend
RUN npm run build

# Expose port
EXPOSE 3001

# Start server
CMD ["node", "server/server.js"]