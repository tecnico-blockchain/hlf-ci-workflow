# FROM node:14-alpine3.14 AS build
# WORKDIR /app
# COPY package.json /app
# RUN npm install
# CMD npm run build

# COPY  . /app
# CMD [ "npm","run","prod" ]

FROM node:alpine AS build
WORKDIR /app

COPY package*.json .
COPY tsconfig*.json .
RUN npm install

COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist/frontend /usr/share/nginx/html
