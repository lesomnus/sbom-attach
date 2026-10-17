#!/usr/bin/env bash
# The action, given the inputs as environment variables (action.yml). For each
# image: scan it, merge the build's documents into that scan, attach the result
# as a CycloneDX referrer, and -- unless told not to -- sign it as an attestation.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT_DIR:?}"
mkdir -p "$out"

log() { printf 'sbom-attach: %s\n' "$*"; }
die() { printf 'sbom-attach: %s\n' "$*" >&2; exit 1; }

export SYFT_CHECK_FOR_APP_UPDATE=false
# The packages are what a scanner reads; a file list of the image is hundreds of
# components (zoneinfo alone) that no one matches against anything.
export SYFT_FILE_METADATA_SELECTION=none
export SYFT_GOLANG_SEARCH_REMOTE_LICENSES="${GO_REMOTE_LICENSES:-false}"

oras_flags=()
if [ "${PLAIN_HTTP:-false}" = true ]; then
	oras_flags+=(--plain-http)
	export SYFT_REGISTRY_INSECURE_USE_HTTP=true
fi

# ── what to attach to ────────────────────────────────────────────────────────

# `name@sha256:…`, one per line. From `images`, and from a bake or build-push
# metadata output: each entry with an `image.name` and a `containerimage.digest`.
images=()
while IFS= read -r line; do
	line="${line%%#*}"
	line="$(printf '%s' "$line" | tr -d '[:space:]')"
	[ -n "$line" ] && images+=("$line")
done <<<"${IMAGES:-}"

if [ -n "${METADATA:-}" ]; then
	while IFS= read -r line; do
		[ -n "$line" ] && images+=("$line")
	done < <(jq -r '
		(if has("containerimage.digest") then {_: .} else . end)
		| to_entries[]
		| .value
		| select(type == "object" and .["image.name"] and .["containerimage.digest"])
		| (.["image.name"] | split(",")[0] | sub(":[^:/]+$"; "")) + "@" + .["containerimage.digest"]
	' <<<"$METADATA")
fi

[ "${#images[@]}" -gt 0 ] || die "nothing to attach to: give images or metadata"
for ref in "${images[@]}"; do
	[[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]] || die "not a digest reference: ${ref} (a tag moves; attach to what was pushed)"
done

# ── the build's documents ────────────────────────────────────────────────────

builds=()
if [ -n "${SOURCE:-}" ]; then
	# What the image cannot show: by default a lockfile's packages, which a bundler
	# folds into one file. Not Go -- the binary carries its module list and the
	# image's scan reads it; go.mod would add test and tool dependencies.
	syft scan "dir:${SOURCE}" --quiet --select-catalogers "${SOURCE_CATALOGERS}" \
		--source-name "${SOURCE_NAME:-${GITHUB_REPOSITORY:-source}}" --source-version "${GITHUB_SHA:-unknown}" \
		-o "cyclonedx-json=${out}/source.cdx.json"
	builds+=("${out}/source.cdx.json")
	log "source ${SOURCE} (${SOURCE_CATALOGERS}): $(jq '.components | length' "${out}/source.cdx.json") components"
fi
while IFS= read -r line; do
	line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	[ -z "$line" ] && continue
	[ -f "$line" ] || die "build-sbom ${line}: no such file"
	jq -e '.bomFormat == "CycloneDX"' "$line" >/dev/null || die "build-sbom ${line}: not a CycloneDX JSON document"
	builds+=("$line")
done <<<"${BUILD_SBOM:-}"

# ── each image ───────────────────────────────────────────────────────────────

uuid() { cat /proc/sys/kernel/random/uuid; }

attached=()
i=0
for ref in "${images[@]}"; do
	i=$((i + 1))
	d="${out}/${i}"
	mkdir -p "$d"

	# The default catalogers: sbom-cataloger is not among them, so an SBOM the image
	# carries inside it is not read back and counted twice.
	syft scan "registry:${ref}" --platform "${PLATFORM}" --quiet -o "cyclonedx-json=${d}/image.cdx.json"
	jq -s --arg serial "urn:uuid:$(uuid)" -f "${here}/merge.jq" "${builds[@]}" "${d}/image.cdx.json" >"${d}/sbom.cdx.json"
	n="$(jq '.components | length' "${d}/sbom.cdx.json")"
	l="$(jq '[.components[] | select((.licenses // []) | length > 0)] | length' "${d}/sbom.cdx.json")"
	log "${ref}: ${n} components, ${l} with a license"

	if [ "${ATTACH}" = true ]; then
		# From inside the directory: oras records the path as the file's title, and a
		# reader pulling the SBOM should get `sbom.cdx.json`.
		(cd "$d" && oras attach "${oras_flags[@]}" --artifact-type application/vnd.cyclonedx+json \
			"$ref" sbom.cdx.json:application/vnd.cyclonedx+json) >"${d}/attach.log"
		log "${ref}: attached $(sed -n 's/^Digest: //p' "${d}/attach.log")"
	fi
	if [ "${SIGN}" = true ]; then
		cosign attest --yes --type cyclonedx --predicate "${d}/sbom.cdx.json" "$ref" >"${d}/attest.log" 2>&1 \
			|| { cat "${d}/attest.log" >&2; die "${ref}: cosign attest failed (does the job have id-token: write?)"; }
		log "${ref}: signed"
	fi
	attached+=("${ref}=${d}/sbom.cdx.json")
done

{
	echo "dir=${out}"
	echo "sboms<<EOF"
	printf '%s\n' "${attached[@]}"
	echo "EOF"
} >>"${GITHUB_OUTPUT:-/dev/null}"
