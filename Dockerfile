FROM node:18-alpine

WORKDIR /app

# Upgrade npm to latest stable
RUN npm install -g npm@11.11.0

# Copy package files
COPY package.json package-lock.json ./

# Install dependencies safely
RUN npm ci --omit=dev --legacy-peer-deps

# Copy source code
COPY . .

# Build frontend
RUN npm run build

# Expose port
EXPOSE 3001

# Start server
CMD ["node", "server/server.js"]