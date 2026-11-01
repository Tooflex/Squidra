FROM alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
RUN apk add --no-cache chromium=149.0.7827.53-r0 && addgroup -g 1000 browser && adduser -D -u 1000 -G browser -h /work browser
COPY --chmod=0555 browser-entrypoint /usr/local/bin/squidra-browser
USER 1000:1000
ENV HOME=/work
WORKDIR /work
ENTRYPOINT ["/usr/bin/chromium-browser"]
