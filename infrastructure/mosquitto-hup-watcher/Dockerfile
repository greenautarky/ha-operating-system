FROM alpine:3.20

RUN apk add --no-cache inotify-tools docker-cli bash

COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh

# Runtime config — operator overrides via docker-compose environment.
ENV WATCH_DIR=/mosquitto/config \
    TARGET_CONTAINER=mosquitto \
    DEBOUNCE_SECS=2

ENTRYPOINT ["/usr/local/bin/watch.sh"]
