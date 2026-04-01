FROM node:20-bookworm-slim

WORKDIR /app

COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/package.json
COPY packages/shared/tsconfig.json packages/shared/tsconfig.json
COPY packages/shared/src packages/shared/src
COPY services/summary-worker/package.json services/summary-worker/package.json
COPY services/summary-worker/tsconfig.json services/summary-worker/tsconfig.json
COPY services/summary-worker/src services/summary-worker/src

RUN npm ci
RUN npm run build --workspace @voice/shared
RUN npm run build --workspace @voice/summary-worker

CMD ["node", "services/summary-worker/dist/index.js"]
