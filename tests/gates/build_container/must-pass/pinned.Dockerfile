# GreenAutarky build container, reproducible by construction (Odoo #1288).
# Every external input is pinned to something that cannot move:
#   - the base image, by dated tag AND content digest (trixie-20261005 = Debian 13.7)
#   - every Debian package, by an exact snapshot.debian.org timestamp (the apt
#     sources below are the ONLY ones; deb.debian.org / security.debian.org are
#     never referenced, so a rebuild next year resolves the same package set)
#   - docker-ce, docker-ce-cli and containerd.io, by exact version AND the
#     SHA-256 of each .deb (download.docker.com is not snapshotted; no apt repo
#     of Docker's is configured)
#   - the CVE scanners (trivy, syft, grype), by release AND SHA-256 (below)
# scripts/check-build-container.sh asserts all of it (build test SRC-BC-01).
# Bumping any pin is a deliberate edit of this file; never "latest".
FROM debian:trixie-20261005@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5

# Set shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# apt: exact archive snapshot. Check-Valid-Until is off because the signed
# Release files of a frozen snapshot are, by definition, old.
ARG DEBIAN_SNAPSHOT=20261019T060000Z
RUN set -eu; \
    rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*; \
    printf '%s\n' \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie main" \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-updates main" \
        "deb http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ trixie-security main" \
        > /etc/apt/sources.list; \
    printf '%s\n' 'Acquire::Check-Valid-Until "false";' 'Acquire::Retries "5";' \
        > /etc/apt/apt.conf.d/99snapshot

# Docker: the three .debs from download.docker.com, version- and SHA-256-pinned
# per architecture (the same two as the scanners below); their dependencies
# (iptables, ...) come from the snapshot above.
ARG DOCKER_VERSION=5:29.9.1-1~debian.13~trixie
ARG CONTAINERD_VERSION=2.4.2-2~debian.13~trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) d_sum=b33133205350e2765df0cc382f5a3ee44c2cfd4cdc3dc6ba32eca40839ac3574; \
             c_sum=c89d977d8073de91e7afcd099c82e16cef5506e4d446d006b240e77f78ba4b7d; \
             k_sum=a3e696cb98baafbb63895dc18b53f143088a2ead95c57820ac90dc5e1d61b05d ;; \
      arm64) d_sum=0e92412b105738c532b7b918ab2fa6b00fa195c346dcf493c0c048d318556f32; \
             c_sum=20b15fb2db59de70cc2172ba1a3cf01b2ab6a2258af20c286b15be2ceca13ecf; \
             k_sum=ec62600bdae178642eb3a6bc9817ff9ccd95a5891b6c3076ffbba11f3b4d1da6 ;; \
      *) echo "no pinned Docker checksums for $arch"; exit 1 ;; \
    esac; \
    mkdir /tmp/docker-debs; cd /tmp/docker-debs; \
    base=https://download.docker.com/linux/debian/dists/trixie/pool/stable/${arch}; \
    for spec in "docker-ce:${DOCKER_VERSION}:${d_sum}" "docker-ce-cli:${DOCKER_VERSION}:${c_sum}" "containerd.io:${CONTAINERD_VERSION}:${k_sum}"; do \
      name="${spec%%:*}"; rest="${spec#*:}"; sum="${rest##*:}"; ver="${rest%:*}"; \
      f="${name}_${ver#5:}_${arch}.deb"; \
      curl -sfL --retry 5 -o "$f" "${base}/${f}"; \
      echo "${sum}  ${f}" | sha256sum -c -; \
    done; \
    apt-get install -y --no-install-recommends ./docker-ce_*.deb ./docker-ce-cli_*.deb ./containerd.io_*.deb; \
    cd /; rm -rf /tmp/docker-debs /var/lib/apt/lists/*; \
    dpkg-query -W -f='${Version}\n' docker-ce | grep -qx "${DOCKER_VERSION}"; \
    dpkg-query -W -f='${Version}\n' containerd.io | grep -qx "${CONTAINERD_VERSION}"

# Build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        automake \
        bash \
        bc \
        binutils \
        build-essential \
        bzip2 \
        cpio \
        e2fsprogs \
        file \
        git \
        graphviz \
        help2man \
        jq \
        make \
        ncurses-dev \
        openssh-client \
        patch \
        perl \
        pigz \
        python3 \
        python3-matplotlib \
        python-is-python3 \
        qemu-utils \
        rsync \
        skopeo \
        sudo \
        texinfo \
        unzip \
        vim \
        wget \
        zip \
    && rm -rf /var/lib/apt/lists/*

# GreenAutarky: the build environment is upstream HAOS 18.x's (Debian trixie,
# haos/Dockerfile at the pinned commit) plus the block below. Keep the rest in
# step with haos/Dockerfile when the HAOS pin moves. (The blocks marked
# GreenAutarky are GA's; everything else is upstream's.)

# CVE scanners, pinned to an exact release and verified against the SHA-256
# published with that release (never "whatever main's install script fetches
# today"). scripts/scan-cves.sh uses all three for the container images:
#   trivy — the scanner of record (OS + language packages)
#   syft  — inventories every Go binary, so trivy's coverage of them is asserted
#   grype — second opinion for any Go binary trivy did not evaluate
# Bumping a version means bumping its checksums from the release's checksums file.
ARG TRIVY_VERSION=0.74.0
ARG SYFT_VERSION=1.52.0
ARG GRYPE_VERSION=0.119.0
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) t_arch=64bit; a_arch=amd64; \
             t_sum=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a; \
             s_sum=caeedb81fb0491615f1ebd1761e4145d41ee86dd2cc7bf80669f9f5ad9d6133d; \
             g_sum=3fa2dc4b924621ab65404cf08d0b8438d896d80ab949c9d5a4ca283c36004c9b ;; \
      arm64) t_arch=ARM64; a_arch=arm64; \
             t_sum=b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5; \
             s_sum=c46d5e4c28e12aa4c5becfaa343ef1c7f89045b6b895f2c21d471c62db09c706; \
             g_sum=29f0ec7c549ddb0e2b6a0ca714851f7399438afc399b80c12808e065edc9a8f8 ;; \
      *) echo "no pinned CVE scanner checksums for $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    fetch() { curl -sfL -o /tmp/tool.tgz "$1" && echo "$2  /tmp/tool.tgz" | sha256sum -c - \
              && tar -xzf /tmp/tool.tgz -C /usr/local/bin "$3" && rm -f /tmp/tool.tgz; }; \
    fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${t_arch}.tar.gz" "$t_sum" trivy; \
    fetch "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${a_arch}.tar.gz" "$s_sum" syft; \
    fetch "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${a_arch}.tar.gz" "$g_sum" grype; \
    trivy --version | grep -qx "Version: ${TRIVY_VERSION}"; \
    syft version | grep -q "^Version: *${SYFT_VERSION}$"; \
    grype version | grep -q "^Version: *${GRYPE_VERSION}$"

# GreenAutarky: Buildroot's CVE tooling (support/scripts/cve-check, cve.py)
# imports distutils, which Python 3.12 removed (trixie ships 3.13); setuptools
# provides the module again. Without it the build's NVD enrichment crashes and
# the OS CVE gate refuses the image (2026-10-17, first 18.3 build). Asserted
# here so the image cannot be built without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-setuptools \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -c "import distutils.version"

# Init entry
COPY scripts/entry.sh /usr/sbin/
ENTRYPOINT ["/usr/sbin/entry.sh"]

# Get buildroot
WORKDIR /build
