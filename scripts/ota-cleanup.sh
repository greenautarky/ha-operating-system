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
#   ./ota-cleanup.sh --ota-server [--retain N] [--archive-retain M] [--dry-run]
#       Run on ga-tools (= /data/ota/ owner). Prunes /data/ota/releases/
#       to the most-recent N HAOS-version directories. Older dirs are
#       archived to /data/ota/_archive/<timestamp>/<version>/.
#
#   ./ota-cleanup.sh --builder [--retain N] [--archive-retain M] [--dry-run]
#       Run on ga-builder LXC. Prunes
#       /home/builder/ha-operating-system/ga_output/images/bos_ihost-*
#       artifacts to the most-recent N per HAOS-version (= multiple
#       timestamped bakes per version are common during dev). Same
#       _archive/ sidecar pattern.
#
# Defaults:
#   --retain 3 — keep last 3 HAOS-versions (= ~1 release / week, ~3 weeks of history)
#   --archive-retain 0 — archive expiry OFF unless asked for (see below)
#   Older "stable" releases (= future Option B with -rcN/-devN suffix
#   distinction) get the same N treatment for now; the per-suffix-class
#   age-out can be added once the naming convention is in active use.
#
# Safety: the release/bake pruning above NEVER deletes — it always archives
# first, so anything it touches stays recoverable under the _archive/ sidecar.
#
# But an archive that only ever grows is just a slower disk-full. Each weekly
# run lands ~10 GB of superseded dev bakes in the sidecar, so on 2026-07-27
# ga-builder hit 81% with 62 GB of never-pruned snapshots going back six weeks.
#
#   --archive-retain M
#       Physically delete archive snapshots beyond the M most recent. This is
#       the ONLY place this script deletes data, which is why it is opt-in and
#       defaults to 0 (= off, historical behaviour).
#
#       Counting note: retention runs AFTER this run's own snapshot was
#       created, so that fresh snapshot occupies one of the M slots. M=1
#       therefore keeps only what this run just archived and expires the
#       previous week immediately; M=2 is the floor for a real one-week
#       fallback (previous snapshot + current). The weekly builder cron uses
#       M=2 → ~2 snapshots ≈ 20-25 GB steady state.
#
#       Released bundles live on the OTA server regardless, so the
#       builder-side sidecar is a convenience net, not the system of record.

set -euo pipefail

MODE=""
RETAIN=3
ARCHIVE_RETAIN=0
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --ota-server)     MODE="ota-server"; shift ;;
        --builder)        MODE="builder";    shift ;;
        --retain)         RETAIN="$2";       shift 2 ;;
        --archive-retain) ARCHIVE_RETAIN="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true;      shift ;;
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
[[ "$ARCHIVE_RETAIN" =~ ^[0-9]+$ ]] || { echo "ERROR: --archive-retain must be a non-negative integer"; exit 1; }

TS="$(date -u +%Y%m%d-%H%M%S)"

# Paths this script must never touch, whatever it is asked to prune.
#
# Release evidence is filed per build under the builder's release-evidence dir
# because images/configs/ is a FIXED path that every build overwrites — the
# previous build's provenance is gone the moment the next one starts, which is
# sooner than any retention policy. Pruning the evidence would delete the only
# durable record of what a shipped version was built from, and the CRA support
# period is years while this script's retention is two builds.
#
# Deliberately a REFUSAL and not a comment. The first version of this was a
# variable named EVIDENCE_DIR_EXEMPT that was set and never read — a note that
# looked like a control. Anything that cannot fail is documentation.
PROTECTED_PATHS="/build/release-evidence /home/builder/release-evidence"

run() {
    local _cmd="$*" _p
    for _p in $PROTECTED_PATHS; do
        case "$_cmd" in
            *"$_p"*)
                echo "REFUSING: '$_cmd' targets protected path ${_p}." >&2
                echo "          Release evidence is the only durable record of what a" >&2
                echo "          shipped version was built from. It is never pruned here." >&2
                exit 1
                ;;
        esac
    done
    if $DRY_RUN; then
        printf "  [dry-run] %s\n" "$*"
    else
        printf "  exec      %s\n" "$*"
        eval "$@"
    fi
}

# Expire archive snapshots beyond the M most recent. The ONLY deleting path
# in this script — see the --archive-retain note in the header.
prune_archive_root() {
    local root="$1" keep="$2"

    (( keep > 0 )) || return 0
    [[ -d "$root" ]] || return 0

    echo
    echo "Archive retention → $root"

    # Empty snapshot dirs carry no data. Drop them, and — critically — keep
    # them out of the retention count: an empty dir occupying a keep-slot
    # would push a REAL snapshot past the cutoff and delete it instead.
    local d
    for d in "$root"/*/; do
        [[ -d "$d" ]] || continue
        [[ -n "$(ls -A "$d" 2>/dev/null)" ]] && continue
        echo "  dropping empty snapshot $(basename "${d%/}")"
        run "rmdir \"${d%/}\""
    done

    # Snapshot dirs are named %Y%m%d-%H%M%S, so a lexical sort IS chronological.
    # Preferred over mtime, which a later `mv` into the dir would bump.
    local snaps=()
    mapfile -t snaps < <(
        find "$root" -mindepth 1 -maxdepth 1 -type d -not -empty -printf '%f\n' 2>/dev/null | sort -r
    )
    local total=${#snaps[@]}

    echo "  found ${total} non-empty snapshot(s); keeping the ${keep} most-recent."
    if (( total <= keep )); then
        echo "  Nothing to expire."
        return 0
    fi

    local i s size
    for (( i = keep; i < total; i++ )); do
        s="${snaps[$i]}"
        size="$(du -sh "$root/$s" 2>/dev/null | awk '{print $1}')"
        echo "  expiring $s (${size:-?})..."
        run "rm -rf \"$root/$s\""
    done
    $DRY_RUN || echo "  archive now: $(du -sh "$root" 2>/dev/null | cut -f1)"
}

if [[ "$MODE" == "ota-server" ]]; then
    RELEASES_DIR="/data/ota/releases"
    ARCHIVE_ROOT="/data/ota/_archive"
    ARCHIVE_DIR="${ARCHIVE_ROOT}/${TS}"
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

    if [[ $TOTAL -le $RETAIN ]]; then
        # Nothing new to archive, but the sidecar may still need expiring —
        # so fall through to prune_archive_root instead of exiting here.
        echo "  Nothing to prune."
    else
        run "mkdir -p \"$ARCHIVE_DIR\""
        for ((i=RETAIN; i<TOTAL; i++)); do
            v="${VERSIONS[$i]}"
            size=$(du -sh "$RELEASES_DIR/$v" 2>/dev/null | awk '{print $1}')
            echo "  archiving $v (${size})..."
            run "mv \"$RELEASES_DIR/$v\" \"$ARCHIVE_DIR/$v\""
        done
        echo
        echo "  archive @ $ARCHIVE_DIR"
        $DRY_RUN || du -sh "$ARCHIVE_DIR" 2>/dev/null
    fi

    prune_archive_root "$ARCHIVE_ROOT" "$ARCHIVE_RETAIN"

elif [[ "$MODE" == "builder" ]]; then
    IMAGES_DIR="/home/builder/ha-operating-system/ga_output/images"
    ARCHIVE_ROOT="/home/builder/ga-build-archive"
    ARCHIVE_DIR="${ARCHIVE_ROOT}/${TS}"
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
            run "mkdir -p \"$ARCHIVE_DIR\""
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

    prune_archive_root "$ARCHIVE_ROOT" "$ARCHIVE_RETAIN"
fi

echo
echo "Done."
