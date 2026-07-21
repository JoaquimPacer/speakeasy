# syntax=docker/dockerfile:1

FROM golang:1.22-alpine AS build

WORKDIR /src
COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/speakeasy-server ./cmd/speakeasy-server

FROM alpine:3.20

RUN addgroup -S speakeasy \
	&& adduser -S -G speakeasy speakeasy \
	&& mkdir -p /data/blobs \
	&& chown -R speakeasy:speakeasy /data

COPY --from=build /out/speakeasy-server /usr/local/bin/speakeasy-server

USER speakeasy
EXPOSE 8080

ENV SPEAKEASY_ADDR=:8080 \
	DB_PATH=/data/speakeasy.db \
	STORAGE_PATH=/data/blobs \
	UNDELIVERED_RETENTION_DAYS=7

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
	CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/speakeasy-server"]
