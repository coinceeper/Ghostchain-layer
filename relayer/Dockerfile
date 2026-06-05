# GhostChain Solver/Relayer Service
# Multi-stage Docker build for production deployments
#
# Build: docker build -t ghostchain-solver -f Dockerfile .
# Run:   docker run -p 3000:3000 --env-file .env ghostchain-solver

FROM node:20-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache python3 make g++

# Copy package files
COPY package.json tsconfig.json ./
RUN npm ci

# Copy source
COPY src/ ./src/

# Build TypeScript
RUN npm run build

# Prune dev dependencies
RUN npm prune --production

# ───── Production Image ─────
FROM node:20-alpine AS runner

WORKDIR /app

# Create non-root user for security
RUN addgroup -S ghostchain && adduser -S ghostchain -G ghostchain

# Copy production artifacts from builder
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./

# Install curl for healthcheck
RUN apk add --no-cache curl

# Create tmp directory for runtime usage
RUN mkdir -p /tmp && chown ghostchain:ghostchain /tmp

USER ghostchain

EXPOSE 3000
EXPOSE 9090

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl --fail http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
