#!/usr/bin/with-contenv bash
# reference: https://github.com/influxdata/influxdata-docker/blob/d18cf6292f3d5de77d9bd7b25f897288fafda290/influxdb/1.8/alpine/init-influxdb.sh

if [ -n "${DEBUG}" ]; then set -ex; fi;
vecho () { if [ "${S6_VERBOSITY:-1}" -gt 0 ]; then echo "[$0] $@"; fi; }

INFLUXDB_HOME="${INFLUXDB_HOME:-/var/lib/influxdb}";
INFLUXDB_BACKUPDIR="${INFLUXDB_BACKUPDIR:-$INFLUXDB_HOME/backups}";
INFLUXDB_INITDIR="${INFLUXDB_INITDIR:-$INFLUXDB_HOME/initdb.d}";

if [ "X${EUID}" = "X0" ]; then vecho "must be run as a non-root user."; exit 1; fi;

CMD="$1"; # required to select task to run

# usage: process_init_file FILENAME INFLUX_ARGS...
#    ie: process_init_file foo.sh influx
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
    local f="$1"; shift;
    # default args for influx
    local INFLUX_ARGS=(-host 127.0.0.1 ${INFLUXDB_ADMIN_USER:+ -username $INFLUXDB_ADMIN_USER} ${INFLUXDB_ADMIN_PWD:+ -password $INFLUXDB_ADMIN_PWD});
    if [[ $# -gt 0 ]]; then INFLUX_ARGS="$@"; fi; # if args passed via cmdline, use those instead

    _influx () { influx ${INFLUX_ARGS} -execute "$@"; }

    case "$f" in
        *.sh|*.bash)
            if [ -x "$f" ];
            then
                vecho "Running $f";
                "$f";
            else
                vecho "Sourcing $f";
                . "$f";
            fi
        ;;
        *.iql) vecho "Loading $f"; _influx "$(sed -e '/^\-\-/d' -e 's/\s*\-\-.*$//g' ""$f"")"; echo ;;
        *)     vecho "Ignoring $f" ;;
    esac
    echo;
}

if [ "${CMD^^}" == 'INITDB' ];
then # process initial db state and/or configurations from /var/lib/influxdb/initdb.d/
    if [ -n "${INFLUXDB_INITDIR}" ] && [ -d "${INFLUXDB_INITDIR}" ];
    then
        vecho "Checking for initializer files in ${INFLUXDB_INITDIR}...";
        for f in $(find "${INFLUXDB_INITDIR}" -maxdepth 1 -type f 2>/dev/null | sort -u);
        do
            process_init_file "$f" ${@:2};
        done;
        vecho "Done.";
    fi;

elif [ "${CMD^^}" == 'BACKUP' ]; # backup single db
then
    DB="$2"; # required db name
    OPTS="${@:3}";
    if [ -z "${OPTS}" ]; then OPTS="-portable"; fi;
    mkdir -p ${INFLUXDB_BACKUPDIR};
    influxd backup \
        -database ${DB} \
        ${OPTS[@]} \
        ${INFLUXDB_BACKUPDIR}/${DB};
    # && tar -cvz \
    #     -f ${INFLUXDB_BACKUPDIR}/${DB}.tar.gz \
    #     -C ${INFLUXDB_BACKUPDIR} \
    #     ./${DB} \
    # && rm -rf ${INFLUXDB_BACKUPDIR}/${DB}/;

elif [ "${CMD^^}" == 'RESTORE' ]; # restore single db
then
    DB="$2"; # required db name
    OPTS="${@:3}";
    if [ -z "${OPTS}" ]; then OPTS="-portable"; fi;
    # tar -xvz \
    #     -f ${INFLUXDB_BACKUPDIR}/${DB}.tar.gz \
    #     -C ${INFLUXDB_BACKUPDIR} \
    # && \
    influxd restore \
        -database ${DB} \
        ${OPTS[@]} \
        ${INFLUXDB_BACKUPDIR}/${DB}; # backup must already exist
    # && rm -rf ${INFLUXDB_BACKUPDIR}/${DB}/;

