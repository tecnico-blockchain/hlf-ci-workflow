FROM node:alpine AS build
WORKDIR /app

COPY package*.json .
COPY tsconfig.json .
COPY eslint.config.mjs .
RUN npm install

COPY . .
RUN npm run build

FROM node:alpine
WORKDIR /app

COPY package*.json .
RUN npm ci --only=production

COPY --from=build /app/dist ./dist

CMD ["node", "dist/app.js"]
