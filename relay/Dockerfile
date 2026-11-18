FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8787 \
    DATA_PATH=/data/devices.json
COPY package.json relay.mjs ./
COPY lib ./lib
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8787
CMD ["node", "relay.mjs"]
