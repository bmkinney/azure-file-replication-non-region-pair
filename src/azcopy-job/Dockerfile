FROM ubuntu:24.04

ARG AZCOPY_VERSION=10.30.1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends ca-certificates curl \
    && curl --fail --silent --show-error --location \
        "https://github.com/Azure/azure-storage-azcopy/releases/download/v${AZCOPY_VERSION}/azcopy_linux_amd64_${AZCOPY_VERSION}.tar.gz" \
        --output /tmp/azcopy.tar.gz \
    && mkdir /tmp/azcopy \
    && tar --extract --gzip --file /tmp/azcopy.tar.gz --directory /tmp/azcopy --strip-components=1 \
    && test "$(/tmp/azcopy/azcopy --version | head -n 1 | awk '{print $3}')" = "${AZCOPY_VERSION}" \
    && install -m 0755 /tmp/azcopy/azcopy /usr/local/bin/azcopy \
    && rm -rf /tmp/azcopy /tmp/azcopy.tar.gz /var/lib/apt/lists/*

COPY run-sync.sh /usr/local/bin/run-sync

# Builds from Windows checkouts can include CRLF line endings, which break /bin/sh.
RUN sed -i 's/\r$//' /usr/local/bin/run-sync \
    && chmod 0755 /usr/local/bin/run-sync \
    && groupadd --gid 10001 azcopy \
    && useradd --uid 10001 --gid azcopy --create-home azcopy \
    && mkdir -p /home/azcopy/.azcopy \
    && chown -R azcopy:azcopy /home/azcopy

USER 10001
WORKDIR /home/azcopy

ENTRYPOINT ["/usr/local/bin/run-sync"]