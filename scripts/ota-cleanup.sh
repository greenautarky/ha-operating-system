#!/bin/bash
# ota-cleanup.sh — disk-hygiene for OTA artifacts on ga-tools + ga-builder.
#
# Reality today: we churn through bake artifacts during dev (~1.5 GB per
# BOSv1.2.x baked img.xz + raucb pair). Without periodic pruning, both
# ga-tools (/data/ota/releases/) and ga-builder
# (/home/builder/ha-operating-system/ga_output/images/) fill up faster
# than we cut releases. This script keeps the latest N versions and
# moves older ones to an _archive/ sidecar (NOT delete — recoverable).
#
# Two modes:
#
#   ./ota-cleanup.sh --ota-server [--retain N] [--dry-run]
#       Run on ga-tools (= /data/ota/ owner). Prunes /data/ota/releases/
#       to the most-recent N HAOS-version directories. Older dirs are
#       archived to /data/ota/_archive/<timestamp>/<version>/.
#
#   ./ota-cleanup.sh --builder [--retain N] [--dry-run]
#       Run on ga-builder LXC. Prunes
#       /home/builder/ha-operating-system/ga_output/images/bos_ihost-*
#       artifacts to the most-recent N per HAOS-version (= multiple
#       timestamped bakes per version are common during dev). Same
#       _archive/ sidecar pattern.
#
# Defaults:
#   --retain 3 — keep last 3 HAOS-versions (= ~1 release / week, ~3 weeks of history)
#   Older "stable" releases (= future Option B with -rcN/-devN suffix
#   distinction) get the same N treatment for now; the per-suffix-class
#   age-out can be added once the naming convention is in active use.
#
# Safety: never deletes; always archives first. To physically free disk,
# run a separate `rm -rf /data/ota/_archive/older-than-30-days`.

set -euo pipefail

MODE=""
RETAIN=3
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --ota-server) MODE="ota-server"; shift ;;
        --builder)    MODE="builder";    shift ;;
        --retain)     RETAIN="$2";       shift 2 ;;
        --dry-run)    DRY_RUN=true;      shift ;;
        -h|--help)
            sed -n '2,/^set -/p' "$0" | sed 's/^# //' | head -n -1
            exit 0
            ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$MODE" ]] && { echo "ERROR: specify --ota-server or --builder"; exit 1; }
[[ "$RETAIN" =~ ^[0-9]+$ ]] || { echo "ERROR: --retain must be a positive integer"; exit 1; }
(( RETAIN >= 1 )) || { echo "ERROR: --retain must be >= 1"; exit 1; }

TS="$(date -u +%Y%m%d-%H%M%S)"

run() {
    if $DRY_RUN; then
        printf "  [dry-run] %s\n" "$*"
    else
        printf "  exec      %s\n" "$*"
        eval "$@"
    fi
}

if [[ "$MODE" == "ota-server" ]]; then
    RELEASES_DIR="/data/ota/releases"
    ARCHIVE_DIR="/data/ota/_archive/${TS}"
    [[ -d "$RELEASES_DIR" ]] || { echo "ERROR: $RELEASES_DIR missing — wrong host?"; exit 1; }

    echo "OTA-server cleanup → retain=${RETAIN} dry-run=${DRY_RUN}"
    echo "  releases: $RELEASES_DIR"
    echo "  archive:  $ARCHIVE_DIR"
    echo

    # Enumerate version dirs by mtime (newest first). HAOS-version dirs
    # are flat: 16.3.1.1, 16.3.1.7, etc. We sort by mtime (= when the
    # release was UPLOADED, not by HAOS version number) so the operator
    # can't accidentally prune a higher-numbered older bake.
    mapfile -t VERSIONS < <(
        find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d \
            -printf '%T@ %f\n' 2>/dev/null \
            | sort -rn \
            | awk '{print $2}'
    )
    TOTAL=${#VERSIONS[@]}
    echo "  found ${TOTAL} version(s); keeping the ${RETAIN} most-recent."
    echo

    [[ $TOTAL -le $RETAIN ]] && { echo "  Nothing to prune."; exit 0; }

    mkdir -p "$ARCHIVE_DIR"
    for ((i=RETAIN; i<TOTAL; i++)); do
        v="${VERSIONS[$i]}"
        size=$(du -sh "$RELEASES_DIR/$v" 2>/dev/null | awk '{print $1}')
        echo "  archiving $v (${size})..."
        run "mv \"$RELEASES_DIR/$v\" \"$ARCHIVE_DIR/$v\""
    done
    echo
    echo "  archive @ $ARCHIVE_DIR"
    $DRY_RUN || du -sh "$ARCHIVE_DIR" 2>/dev/null

elif [[ "$MODE" == "builder" ]]; then
    IMAGES_DIR="/home/builder/ha-operating-system/ga_output/images"
    ARCHIVE_DIR="/home/builder/ga-build-archive/${TS}"
    [[ -d "$IMAGES_DIR" ]] || { echo "ERROR: $IMAGES_DIR missing — wrong host?"; exit 1; }

    echo "ga-builder cleanup → retain=${RETAIN} per HAOS-version dry-run=${DRY_RUN}"
    echo "  images:  $IMAGES_DIR"
    echo "  archive: $ARCHIVE_DIR"
    echo

    # Group baked artifacts by HAOS version (= the X.Y.Z token in the
    # filename), then keep the N newest timestamped bakes per group.
    mapfile -t VERSIONS < <(
        find "$IMAGES_DIR" -maxdepth 1 -name 'bos_ihost-*.img.xz' \
            -printf '%f\n' 2>/dev/null \
            | sed -E 's/^bos_ihost-([0-9.]+)_.*/\1/' \
            | sort -u
    )

    archived_any=false
    for v in "${VERSIONS[@]}"; do
        # Bakes for this HAOS-version, newest mtime first.
        mapfile -t BAKES < <(
            find "$IMAGES_DIR" -maxdepth 1 -name "bos_ihost-${v}_*.img.xz" \
                -printf '%T@ %f\n' 2>/dev/null \
                | sort -rn \
                | awk '{print $2}' \
                | sed -E 's/\.img\.xz$//'
        )
        total=${#BAKES[@]}
        if (( total <= RETAIN )); then
            printf "  %-12s %d bake(s), keeping all\n" "$v:" "$total"
            continue
        fi
        printf "  %-12s %d bake(s), keeping %d, archiving %d\n" \
            "$v:" "$total" "$RETAIN" "$((total - RETAIN))"

        if ! $archived_any; then
            mkdir -p "$ARCHIVE_DIR"
            archived_any=true
        fi
        for ((i=RETAIN; i<total; i++)); do
            base="${BAKES[$i]}"
            # Move all artifacts that share the base prefix (img.xz, raucb, sha256 sidecars, etc.)
            for f in "$IMAGES_DIR/${base}".*; do
                [[ -f "$f" ]] || continue
                fname="${f##*/}"
                run "mv \"$f\" \"$ARCHIVE_DIR/$fname\""
            done
        done
    done
    echo
    if $archived_any && ! $DRY_RUN; then
        echo "  archive @ $ARCHIVE_DIR"
        du -sh "$ARCHIVE_DIR" 2>/dev/null
    elif ! $archived_any; then
        echo "  Nothing to prune."
    fi
fi

echo
echo "Done."
