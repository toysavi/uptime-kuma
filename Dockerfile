# Dockerfile
FROM node:18-alpine

# Set workdir
WORKDIR /app

# Copy package.json first to install deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy all source code
COPY . .

# Build front-end (optional, Uptime Kuma uses npm run build)
RUN npm run build

# Expose port
EXPOSE 3001

# Start
CMD ["node", "server/server.js"]