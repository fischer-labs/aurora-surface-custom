# syntax=docker/dockerfile:1
# Roost: one image with the server and the web app.
#   docker build -t roost .        (from the roost/ directory)
FROM node:22-alpine AS web
WORKDIR /src
COPY shared ./shared
COPY web/package.json web/package-lock.json web/.npmrc ./web/
RUN cd web && npm ci --no-audit --no-fund
COPY web ./web
RUN cd web && npx vite build

FROM golang:1.27-alpine AS server
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/roost-server .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -H -u 10001 roost \
 && mkdir -p /app/pb_data && chown roost /app/pb_data
WORKDIR /app
COPY --from=server /out/roost-server /app/roost-server
COPY --from=web /src/web/dist /app/web
ENV ROOST_WEB_DIR=/app/web
VOLUME /app/pb_data
EXPOSE 8090
USER roost
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:8090/api/health >/dev/null || exit 1
ENTRYPOINT ["/app/roost-server"]
CMD ["serve", "--http=0.0.0.0:8090", "--dir=/app/pb_data"]
