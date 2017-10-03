Docker Image for Simple Synchronization of Volumes
==================================================

Runs `rsync -avP --delete` with your additional options. This is very
handy, when you want to backup or migrate volumes. Other than `docker
cp` it supports incremental synchronisation, it can be restarted after
fail, and it is much more robust. For me, `docker cp` often fails with
large volumes (several TB).

Usage
-----

Basic usage is `docker run --rm mwaeckerlin/rsync`, `--rm` to remove
the temporary container after synchronization. Then mount some volumes
and add from and to parameters for the synchronization:

Synchronize `/var/lib/mysql` from a mysql database docker container
to a local directory in `/tmp/target`:

    docker run -d --name mysql -e MYSQL_ROOT_PASSWORD=secret mysql
    mkdir /tmp/target
    docker run --rm \
               -v /tmp/target:/target \
               --volumes-from mysql \
               mwaeckerlin/rsync \
               /var/lib/mysql/ /target/

Dry run, just add `-n`:

    docker run --rm \
               -v /tmp/target:/target \
               --volumes-from mysql \
               mwaeckerlin/rsync \
               -n /var/lib/mysql/ /target/

To use other options than default, set entrypoint to `rsync` and add
your options after the image, e.g. to run `rsync -a` instead of `rsync
-avP --delete`:

    docker run --rm \
               --entrypoint 'rsync' \
               … \
               mwaeckerlin/rsync \
               -a …
