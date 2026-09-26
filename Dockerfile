# build stage - collect rsync and its libraries
FROM mwaeckerlin/very-base AS build
RUN $PKG_INSTALL rsync

# empty mount points that belong to the unprivileged user, so that a new
# named volume mounted there is writable for the container
RUN mkdir /source /target
RUN $ALLOW_USER /source /target

# create /root with only the rsync executable and its dependencies
# (paths relative to / so that tar has no leading slash to warn about)
RUN tar cph -C / \
        source target usr/bin/rsync \
        $(ldd /usr/bin/rsync | sed -n 's,.* => /\([^ ]*\) .*,\1,p') \
    | tar xpC /root/


# now create a minimalistic image from scratch
FROM mwaeckerlin/scratch
ENV CONTAINERNAME="rsync"
ENTRYPOINT ["/usr/bin/rsync", "-avP", "--delete"]
COPY --from=build /root/ /
