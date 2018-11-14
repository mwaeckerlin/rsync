FROM alpine
MAINTAINER mwaeckerlin
ARG lang="en_US.UTF-8"

# change in childern:
ENV CONTAINERNAME     "rsync"

ENV LANG              "${lang}"
ENV PS1               '\[\033[36;1m\]\u\[\033[97m\]@\[\033[32m\]${CONTAINERNAME}[\[\033[36m\]\h\[\033[97m\]]:\[\033[37m\]\w\[\033[0m\]\$ '

RUN apk add rsync

ENTRYPOINT ["/usr/bin/rsync", "-avP", "--delete"]
