FROM steamcmd/steamcmd:ubuntu-24

# Valheim dedicated server: Steam app 896660, runs against the client's app id (892970).
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libatomic1 \
        libpulse0 \
        # libparty.so (PlayFab Party, used by -crossplay) links against this; without
        # it the plugin fails to load and the server never gets a join code.
        libpulse-mainloop-glib0 \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships a stock `ubuntu` user squatting on uid 1000; drop it so the
# server owns 1000 and bind-mounted ./data is writable by a normal host user.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash valheim \
    && mkdir -p /valheim /config \
    && chown -R valheim:valheim /valheim /config

COPY --chown=valheim:valheim entrypoint.sh mkworld.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/mkworld.sh

USER valheim
# The base image bakes HOME=/root, which a non-root USER cannot write — steamcmd
# stores its state under $HOME and dies on the first mkdir without this.
ENV HOME=/home/valheim
VOLUME ["/config"]
EXPOSE 2456/udp 2457/udp

# tini reaps the steamcmd children the server leaves behind.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
