# Debian 11 (bullseye) LTS ended 2026-08-31: its live security index lists
# packages that 404, so `apt-get update && install` against deb.debian.org no
# longer builds (Odoo #1288). release/1.5 keeps its bullseye build environment
# by (a) pinning the base image to the dated tag + digest it was built on and
# (b) pointing apt at an exact snapshot.debian.org timestamp - the state of the
# archive when the builder image hassos:local got its package layers
# (2026-04-14 07:37 UTC). Same inputs, forever; no dependence on the live mirror.
FROM debian:bullseye-20260406@sha256:bf53effcacca31b60ce97dabc67578f37e43075d716dc90804d3da3a80d2996c

# Set shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# apt: exact archive snapshot (see the note at the top). Valid-Until is off
# because the signed Release files of a frozen snapshot are, by definition, old.
ARG DEBIAN_SNAPSHOT=20260414T073700Z
RUN set -eu; \
    rm -f /etc/apt/sources.list.d/*; \
    printf '%s\n' \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bullseye main" \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bullseye-updates main" \
        "deb http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ bullseye-security main" \
        > /etc/apt/sources.list; \
    printf '%s\n' 'Acquire::Check-Valid-Until "false";' 'Acquire::Retries "5";' \
        > /etc/apt/apt.conf.d/99snapshot

# Docker
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gpg-agent \
        gpg \
        dirmngr \
        software-properties-common \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.gpg] \
        https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce=5:29.4.0-1~debian.11~bullseye \
        docker-ce-cli=5:29.4.0-1~debian.11~bullseye \
        containerd.io=2.2.2-1~debian.11~bullseye \
    && rm -rf /var/lib/apt/lists/*

# Build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        automake \
        bash \
        bc \
        binutils \
        build-essential \
        bzip2 \
        cpio \
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

# Init entry
COPY scripts/entry.sh /usr/sbin/
ENTRYPOINT ["/usr/sbin/entry.sh"]

# Get buildroot
WORKDIR /build
