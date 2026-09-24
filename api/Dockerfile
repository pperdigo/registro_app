FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
# CA da AWS para TLS verificado com o RDS; legível pelo usuário node
RUN mkdir -p /app/certs \
  && wget -qO /app/certs/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  && chmod 755 /app/certs && chmod 644 /app/certs/rds-global-bundle.pem
COPY src ./src
COPY migrations ./migrations
USER node
ENV NODE_ENV=production
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1
CMD ["node", "src/index.js"]
