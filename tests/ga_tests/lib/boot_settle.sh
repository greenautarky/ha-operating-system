#!/bin/sh
# boot_settle.sh - let a "last 5 min" journal check wait until boot noise has
# left its window. Source it; it only defines functions. POSIX sh (BusyBox ash).
#
# WHY (Odoo #1222, first seen 2026-10-09): TEL-10, NET-03, NET-03b and NET-04
# judge `journalctl --since '5 min ago'` for connection errors. The shippers
# log "connection refused" / "no upstream" / HTTP 4xx while the mesh and DNS
# come up, and that lasts several minutes after boot. A suite that starts
# within ~10 min of boot (every post-OTA / fresh-flash run does) reads those
# lines as a regression. A check that is red for a timing reason teaches
# people to ignore the colour.
#
# WHAT THIS DOES: it never changes what a check asserts. It only decides WHETHER
# the check may judge yet: uptime >= GA_SETTLE_SECS (default 660 = 5 min window
# + 6 min for the boot noise to end). If the device is younger, it waits
# (bounded by GA_SETTLE_WAIT seconds, default 720, polled every
# GA_SETTLE_INTERVAL, default 10). If the bound is hit the caller SKIPS with
# the reason - never a silent pass, never a fail for timing.
#
# Test seam: GA_UPTIME_CMD prints the uptime in seconds (default /proc/uptime);
# GA_SETTLE_SLEEP_CMD replaces `sleep` (the selftest drives the live functions).

_ga_uptime_s() {
  if [ -n "${GA_UPTIME_CMD:-}" ]; then sh -c "$GA_UPTIME_CMD"; return; fi
  awk '{ printf "%d\n", $1 }' /proc/uptime 2>/dev/null
}

# ga_boot_settled - 0 when uptime >= GA_SETTLE_SECS. An unreadable uptime is
# NOT settled (fail closed: the caller skips with the reason, loudly).
ga_boot_settled() {
  _bs_up=$(_ga_uptime_s)
  case "$_bs_up" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_bs_up" -ge "${GA_SETTLE_SECS:-660}" ]
}

# ga_wait_boot_settled - wait (bounded) until settled. 0 = settled, 1 = bound hit.
# Sets GA_SETTLE_REASON on failure (uptime, threshold, bound) for skip_test.
ga_wait_boot_settled() {
  _bs_waited=0
  _bs_max=${GA_SETTLE_WAIT:-720}
  _bs_int=${GA_SETTLE_INTERVAL:-10}
  while ! ga_boot_settled; do
    if [ "$_bs_waited" -ge "$_bs_max" ]; then
      GA_SETTLE_REASON="uptime '$(_ga_uptime_s)' s < ${GA_SETTLE_SECS:-660} s boot-settle threshold after waiting ${_bs_waited} s (GA_SETTLE_WAIT=${_bs_max}); the 5-min journal window still contains boot noise (Odoo #1222) - rerun later"
      return 1
    fi
    if [ -n "${GA_SETTLE_SLEEP_CMD:-}" ]; then sh -c "$GA_SETTLE_SLEEP_CMD $_bs_int"; else sleep "$_bs_int"; fi
    _bs_waited=$((_bs_waited + _bs_int))
  done
  return 0
}

# settled_run_test <id> <desc> <cmd> - run_test once boot has settled, else skip
# with the reason. Needs test_helpers.sh (run_test, skip_test).
settled_run_test() {
  if ga_wait_boot_settled; then
    run_test "$1" "$2" "$3"
  else
    skip_test "$1" "$2" "$GA_SETTLE_REASON"
  fi
}
