# Dev/Prod Environment Tests

## Components
- Build-time config: `/etc/ga-env.conf`
- Runtime override: `/mnt/data/ga-env.conf`
- Environment variables: `GA_ENV`, `GA_LOG_LEVEL`, `GA_TELEMETRY`

## Prerequisites
- Device booted with a built image (dev or prod)
- `/etc/ga-env.conf` exists on rootfs

## Tests

### ENV-01: Build-time ga-env.conf exists
- **Action**: Verify config file is baked into rootfs
- **Command**: `test -f /etc/ga-env.conf && cat /etc/ga-env.conf`
- **Expected**: File exists with `GA_ENV`, `GA_LOG_LEVEL`, `GA_TELEMETRY` values

### ENV-02: GA_ENV value is valid
- **Action**: Check GA_ENV is either "dev" or "prod"
- **Command**: `. /etc/ga-env.conf && echo $GA_ENV`
- **Expected**: `dev` or `prod`

### ENV-03: Dev build has correct defaults
- **Action**: Verify dev build settings
- **Command**: `. /etc/ga-env.conf && echo "$GA_ENV $GA_LOG_LEVEL $GA_TELEMETRY"`
- **Expected**: `dev debug verbose`

### ENV-04: Prod build has correct defaults
- **Action**: Verify prod build settings
- **Command**: `. /etc/ga-env.conf && echo "$GA_ENV $GA_LOG_LEVEL $GA_TELEMETRY"`
- **Expected**: `prod warning minimal`

### ENV-05: Runtime override takes precedence
- **Action**: Create override file, restart service, verify
- **Command**:
  ```
  echo "GA_ENV=override_test" > /mnt/data/ga-env.conf
  systemctl restart telegraf
  grep GA_ENV /mnt/data/telegraf/env
  ```
- **Expected**: `GA_ENV=override_test`
- **Cleanup**: `rm /mnt/data/ga-env.conf`

### ENV-06: Rootfs config is read-only
- **Action**: Attempt to modify /etc/ga-env.conf
- **Command**: `echo "test" >> /etc/ga-env.conf 2>&1`
- **Expected**: Error (read-only filesystem)

### ENV-07: Image filename carries the ga_release (build-time)
- **Action**: Check the built image filename (ADR-0055)
- **Command**: `ls ga_output/images/*.img.xz` (build suite ENV-03c)
- **Expected**: `<ga_release>_<board>_<osver>.img.xz`, e.g. `BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz` (no `_dev_`/`_prod_` tag, no timestamp)

### ENV-08: os-release contains build info
- **Action**: Verify GA build metadata in os-release
- **Command**: `grep GA_ /etc/os-release`
- **Expected**: `GA_BUILD_ID`, `GA_BUILD_TIMESTAMP`, `GA_ENV` present

### ENV-09: PRETTY_NAME carries the ga_release (ADR-0055)
- **Command**: `. /etc/os-release; echo "$PRETTY_NAME"`; compare with `cat /etc/ga-release`
- **Expected**: `GreenAutarky <ga_release> (HAOS <VERSION_ID>)` exactly; built from /etc/ga-release, not from the file under test

### ENV-10 / ENV-11: login banner carries the ga_release
- **Command**: `grep -F "$(cat /etc/ga-release)" /etc/motd /etc/issue`
- **Expected**: both match

### ENV-12: technical IDs unchanged
- **Command**: `. /etc/os-release; echo "$VERSION_ID $CPE_NAME"`
- **Expected**: VERSION_ID is the plain HAOS version and CPE_NAME contains `:haos:<VERSION_ID>:` (Supervisor reads `hassos`/`haos` + version from the CPE)
