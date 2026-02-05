FROM msjpq/wine-vnc:bionic

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEDEBUG=-all

RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor xvfb wget winbind ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Persisted wine prefix
RUN mkdir -p /config/.wine

COPY ./mt5/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# MT5 installer (broker) dentro immagine
COPY ./mt5/mt5setup.exe /root/mt5setup.exe

# Entrypoint install-on-first-run (senza python)
COPY ./mt5/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
