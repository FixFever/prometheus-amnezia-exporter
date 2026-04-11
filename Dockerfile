FROM alpine:latest

RUN apk add --no-cache bash socat docker-cli jq

WORKDIR /app
COPY wireguard-exporter.sh http-server.sh config.sh ./
RUN chmod +x *.sh

CMD ["./http-server.sh", "start"]