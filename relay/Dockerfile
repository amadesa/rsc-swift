# rsc-relay in a container (Docker or Podman).
#
#   docker build -t rsc-relay relay/
#   docker run -d --name rsc-relay --restart unless-stopped \
#       --network host -v rsc-relay:/data rsc-relay
#
# --network host lets the relay list the machine's real addresses in
# /v1/info (and, later, be found with Bonjour). Without it, publish the
# port and say where it's reachable:
#
#   docker run -d -p 8443:8443 -v rsc-relay:/data \
#       -e RSC_RELAY_LOCAL_ADDRESSES=false \
#       -e RSC_RELAY_ADVERTISE=192.168.4.20 rsc-relay
#
# Key, token and paired devices live in /data:
#
#   docker exec rsc-relay rsc-relay info
#   docker exec rsc-relay rsc-relay devices add "Apple Watch"

FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /rsc-relay .
# scratch has no directories; the volume starts from this one, owned by the
# user the relay runs as
RUN mkdir /data && chown 65532:65532 /data

FROM scratch
COPY --from=build /rsc-relay /usr/local/bin/rsc-relay
COPY --from=build --chown=65532:65532 /data /data
ENV RSC_RELAY_DATA=/data \
    RSC_RELAY_LISTEN= \
    RSC_RELAY_TLS_LISTEN=:8443
VOLUME /data
EXPOSE 8443
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/rsc-relay"]
