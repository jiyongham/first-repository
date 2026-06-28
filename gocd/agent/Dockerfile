FROM --platform=linux/amd64 golang:1.22-alpine AS go-src
FROM --platform=linux/amd64 docker:27-cli AS docker-src

FROM --platform=linux/amd64 gocd/gocd-agent-ubuntu-22.04:v24.5.0

# RUN 없이 COPY만 (에뮬레이션 환경에서 RUN 오류 회피)
COPY --from=go-src     /usr/local/go        /usr/local/go
COPY --from=docker-src /usr/local/bin/docker /usr/local/bin/docker

ENV GOPATH=/tmp/gopath
ENV PATH=/usr/local/go/bin:${PATH}
