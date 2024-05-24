#!/usr/bin/with-contenv bash

set -e;

CMD="$1";
DB="$2"; # required for backup/restore;

INFLUXDB_HOME="${INFLUXDB_HOME:-/var/lib/influxdb}";
INFLUXDB_INIT_DB=${INFLUXDB_INIT_DB:-$INFLUXDB_HOME/initdb.d}
INFLUXDB_BACKUPDIR="${INFLUXDB_BACKUPDIR:-$INFLUXDB_HOME/backups}";

# from https://github.com/influxdata/influxdata-docker/blob/d18cf6292f3d5de77d9bd7b25f897288fafda290/influxdb/1.8/alpine/init-influxdb.sh
# usage: process_init_file FILENAME
#    ie: process_init_file foo.sh influxd
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
    local f="$1"; shift;
    local inflex=(influx -host 127.0.0.1 ${INFLUXDB_ADMIN_USER:+ -username $INFLUXDB_ADMIN_USER} ${INFLUXDB_ADMIN_USER_PWD:+ -password $INFLUXDB_ADMIN_USER_PWD} -execute)

    case "$f" in
        *.sh)     echo "$0: running $f"; . "$f" ;;
        *.iql)    echo "$0: loading $f"; "${inflex[@]}" "$(cat $f)"; echo ;;
        *)        echo "$0: ignoring $f" ;;
    esac
    echo;
}

if [ ${CMD^^} == 'INITDB'  ];
then
    # process initial db state and/or configurations from /var/lib/influxdb/initdb.d/
    for f in ${INFLUXDB_INIT_DB}/*; do
        process_init_file "$f" ;
    done;

elif [ ${CMD^^} == 'BACKUP'  ];
then
    mkdir -p ${INFLUXDB_BACKUPDIR};
    influxd backup \
        -portable \
        -database ${DB} \
        ${INFLUXDB_BACKUPDIR}/${DB};
    # && tar -cvz \
    #     -f ${INFLUXDB_BACKUPDIR}/${DB}.tar.gz \
    #     -C ${INFLUXDB_BACKUPDIR} \
    #     ./${DB} \
    # && rm -rf ${INFLUXDB_BACKUPDIR}/${DB}/;

elif [ ${CMD^^} == 'RESTORE'  ];
then
    # tar -xvz \
    #     -f ${INFLUXDB_BACKUPDIR}/${DB}.tar.gz \
    #     -C ${INFLUXDB_BACKUPDIR} \
    # && \
    influxd restore \
        -portable \
        -database ${DB} \
        ${INFLUXDB_BACKUPDIR}/${DB};
    # && rm -rf ${INFLUXDB_BACKUPDIR}/${DB}/;

elif [ ${CMD^^} == 'HEALTHCHECK'  ];
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
fi;
