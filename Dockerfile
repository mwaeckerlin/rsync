# compile stage - the shell-free entrypoint
FROM mwaeckerlin/very-base AS init
RUN $PKG_INSTALL g++
COPY init.cpp .
RUN g++ -static -Os -flto=auto -fno-rtti -ffunction-sections -fdata-sections \
        -Wl,--gc-sections -Wl,-s -std=c++20 -Wall -Wextra -Werror \
        -o init init.cpp
RUN strip -s -R .comment -R .gnu.version --strip-unneeded init

# build stage - collect rsync and its libraries
FROM mwaeckerlin/very-base AS build
RUN $PKG_INSTALL rsync
COPY --from=init init /usr/bin/init

# empty mount points that belong to the unprivileged user, so that a new
# named volume mounted there is writable for the container
RUN mkdir /source /target
RUN $ALLOW_USER /source /target

# the daemon configuration generated from RSYNCD_MODULES, writable for every
# user given with --user
RUN mkdir -p /run/rsyncd
RUN chmod 1777 /run/rsyncd

# create /root with only the executables and the dependencies of rsync
# (paths relative to / so that tar has no leading slash to warn about)
RUN tar cph -C / \
        source target run/rsyncd usr/bin/rsync usr/bin/init \
        $(ldd /usr/bin/rsync | sed -n 's,.* => /\([^ ]*\) .*,\1,p') \
    | tar xpC /root/


# now create a minimalistic image from scratch
FROM mwaeckerlin/scratch
ENV CONTAINERNAME="rsync" \
    RSYNC_OPTIONS="-avP --delete" \
    RSYNCD_MODULES=""
ENTRYPOINT ["/usr/bin/init"]
COPY --from=build /root/ /
