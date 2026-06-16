FROM wiremock/wiremock:3.10.0

# WireMock base runs as root; /home/wiremock is the default mappings root.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-venv \
 && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY ws-bridge.py /opt/ws-bridge.py

ENV CHAIN_NAME=ethereum \
    RPC_HOST=0.0.0.0 \
    RPC_PORT=8545 \
    WIREMOCK_PORT=8080

EXPOSE 8545

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=5s --timeout=3s --start-period=20s --retries=12 \
  CMD python3 -c \
      "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${RPC_PORT}/health', timeout=2)" \
  || exit 1

ENTRYPOINT ["/entrypoint.sh"]
