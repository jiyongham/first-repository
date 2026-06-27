FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
RUN go build -ldflags="-X main.version=${VERSION}" -o server .

FROM alpine:3.19
COPY --from=builder /app/server /server
EXPOSE 8080
CMD ["/server"]
