#!/usr/bin/env bash
# Build source-only SRU uploads for every fix in this repo.
#
# Run this ON AN UBUNTU MACHINE (or schroot) for the target series — it cannot
# work on Debian or any non-Ubuntu host, because pull-lp-source fetches from
# Launchpad and the build must match the Ubuntu series.
#
# What it does, per package × affected series:
#   pull-lp-source → copy patch into debian/patches/ → register in series →
#   quilt push -a (proves the patch applies clean) → dch security stanza →
#   debuild -S -d -sa (source-only, unsigned by default).
#
# What it deliberately does NOT do unless you pass --upload:
#   sign + dput. That step is outward-facing, irreversible, and must be done
#   by you with the GPG key registered on your Launchpad profile.
#
# Usage:
#   tools/submit-sru.sh                 # build everything, unsigned source pkgs
#   tools/submit-sru.sh --sign          # debuild -S -sa (sign with your key)
#   tools/submit-sru.sh --upload        # implies --sign, then dput ubuntu
#   tools/submit-sru.sh libsoup3        # only the named package(s)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workdir="${SRU_WORKDIR:-$root/.sru-build}"
sign=0
upload=0
only=()

for a in "$@"; do
    case "$a" in
        --sign)   sign=1 ;;
        --upload) sign=1; upload=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        --*) echo "unknown flag: $a" >&2; exit 2 ;;
        *) only+=("$a") ;;
    esac
done

# --- registry: package | "series,series" | patch (relative to repo root) | "CVE,CVE" | summary
fixes=(
  "libsoup3|jammy|libsoup3/CVE-2025-11021-CVE-2025-4945.patch|CVE-2025-11021,CVE-2025-4945|out-of-bounds read in cookie date parsing"
  "libyaml-syck-perl|jammy,noble|libyaml-syck-perl/CVE-2025-11683.patch|CVE-2025-11683|out-of-bounds read on empty-key YAML hashes"
  "gdcm|jammy,noble,questing|gdcm/CVE-2025-11266.patch|CVE-2025-11266|out-of-bounds write in DICOM fragment parsing"
)

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# --- preflight -------------------------------------------------------------
command -v lsb_release >/dev/null && [[ "$(lsb_release -is)" == Ubuntu ]] \
    || die "this host is not Ubuntu — run it in an Ubuntu schroot/VM for the target series"

missing=()
for t in pull-lp-source dch debuild quilt dpkg-parsechangelog; do
    command -v "$t" >/dev/null || missing+=("$t")
done
if ((${#missing[@]})); then
    die "missing tools: ${missing[*]}
  install with: sudo apt install devscripts ubuntu-dev-tools quilt"
fi
if ((sign)) && ! gpg --list-secret-keys >/dev/null 2>&1; then
    die "no GPG secret key found — needed to sign. Register one on your Launchpad profile first."
fi

# Compute the Ubuntu security version: append .1, or bump a trailing .N.
bump_version() {
    local v="$1"
    if [[ "$v" =~ \.[0-9]+$ ]]; then
        local n="${v##*.}"; echo "${v%.*}.$((n+1))"
    else
        echo "${v}.1"
    fi
}

mkdir -p "$workdir"
built=()

for entry in "${fixes[@]}"; do
    IFS='|' read -r pkg series_csv patch_rel cve_csv summary <<<"$entry"
    if ((${#only[@]})) && [[ ! " ${only[*]} " == *" $pkg "* ]]; then continue; fi
    patch_abs="$root/$patch_rel"
    [[ -f "$patch_abs" ]] || die "patch not found: $patch_rel"
    patch_file="$(basename "$patch_abs")"

    IFS=',' read -ra series <<<"$series_csv"
    IFS=',' read -ra cves   <<<"$cve_csv"

    for s in "${series[@]}"; do
        note "$pkg → $s"
        sdir="$workdir/$pkg-$s"
        rm -rf "$sdir"; mkdir -p "$sdir"
        ( cd "$sdir" && pull-lp-source "$pkg" "$s" ) || die "pull-lp-source $pkg $s failed"
        src="$(find "$sdir" -mindepth 1 -maxdepth 1 -type d -name "$pkg-*" | head -1)"
        [[ -d "$src" ]] || die "could not locate unpacked source for $pkg/$s"

        cur="$(cd "$src" && dpkg-parsechangelog -S Version)"
        new="$(bump_version "$cur")"

        install -m644 "$patch_abs" "$src/debian/patches/$patch_file"
        grep -qxF "$patch_file" "$src/debian/patches/series" 2>/dev/null \
            || echo "$patch_file" >> "$src/debian/patches/series"

        ( cd "$src" && QUILT_PATCHES=debian/patches quilt push -a ) \
            || die "patch does not apply cleanly for $pkg/$s — fix the patch, do not force"
        ( cd "$src" && QUILT_PATCHES=debian/patches quilt pop -a >/dev/null )

        # Changelog: one SECURITY UPDATE line + the CVE list.
        ( cd "$src"
          dch -v "$new" -D "$s-security" "SECURITY UPDATE: $summary"
          for c in "${cves[@]}"; do dch -a "  - $c"; done
        )

        dargs=(-S -d -sa)
        ((sign)) || dargs+=(-us -uc)
        ( cd "$src" && debuild "${dargs[@]}" ) || die "debuild failed for $pkg/$s"

        changes="$(find "$sdir" -maxdepth 1 -name "*_source.changes" | head -1)"
        built+=("$pkg/$s  ->  $cur  =>  $new  ($changes)")

        if ((upload)); then
            ( cd "$sdir" && dput ubuntu "$(basename "$changes")" ) \
                || die "dput failed for $pkg/$s"
        fi
    done
done

note "Done"
printf '  %s\n' "${built[@]}"
if ! ((upload)); then
    cat <<EOF

Source packages are in: $workdir
Next (you, with your Launchpad identity):
  • If you have upload rights:   dput ubuntu <pkg>_<ver>_source.changes
  • Otherwise, get it sponsored: debdiff the .dsc, attach to the LP bug,
    and subscribe 'ubuntu-sponsors'.
  • Either way, first replace '+bug/TODO' in the patch headers with the
    real Launchpad bug number (file one per package using */bug-report.md).
EOF
fi
