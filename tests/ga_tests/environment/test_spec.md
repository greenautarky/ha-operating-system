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

### ENV-07: Image filename contains env tag
- **Action**: Check built image filename includes dev/prod
- **Command**: `ls /mnt/data/*.raucb 2>/dev/null` (or check os-release)
- **Expected**: Filename contains `_dev_` or `_prod_`

### ENV-08: os-release contains build info
- **Action**: Verify GA build metadata in os-release
- **Command**: `grep GA_ /etc/os-release`
- **Expected**: `GA_BUILD_ID`, `GA_BUILD_TIMESTAMP`, `GA_ENV` present
