# Dockerfile
FROM node:18-alpine

WORKDIR /app

# Correct paths: COPY <source relative to build context> <dest>
COPY ./uptime-kuma/package*.json ./

# Install dependencies
RUN npm ci --omit=dev --legacy-peer-deps

# Copy all source code
COPY ./uptime-kuma/ ./

# Build frontend
RUN npm run build

EXPOSE 3001
CMD ["node", "server/server.js"]