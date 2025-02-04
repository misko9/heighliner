FROM golang:1.19.0-alpine3.16 AS build-env

RUN apk add --update --no-cache curl make git libc-dev bash gcc linux-headers eudev-dev ncurses-dev

ARG TARGETARCH
ARG BUILDARCH

# Build minimal busybox
WORKDIR /
# busybox v1.34.1 stable
RUN git clone -b 1_34_1 --single-branch https://git.busybox.net/busybox
WORKDIR /busybox
ADD busybox.min.config .config
RUN make

ARG GITHUB_ORGANIZATION
ARG REPO_HOST

WORKDIR /go/src/${REPO_HOST}/${GITHUB_ORGANIZATION}

ARG GITHUB_REPO
ARG VERSION

RUN git clone -b ${VERSION} --single-branch https://${REPO_HOST}/${GITHUB_ORGANIZATION}/${GITHUB_REPO}.git

WORKDIR /go/src/${REPO_HOST}/${GITHUB_ORGANIZATION}/${GITHUB_REPO}

ARG BUILD_TARGET
ARG BUILD_ENV
ARG BUILD_TAGS
ARG PRE_BUILD
ARG BUILD_DIR

RUN set -eux; \
    WASM_VERSION=$(go list -u -m all | grep github.com/CosmWasm/wasmvm | awk '{print $2}'); \
    if [ ! -z "${WASM_VERSION}" ]; then \
      wget -O /lib/libwasmvm_muslc.a https://github.com/CosmWasm/wasmvm/releases/download/${WASM_VERSION}/libwasmvm_muslc.$(uname -m).a; \
    fi; \
    export CGO_ENABLED=1 LDFLAGS='-linkmode external -extldflags "-static"'; \
    if [ ! -z "$PRE_BUILD" ]; then sh -c "${PRE_BUILD}"; fi; \
    if [ ! -z "$BUILD_TARGET" ]; then \
      if [ ! -z "$BUILD_ENV" ]; then export ${BUILD_ENV}; fi; \
      if [ ! -z "$BUILD_TAGS" ]; then export "${BUILD_TAGS}"; fi; \
      if [ ! -z "$BUILD_DIR" ]; then cd "${BUILD_DIR}"; fi; \
      make ${BUILD_TARGET}; \
    fi

# Copy all binaries to /root/bin, for a single place to copy into final image.
# If a colon (:) delimiter is present, binary will be renamed to the text after the delimiter.
RUN mkdir /root/bin
ARG BINARIES
ENV BINARIES_ENV ${BINARIES}
RUN bash -c \
  'BINARIES_ARR=($BINARIES_ENV); \
  for BINARY in "${BINARIES_ARR[@]}"; do \
    BINSPLIT=(${BINARY//:/ }) ; \
    BINPATH=${BINSPLIT[1]} ; \
    if [ ! -z "$BINPATH" ]; then \
      if [[ $BINPATH == *"/"* ]]; then \
        mkdir -p "$(dirname "${BINPATH}")" ; \
        cp ${BINSPLIT[0]} "${BINPATH}"; \
      else \
        cp ${BINSPLIT[0]} "/root/bin/${BINPATH}"; \
      fi ;\
    else \
      cp ${BINSPLIT[0]} /root/bin/ ; \
    fi; \
  done'

RUN mkdir -p /root/lib
ARG LIBRARIES
ENV LIBRARIES_ENV ${LIBRARIES}
RUN bash -c 'LIBRARIES_ARR=($LIBRARIES_ENV); for LIBRARY in "${LIBRARIES_ARR[@]}"; do cp $LIBRARY /root/lib/; done'

RUN addgroup --gid 1025 -S heighliner && adduser --uid 1025 -S heighliner -G heighliner

# Use ln and rm from full featured busybox for assembling final image
FROM busybox:1.34.1-musl AS busybox-full

# Build final image from scratch
FROM scratch

LABEL org.opencontainers.image.source="https://github.com/strangelove-ventures/heighliner"

WORKDIR /bin

# Install ln (for making hard links) and rm (for cleanup) from full busybox image (will be deleted, only needed for image assembly)
COPY --from=busybox-full /bin/ln /bin/rm ./

# Install minimal busybox image as shell binary (will create hardlinks for the rest of the binaries to this data)
COPY --from=build-env /busybox/busybox /bin/sh

# Add hard links for read-only utils, then remove ln and rm
# Will then only have one copy of the busybox minimal binary file with all utils pointing to the same underlying inode
RUN ln sh pwd && \
    ln sh ls && \
    ln sh cat && \
    ln sh less && \
    ln sh grep && \
    ln sh sleep && \
    ln sh du && \
    rm ln rm

# Install chain binaries
COPY --from=build-env /root/bin /bin

# Install libraries
COPY --from=build-env /root/lib /lib

# Install trusted CA certificates
COPY --from=build-env /etc/ssl/cert.pem /etc/ssl/cert.pem

# Install heighliner user
COPY --from=build-env /etc/passwd /etc/passwd
COPY --from=build-env --chown=1025:1025 /home/heighliner /home/heighliner

WORKDIR /home/heighliner
USER heighliner
