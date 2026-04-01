# Reproducing a Build

Every prod build generates a `source-pins.json` that captures the exact
state of all sources used. This file, together with the defconfig and
container digest lockfile, allows reproducing the exact same build.

## What is captured

| Artifact | Location | Contents |
|----------|----------|----------|
| `source-pins.json` | `ga_output/images/configs/` | Git SHAs, tarball hashes, tool versions |
| `container-images.lock.json` | `ga_output/images/configs/` | Docker image digests (SHA256) |
| `buildroot.config` | `ga_output/images/configs/` | Resolved Buildroot .config |
| `kernel.config` | `ga_output/images/configs/` | Resolved kernel .config |
| `defconfig` | `ga_output/images/configs/` | Original defconfig used |
| `ga-frontend-version` | `/etc/ga-frontend-version` on rootfs | Frontend pyversion + SHA |

All of these are also included in the release archive (`create-release.sh`).

## Reproducing from source-pins.json

### Step 1: Check out exact source versions

```bash
# Read SHAs from source-pins.json
cat ga_output/images/configs/source-pins.json | jq '.repositories'

# Example output:
# [
#   { "name": "buildroot", "sha": "abc123..." },
#   { "name": "linux", "sha": "def456..." },
#   ...
# ]

# Check out ha-operating-system at the tagged release
git checkout v16.3.1.1

# The buildroot submodule is pinned in the repo
git submodule update --init
```

### Step 2: Restore secrets

These files are gitignored and must be manually placed:

```bash
mkdir -p secrets
# Copy from secure storage:
cp <secure>/wifi-install.psk secrets/
cp <secure>/openstick-wifi.key secrets/
cp <secure>/cert.pem .
cp <secure>/key.pem .
cp <secure>/rel-ca.pem buildroot-external/ota/
ln -sf rel-ca.pem buildroot-external/ota/dev-ca.pem
```

### Step 3: Build

```bash
# Same command as original build
./scripts/ga_build.sh full prod
```

The pre-build validation will check all required files are present.

### Step 4: Verify

Compare the new build's `source-pins.json` with the original:

```bash
diff <(jq -S . original/source-pins.json) <(jq -S . ga_output/images/configs/source-pins.json)
```

## What affects reproducibility

| Factor | Impact | Mitigation |
|--------|--------|------------|
| **Buildroot download cache** | Tarball hashes may differ if upstream changes | `source-pins.json` records tarball hashes |
| **Container image digests** | Same tag can have new content | `container-images.lock.json` records exact digests |
| **Host toolchain** | Different GCC version may produce different binaries | `source-pins.json` records host environment |
| **Timestamps** | Build timestamps differ | Expected — only content matters |
| **ccache** | May affect build order | Disable with `BR2_CCACHE=n` for exact reproduction |

## Bit-for-bit reproducibility

Full bit-for-bit reproducibility is **not guaranteed** due to:
- Timestamps embedded in binaries (kernel, packages)
- ccache artifacts
- Container image layers (Docker layer IDs are content-addressed but ordering varies)

However, **functional equivalence** is guaranteed: same source → same behavior.
The container digest lockfile ensures the exact same container images are used.

## Container image pinning

The build system pins containers by digest, not just tag:

```
# container-images.lock.json
{
  "images": [
    {
      "image": "ghcr.io/greenautarky/tinker-homeassistant:2025.11.3.1",
      "digest": "sha256:0e4c57f9b550...",
      "tar_sha256": "abc123..."
    }
  ]
}
```

To reproduce with exact same containers, pull by digest:
```bash
skopeo copy docker://ghcr.io/greenautarky/tinker-homeassistant@sha256:0e4c57f9b550... \
  docker-archive:core.tar
```

## Useful for

- **Audits**: Prove which source code produced a specific release
- **Debugging**: Reproduce a customer's exact build to investigate issues
- **Compliance**: ISO 9001 traceability requirement
- **Incident response**: Rebuild a known-good version after compromise
