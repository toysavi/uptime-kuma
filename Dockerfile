# Use Node 18 Alpine
FROM node:18-alpine

# Set working directory
WORKDIR /app

# Copy package files from subfolder
COPY ./uptime-kuma/package*.json ./

# Install dependencies
# Use npm install instead of npm ci to avoid lockfile issues in CI
RUN npm install --omit=dev --legacy-peer-deps

# Copy all source code from subfolder
COPY ./uptime-kuma/ ./

# Build frontend (if needed)
RUN npm run build

# Expose port
EXPOSE 3001

# Start server
CMD ["node", "server/server.js"]