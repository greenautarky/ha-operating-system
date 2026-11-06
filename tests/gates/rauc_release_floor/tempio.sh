# shellcheck shell=bash
# Sourced by the release-floor self-tests: the tempio the image builds with
# (buildroot-external/package/tempio/tempio.mk), fetched and checksummed when
# it is not on PATH. Sets TEMPIO; exits the caller on failure.
TEMPIO_VERSION="2026.07.0"
TEMPIO_SHA256="c03682e407110fa89475c0231cde5c4b5fd59660c7fc68e5ce5d2e703ed8c002"
tempio_fetch() {  # <scratch dir>
  TEMPIO="$(command -v tempio || true)"
  [[ -n "$TEMPIO" ]] && return 0
  TEMPIO="$1/tempio"
  curl -fsSL -o "$TEMPIO" \
    "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_amd64" \
    || { echo "FATAL: could not fetch tempio ${TEMPIO_VERSION} — the live templates cannot be rendered"; exit 1; }
  echo "${TEMPIO_SHA256}  ${TEMPIO}" | sha256sum -c --quiet \
    || { echo "FATAL: tempio checksum mismatch"; exit 1; }
  chmod +x "$TEMPIO"
}
# tempio reads a JSON config from stdin when stdin is open: close it.
render() { "$TEMPIO" -template "$1" </dev/null; }