elif [ "${CMD^^}" == 'HEALTHCHECK' ]; # used in Dockerfile
then
    if [ -n "${INFLUXDB_HEALTHCHECK_USER:-$INFLUXDB_USER}" ] && [ -n "${INFLUXDB_HEALTHCHECK_USER_PWD:-$INFLUXDB_USER_PWD}" ];
    then
        influx \
            ${INFLUXDB_HOST:+ -host=$INFLUXDB_HOST} \
            -username=${INFLUXDB_HEALTHCHECK_USER:-$INFLUXDB_USER} \
            -password=${INFLUXDB_HEALTHCHECK_USER_PWD:-$INFLUXDB_USER_PWD} \
            -execute="${INFLUXDB_HEALTHCHECK_QUERY:-SHOW DATABASES};";
    else
        influx \
            ${INFLUXDB_HOST:+ -host=$INFLUXDB_HOST} \
            -execute="${INFLUXDB_HEALTHCHECK_QUERY:-SHOW DATABASES};";
    fi;

elif [ "${CMD^^}" == 'TEMP-SERVER-START' ]; # runs as non-root user by default
then
    if [ -f /tmp/influxd-temp.pid ] \
    && [ -n $(cat /tmp/influxd-temp.pid) ];
    then
        vecho "InfluxDB temporary server already running.";
        exit 0;
    else
        vecho "InfluxDB temporary server starting.";
        INFLUXDB_HTTP_BIND_ADDRESS=127.0.0.1:${INFLUXDB_INIT_PORT:-8086} \
        INFLUXDB_HTTP_HTTPS_ENABLED=false \
        influxd \
        ${INFLUXDB_ARGS[@]} \
        ${@:2} \
        &
        echo $! > /tmp/influxd-temp.pid;
    fi;

elif [ "${CMD^^}" == 'WAIT-SERVER-READY' ]; # runs as non-root user by default
then # block until database ready
    if [ "${@:2}" ] && [ -n "${@:2:1}" ];
    then EXEC_QUERY=${@:2:1}; # pass custom query or initializer statement for first run
    else EXEC_QUERY="SHOW DATABASES;";
    fi;
    vecho "Waiting for connection...";
    ret=${INFLUX_WAIT_RETRIES:-6}; # wait for upto 5x6=30 seconds
    until \
        influx \
            -host 127.0.0.1 \
            -port ${INFLUXDB_INIT_PORT:-8086} \
            -execute "${EXEC_QUERY}" \
            ${@:3} \
            &> /dev/null;
    do
        if [[ ret -eq 0 ]];
        then
            vecho "Could not connect to database. Exiting.";
            exit 1;
        fi;
        sleep 5;
        ((ret--));
    done;
    vecho "Found database connection.";

elif [ "${CMD^^}" == 'TEMP-SERVER-STOP' ]; # runs as non-root user by default
then
    INFLUXDB_PID="$(cat /tmp/influxd-temp.pid)";
    if [ ! -f /tmp/influxd-temp.pid ] \
    || [ -z "${INFLUXDB_PID}" ];
    then
        vecho "InfluxDB temporary server not running.";
        exit 0;
    else
        kill ${INFLUXDB_PID};
        wait ${INFLUXDB_PID} 2>/dev/null || true; # so we don't error when (usually) pid is not a child
        rm -f /tmp/influxd-temp.pid;
        vecho "InfluxDB temporary server stopped.";
    fi;
else
    echo "Usage: $0 <cmd> <additional args>";
    echo "cmd:";
    echo "  initdb <additional args>";
    echo "    load initializer files from ${INFLUXDB_INITDIR}";
    echo "  backup <dbname>";
    echo "    backup single db to ${INFLUXDB_BACKUPDIR}/<dbname>/";
    echo "  restore <dbname>";
    echo "    restore single db from ${INFLUXDB_BACKUPDIR}/<dbname>/";
    echo "  healthcheck";
    echo "    run healthcheck-query as \$INFLUXDB_HEALTHCHECK_USER";
    echo "    fallback to \$INFLUXDB_USER if defined";
    echo "    or fallback to socket user.";
    echo "  temp-server-start <additional args>";
    echo "    start a temporary-server listening to localhost";
    echo "  wait-server-ready '<query>'";
    echo "    wait (with \$INFLUX_WAIT_RETRIES retries) until";
    echo "    temporary-server becomes accessible.";
    echo "    optionally run custom query if supplied";
    echo "  temp-server-stop";
    echo "    stop temporary-server";
fi;
