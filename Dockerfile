FROM node:16-alpine

WORKDIR /app

COPY package.json package-lock.json .
RUN npm install

COPY index.js .

ENV CHAINCODE_ID name:somehash
ENV CHAINCODE_SERVER_ADDRESS 0.0.0.0:7052

CMD ["npm", "run", "server", "--chaincode-address", "$CHAINCODE_SERVER_ADDRESS", "--chaincode-id", "$CHAINCODE_ID"]

