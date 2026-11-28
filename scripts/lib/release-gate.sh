# shellcheck shell=bash
# release-gate.sh — the BOS release gate (ENGINEERING-NORMS N65, Odoo #2137).
# Sourced by scripts/create-release.sh. No side effects on load.
#
# No release without COMPLETE gate evidence for the EXACT image sha256 that is
# being released. The evidence is one key=value file per release, written by
# k31-reflash.sh (machine part) and `release-evidence sign` (human part), kept
# PRIVATE (it holds names and dates; this repo is public) in a directory on the
# machine that runs create-release.sh (default ~/release-evidence on ga-builder).
#
# Format (one `key=value` per line, no spaces around `=`, `#` comments allowed):
#   release=BOSv1.6.1-rc2              full release label (never just "rc2")
#   image=<file>.img.xz                the artefact
#   image_sha256=<64 hex>              compared with the sha256 of the file
#                                      ACTUALLY being released, never trusted
#   k31_reflash_verdict=PASS           step 11 verdict, exactly PASS
#   k31_reflash_last_step=11           the run reached step 11 (N66: one
#                                      uninterrupted invocation)
#   k31_reflash_at=<ISO time>          k31_reflash_run_log=<path>
#   onboarding=PASS <date> ...         tenant onboarding with a test user
#   ui_hand_test_thomas=SIGNED <date> by <name>   (DONE <date> also accepted)
#   signoff_ahmad=SIGNED <date> by <name>
#   signoff_ramin=SIGNED <date> by <name>
#   vccio5_fresh_sd=PASS <pointer>        iHost releases >= BOSv1.6.1 ONLY (option B,
#                                         Odoo #1981): a fresh SD flash WITHOUT the
#                                         ga_vccio5 key booted 3.3 V, read on the device
#   vccio5_ota_keeps_1v8=PASS <pointer>   iHost releases >= BOSv1.6.1 ONLY: a device on
#                                         BOSv1.6.0 at 1.8 V, OTA'd to this release, still
#                                         runs 1.8 V after the reboot. <pointer> = a short
#                                         reference to the log/run that shows it (never
#                                         empty: a bare PASS is refused)
#   auto_gate=PASS <date> ... sha256=<image sha>   weekly sprint (KB #381), iHost releases
#                                         >= BOSv1.6.2 ONLY: the automated K31 gate after the
#                                         bake passed for THIS image (sha must equal image_sha256)
#   bundle_sha256=<64 hex>                same scope: the RAUC bundle baked with this image
#   soak_k7=PASS <date> ... bundle_sha256=<bundle sha>   same scope: the 24 h K7 soak passed
#                                         on THIS bundle (sha must equal bundle_sha256)
#   gate_override=<ts> by <user>: <reason>   (appended by --override-gate only)
# Any other key is free-form evidence and is ignored by the gate.
#
# The gate is held to this by tests/gates/release_evidence/selftest.sh, which
# drives THIS file and create-release.sh itself (never a copy).

# Values of required keys that carry a signature or a pass, with an ISO date.
GA_GATE_SIGNED_RE='^(SIGNED|DONE) [0-9]{4}-[0-9]{2}-[0-9]{2}'
GA_GATE_PASSED_RE='^PASS [0-9]{4}-[0-9]{2}-[0-9]{2}'
# Evidence keys the gate requires.
GA_GATE_REQUIRED_KEYS="release image image_sha256 k31_reflash_verdict k31_reflash_last_step onboarding ui_hand_test_thomas signoff_ahmad signoff_ramin"
# Option B evidence (Odoo #1981): required for iHost releases >= BOSv1.6.1 only.
# The value is "PASS" plus a non-empty evidence pointer.
GA_GATE_VCCIO5_FIELDS="vccio5_fresh_sd vccio5_ota_keeps_1v8"
GA_GATE_PASS_POINTER_RE='^PASS [^[:space:]]'
# Weekly sprint (KB #381, Thomas 2026-11-26/28): automated K31 gate + 24 h K7 soak.
# Switch point = the first release of the sprint, BOSv1.6.2 (rc included). Releases
# below it (BOSv1.6.1 and its rcs) were gated by hand and stay valid without them.
GA_GATE_AUTO_FROM="1.6.2"
GA_GATE_AUTO_FIELDS="auto_gate bundle_sha256 soak_k7"

