#!/usr/bin/env python3
"""Summarise a Playwright JSON report.

Reads the OUTCOME of each test from `tests[].status`, which Playwright fills
with one of expected / unexpected / flaky / skipped. The per-attempt field
`tests[].results[].status` holds passed / failed and counts every retry
separately, so a suite with 41 failing tests and one retry each reports 82
failures there — a number that is real and answers a different question.

This script previously read `tests[].status` while comparing it against
"passed" / "failed", which that field never contains. Both counters were
therefore always zero, and the only sentence the summary could print was
"ALL PASS" — including on the run that exposed it (91 passed, 41 failed).

It exits non-zero when the report cannot be read, when it contains no tests,
or when any test did not pass: a summary that cannot report a failure is worse
than no summary, because people stop reading the log below it.
"""
import json
import sys

# Playwright's outcome vocabulary. Pinned here rather than inferred from the
# report, so a renamed or unexpected value is a loud failure and not a silent
# zero.
OUTCOMES = {
    "expected": "passed",
    "unexpected": "failed",
    "flaky": "flaky",
    "skipped": "skipped",
}


def walk(node, counts, unknown):
    for spec in node.get("specs", []):
        for test in spec.get("tests", []):
            status = test.get("status")
            key = OUTCOMES.get(status)
            if key is None:
                unknown[status] = unknown.get(status, 0) + 1
            else:
                counts[key] += 1
    for suite in node.get("suites", []):
        walk(suite, counts, unknown)
    return counts


def main(path):
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as err:
        print(f"  E2E: could not read {path}: {err}")
        print("  Result: NO RESULT — treating as failure")
        return 2

    counts = {"passed": 0, "failed": 0, "flaky": 0, "skipped": 0}
    unknown: dict = {}
    walk(data, counts, unknown)

    total = sum(counts.values()) + sum(unknown.values())
    print("=" * 46)
    print(
        f"  E2E: {counts['passed']} passed, {counts['failed']} failed, "
        f"{counts['flaky']} flaky, {counts['skipped']} skipped"
    )

    if unknown:
        print(f"  Unrecognised outcomes: {unknown}")
        print("  Result: UNRECOGNISED REPORT FORMAT — treating as failure")
        print("=" * 46)
        return 2

    # A run over zero tests is a failure wearing the colour of success.
    if total == 0:
        print("  Result: ZERO TESTS — the report is empty, treating as failure")
        print("=" * 46)
        return 2

    if counts["failed"] or counts["flaky"]:
        print(f"  Result: {counts['failed']} FAILURES, {counts['flaky']} FLAKY")
        print("=" * 46)
        return 1

    if counts["passed"] == 0:
        print(f"  Result: NOTHING RAN — {counts['skipped']} skipped, 0 executed")
        print("=" * 46)
        return 2

    print("  Result: ALL PASS")
    print("=" * 46)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "test-results/results.json"))
