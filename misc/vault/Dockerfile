ARG VAULT_VERSION=1.13.3

FROM hashicorp/vault:$VAULT_VERSION

RUN apk update && apk add --no-cache curl jq coreutils

COPY /config /usr/local/bin/ebsco/config
COPY /scripts /usr/local/bin/ebsco/scripts

RUN chmod 500 /usr/local/bin/ebsco/scripts/*
RUN chmod 400 /usr/local/bin/ebsco/config/*

ENTRYPOINT [ "/usr/local/bin/ebsco/scripts/start.sh" ]
