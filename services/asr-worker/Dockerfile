FROM node:20-bookworm-slim

WORKDIR /app

COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/package.json
COPY packages/shared/tsconfig.json packages/shared/tsconfig.json
COPY packages/shared/src packages/shared/src
COPY services/asr-worker/package.json services/asr-worker/package.json
COPY services/asr-worker/tsconfig.json services/asr-worker/tsconfig.json
COPY services/asr-worker/src services/asr-worker/src

RUN npm ci
RUN npm run build --workspace @voice/shared
RUN npm run build --workspace @voice/asr-worker

CMD ["node", "services/asr-worker/dist/index.js"]
