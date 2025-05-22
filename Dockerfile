# syntax=docker/dockerfile:1
#
ARG IMAGEBASE=frommakefile
#
FROM ${IMAGEBASE}
#
ENV \
    INFLUXDB_HOME=/var/lib/influxdb \
    INFLUXDB_CONFIG_PATH=/etc/influxdb.conf
#
RUN set -xe \
    && apk add -Uu --purge --no-cache \
        ca-certificates \
        # influxdb \
    # influxdb unavailable in repos since v3.17
    # newer builds will not have armv7l/armhf
    && { \
        echo "http://dl-cdn.alpinelinux.org/alpine/v3.17/main"; \
        echo "http://dl-cdn.alpinelinux.org/alpine/v3.17/community"; \
    } > /tmp/repo3.17 \
    && apk add --no-cache \
        --repositories-file "/tmp/repo3.17" \
        influxdb \
    # && update-ca-certificates \
    && mkdir -p \
        /defaults \
        ${INFLUXDB_HOME} \
    && mv ${INFLUXDB_CONFIG_PATH} /defaults/influxdb.conf.default \
    && (if [ ! -e /etc/nsswitch.conf ]; then echo 'hosts: files dns' > /etc/nsswitch.conf; fi) \
    && rm -rf /var/cache/apk/* /tmp/*
#
COPY root/ /
#
ENV \
    S6_USERHOME=${INFLUXDB_HOME}
#
VOLUME  ["${INFLUXDB_HOME}"]
#
EXPOSE 8086 8088 8089 4242 25826
#
HEALTHCHECK \
    --interval=2m \
    --retries=5 \
    --start-period=5m \
    --timeout=10s \
    CMD \
        s6-setuidgid ${S6_USER:-alpine} \
        /scripts/run.sh healthcheck \
    || exit 1
#
ENTRYPOINT ["/init"]
