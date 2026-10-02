FROM ghcr.io/home-assistant/base:3.24

RUN apk add --no-cache bash coreutils jq inotify-tools curl lftp tar

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
