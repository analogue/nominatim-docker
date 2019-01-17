#!/bin/bash

echo "starting $@"

if [ -f /usr/local/etc/osm-config.sh ]; then
    . /usr/local/etc/osm-config.sh
fi

if [ "$1" == "postgres" ]; then
    exec docker-entrypoint.sh "$@"
fi

# https://github.com/docker/docker/issues/6880
cat <> /Nominatim/build/logpipe 1>&2 &

if [ "$1" == "nominatim-apache2" ]; then
    echo "$1" called
    shift

    . /etc/apache2/envvars

    if [ ! -z "$APACHE_LOG_DIR" ]; then
        cd ${APACHE_LOG_DIR} && \
            ln -sf /dev/stdout access.log && \
            ln -sf /dev/stdout error.log
    fi

    if [ ! -d /data/nominatim ]; then
        mkdir /data/nominatim
        chown postgres: /data/nominatim
    fi

    cd /

    mkdir -p "$APACHE_RUN_DIR" && \
        rm -f $APACHE_PID_FILE && \
        exec /usr/sbin/apache2 -DFOREGROUND "$@"
fi

if [ "$1" == "nominatim-reinitdb" ]; then
    echo "$1" called, reinitializing nominatim database
    REINITDB=1 exec $0 nominatim-initdb
fi

if [ "$1" == "nominatim-redownload" ]; then
    echo "$1" called, redownloading osm files
    REDOWNLOAD=1 exec $0 nominatim-initdb
fi

if [ "$1" == "nominatim-initdb" ]; then
    echo "$1" called
    shift

    # if nominatim-initdv.init exists then the previous initdb didn't complete
    if [ -f /data/nominatim-initdb.init ]; then
        echo "detected previous nominatim-initdb didn't complete, redownlading and reinitialising db"
        REDOWNLOAD=1
    fi
    touch /data/nominatim-initdb.init

    until echo select 1 | gosu postgres psql template1 &> /dev/null ; do
            echo "Waiting for postgres"
            sleep 30
    done

    gosu postgres createuser www-data &> /dev/null || true

    if [ ! -f /data/nominatim/country_name.sql ]; then
        cd /Nominatim && \
            mkdir -p /data/nominatim && \
            cp -a data/* /data/nominatim && \
            chown -R postgres: /data/nominatim
            touch /data/nominatim/nominatim.log && \
            chgrp www-data /data/nominatim/nominatim.log && \
            chmod g+wr /data/nominatim/nominatim.log
    fi

    cd /Nominatim && \
        rm -rf data && \
        ln -s /data/nominatim data && \

    if [ "$REINITDB" -o "$REDOWNLOAD" ]; then
        echo reinitializing nominatim database, REINITDB="$REINITDB", REDOWNLOAD="$REDOWNLOAD"
        gosu postgres dropdb nominatim
    fi

    if ! $(echo "SELECT 'tables already created' FROM pg_catalog.pg_tables where tablename = 'country_osm_grid'" | \
            gosu postgres psql nominatim | grep -q 'tables already created') || [ "$REINITDB" ];then
        gosu postgres curl -L -z /Nominatim/data/country_osm_grid.sql.gz -o /Nominatim/data/country_osm_grid.sql.gz \
            https://www.nominatim.org/data/country_grid.sql.gz || {
                echo "error downloading https://www.nominatim.org/data/country_grid.sql.gz, exit 2"; exit 2; }
        gosu postgres curl -L -z /data/nominatim/wikipedia_article.sql.bin -o /data/nominatim/wikipedia_article.sql.bin \
            https://www.nominatim.org/data/wikipedia_article.sql.bin || {
                echo "error downloading https://www.nominatim.org/data/wikipedia_article.sql.bin, exit 3"; exit 3; }
        gosu postgres curl -L -z /data/nominatim/wikipedia_redirect.sql.bin -o /data/nominatim/wikipedia_redirect.sql.bin \
            https://www.nominatim.org/data/wikipedia_redirect.sql.bin|| {
                echo "error downloading https://www.nominatim.org/data/wikipedia_redirect.sql.bin, exit 4"; exit 4; }

        # this is a noop for a standalone nominatim container, it's used in
        # https://github.com/chesty/maps-docker-compose
        until ! test -f /data/renderd-initdb.init; do
            echo waiting on renderd-initdb
            sleep 30
        done

        if [ "$REDOWNLOAD" -o ! -f /data/"$OSM_PBF" -a "$OSM_PBF_URL" ]; then
            curl -L -z /data/"$OSM_PBF" -o /data/"$OSM_PBF" "$OSM_PBF_URL" || {
                echo "error downloading ${OSM_PBF_UPDATE_URL}/state.txt, exit 7"; exit 7; }
            curl -o /data/"$OSM_PBF".md5 "$OSM_PBF_URL".md5 || {
                echo "error downloading $OSM_PBF_URL, exit 8"; exit 8; }
            cd /data && \
                md5sum -c "$OSM_PBF".md5 || { rm -f /data/"$OSM_PBF"; exit 1; }
        fi
        REINITDB=1
    fi

    if ! $(echo "SELECT 'tables already created' FROM pg_catalog.pg_tables where tablename = 'planet_osm_nodes'" | \
            gosu postgres psql nominatim | grep -q 'tables already created') || [ "$REINITDB" ];then
        cd /Nominatim/build && \
            gosu postgres ./utils/setup.php --osm-file /data/"$OSM_PBF" --all --osm2pgsql-cache "$OSM2PGSQLCACHE" && \
            gosu postgres ./utils/specialphrases.php --wiki-import > /data/nominatim/specialphrases.sql && \
            gosu postgres psql -d nominatim -f /data/nominatim/specialphrases.sql && \
            gosu postgres ./utils/setup.php --create-functions --enable-diff-updates --create-partition-functions && \
            gosu postgres ./utils/update.php --recompute-word-counts && \
            gosu postgres ./utils/update.php --init-updates || {
                echo "error initialising database, exit 5"; exit 5; }
    fi
    rm -f /data/nominatim-initdb.init
    exit 0
fi

if [ "$1" == "nominatim-updatedb" ]; then
    shift
    sleep 5

    until echo select 1 | gosu postgres psql template1 &> /dev/null ; do
            echo "Waiting for postgres"
            sleep 30
    done

    # don't run update during initdb
    until [ ! -f /data/nominatim-initdb.init ]; do
        echo "$1 waiting for init to finish"
        sleep 30
    done

    gosu postgres ./utils/update.php --import-osmosis-all

    exit 0
fi

# postgresql container's docker-entrypoint.sh
exec docker-entrypoint.sh "$@"