# ga_gate_version_ge RELEASE X.Y.Z — rc 0 when the base version of RELEASE
# (BOSvA.B.C[-rcN], rc ignored) is >= X.Y.Z. Unparsable = rc 1.
ga_gate_version_ge() {
	local a b
	[[ "$1" =~ ^BOSv([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
	a=$(printf '%05d%05d%05d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
	[[ "$2" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
	b=$(printf '%05d%05d%05d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
	[[ "$a" > "$b" || "$a" == "$b" ]]
}

# ga_gate_needs_auto RELEASE IMAGE_FILE — rc 0 for an iHost image (bos_ihost*) of
# base version >= GA_GATE_AUTO_FROM. iHost only: the automated gate runs on K31;
# the DSGW line gets its own once DUT2 has an automated gate.
ga_gate_needs_auto() {
	case "$(basename -- "$2")" in bos_ihost*) ;; *) return 1 ;; esac
	ga_gate_version_ge "$1" "$GA_GATE_AUTO_FROM"
}

# ga_gate_needs_vccio5 RELEASE IMAGE_FILE — rc 0 when the release is an iHost
# image (file name bos_ihost*) of base version >= 1.6.1 (rc suffix ignored:
# BOSv1.6.1-rc3 counts as 1.6.1).
ga_gate_needs_vccio5() {
	local rel="$1" img="$2" maj min pat
	case "$(basename -- "$img")" in bos_ihost*) ;; *) return 1 ;; esac
	[[ "$rel" =~ ^BOSv([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
	maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; pat="${BASH_REMATCH[3]}"
	[ "$maj" -gt 1 ] && return 0
	[ "$maj" -eq 1 ] && { [ "$min" -gt 6 ] || { [ "$min" -eq 6 ] && [ "$pat" -ge 1 ]; }; } && return 0
	return 1
}

# ga_gate_get FILE KEY — prints the value of KEY. rc 0 = exactly one line,
# 1 = absent, 2 = duplicated (ambiguous: a second line must never win silently).
ga_gate_get() {
	local n
	n="$(grep -c -- "^$2=" "$1" 2>/dev/null || true)"
	case "$n" in
		1) grep -- "^$2=" "$1" | head -n 1 | cut -d= -f2- ; return 0 ;;
		0) return 1 ;;
		*) return 2 ;;
	esac
}

# ga_release_gate_check EVIDENCE_FILE RELEASE IMAGE_FILE
# Prints every reason the release is blocked, one per line, on stdout.
# rc 0 = complete evidence for this exact image; rc 1 = blocked.
ga_release_gate_check() {
	local ev="$1" rel="$2" img="$3" bad=0 v rc actual k n=0

	if [ -z "$rel" ]; then echo "  - no --release given (the full label, e.g. BOSv1.6.1-rc2)"; return 1; fi
	if [ ! -f "$img" ]; then echo "  - image file '$img' not found, cannot hash it"; return 1; fi
	if [ ! -s "$ev" ]; then
		echo "  - no evidence file for $rel (expected $ev, missing or empty)"
		return 1
	fi
	actual="$(sha256sum -- "$img" | awk '{print $1}')"
	if [ "${#actual}" -ne 64 ]; then echo "  - could not hash $img"; return 1; fi

	for k in $GA_GATE_REQUIRED_KEYS; do
		n=$((n + 1))
		rc=0; v="$(ga_gate_get "$ev" "$k")" || rc=$?
		if [ "$rc" -eq 2 ]; then echo "  - $k appears more than once in $ev (ambiguous)"; bad=1; continue; fi
		if [ "$rc" -ne 0 ] || [ -z "$v" ]; then echo "  - $k is missing or empty"; bad=1; continue; fi
		case "$k" in
			release)
				[ "$v" = "$rel" ] || { echo "  - evidence is for release '$v', not '$rel'"; bad=1; } ;;
			image)
				[ "$v" = "$(basename -- "$img")" ] || { echo "  - evidence image '$v' is not the file being released '$(basename -- "$img")'"; bad=1; } ;;
			image_sha256)
				[ "$v" = "$actual" ] || { echo "  - image_sha256 mismatch: evidence says ${v}, the image being released is ${actual}"; bad=1; } ;;
			k31_reflash_verdict)
				[ "$v" = "PASS" ] || { echo "  - k31_reflash_verdict is '$v', not PASS"; bad=1; } ;;
			k31_reflash_last_step)
				[ "$v" = "11" ] || { echo "  - k31 run stopped at step '$v', not 11 (no verdict was reached)"; bad=1; } ;;
			onboarding)
				printf '%s' "$v" | grep -Eq "$GA_GATE_PASSED_RE" || { echo "  - onboarding is '$v' (want 'PASS <date> ...')"; bad=1; } ;;
			ui_hand_test_thomas|signoff_ahmad|signoff_ramin)
				printf '%s' "$v" | grep -Eq "$GA_GATE_SIGNED_RE" || { echo "  - $k is '$v' (want 'SIGNED <date> by <name>') - not signed"; bad=1; } ;;
		esac
	done
	# Option B (Odoo #1981): both vccio5 paths, iHost >= BOSv1.6.1 only.
	if ga_gate_needs_vccio5 "$rel" "$img"; then
		for k in $GA_GATE_VCCIO5_FIELDS; do
			n=$((n + 1))
			rc=0; v="$(ga_gate_get "$ev" "$k")" || rc=$?
			if [ "$rc" -eq 2 ]; then echo "  - $k appears more than once in $ev (ambiguous)"; bad=1; continue; fi
			if [ "$rc" -ne 0 ] || [ -z "$v" ]; then echo "  - $k is missing or empty (iHost >= BOSv1.6.1 needs 'PASS <evidence pointer>')"; bad=1; continue; fi
			printf '%s' "$v" | grep -Eq "$GA_GATE_PASS_POINTER_RE" || { echo "  - $k is '$v' (want 'PASS <evidence pointer>')"; bad=1; }
		done
	fi
	# Weekly sprint (KB #381): automated K31 gate + K7 soak, each bound to its sha.
	if ga_gate_needs_auto "$rel" "$img"; then
		local bsha=""
		for k in $GA_GATE_AUTO_FIELDS; do
			n=$((n + 1))
			rc=0; v="$(ga_gate_get "$ev" "$k")" || rc=$?
			if [ "$rc" -eq 2 ]; then echo "  - $k appears more than once in $ev (ambiguous)"; bad=1; continue; fi
			if [ "$rc" -ne 0 ] || [ -z "$v" ]; then echo "  - $k is missing or empty (iHost >= BOSv${GA_GATE_AUTO_FROM} needs it: automated K31 gate + K7 soak)"; bad=1; continue; fi
			case "$k" in
				bundle_sha256)
					if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then bsha="$v"; else echo "  - bundle_sha256 is '$v' (want 64 lowercase hex)"; bad=1; fi ;;
				auto_gate)
					if ! printf '%s' "$v" | grep -Eq "$GA_GATE_PASSED_RE"; then echo "  - auto_gate is '$v' (want 'PASS <date> ... sha256=<image sha>')"; bad=1
					elif [[ " $v " != *" sha256=$actual "* ]]; then echo "  - auto_gate does not name sha256=$actual (it passed for another image, or names none)"; bad=1; fi ;;
				soak_k7)
					if ! printf '%s' "$v" | grep -Eq "$GA_GATE_PASSED_RE"; then echo "  - soak_k7 is '$v' (want 'PASS <date> ... bundle_sha256=<bundle sha>')"; bad=1
					elif [ -z "$bsha" ] || [[ " $v " != *" bundle_sha256=$bsha "* ]]; then echo "  - soak_k7 does not name bundle_sha256=${bsha:-<none recorded>} (it soaked another bundle, or names none)"; bad=1; fi ;;
			esac
		done
	fi
	# Fail closed on a gate that inspected nothing.
	if [ "$n" -eq 0 ]; then echo "  - internal: zero required keys were checked"; return 1; fi
	return "$bad"
}

# ga_release_gate_override FILE RELEASE IMAGE_FILE REASON
# Records a written override INSIDE the release evidence (creating it if need
# be) so the audit trail lives with the release. The reason is mandatory.
ga_release_gate_override() {
	local ev="$1" rel="$2" img="$3" reason="$4" sha
	if [ "${#reason}" -lt 15 ]; then echo "override reason must be at least 15 characters (a real reason, not 'x')" >&2; return 1; fi
	case "$reason" in *$'\n'*|*$'\r'*) echo "override reason must be one line" >&2; return 1 ;; esac
	mkdir -p -- "$(dirname -- "$ev")" || return 1
	if [ ! -s "$ev" ]; then
		sha="$(sha256sum -- "$img" | awk '{print $1}')"
		printf 'release=%s\nimage=%s\nimage_sha256=%s\n' "$rel" "$(basename -- "$img")" "$sha" > "$ev" || return 1
	fi
	printf 'gate_override=%s by %s: %s\n' "$(date '+%F %T %Z')" "${SUDO_USER:-${USER:-unknown}}" "$reason" >> "$ev"
}
