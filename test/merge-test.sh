#!/usr/bin/env bash
# merge.jq on fixtures. No network, no registry: jq only.
#
#   bash test/merge-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() {
	local name="$1" want="$2" got="$3"
	if [ "$want" = "$got" ]; then
		printf '  ok   %s\n' "$name"
	else
		printf '  FAIL %s\n--- want\n%s\n--- got\n%s\n' "$name" "$want" "$got"
		fail=1
	fi
}
merge() { jq -s --arg serial urn:uuid:merged -f merge.jq "$@"; }
refs() { jq -r '[.components[]."bom-ref"] | sort | join(" ")'; }

f=test/fixtures
out="$(merge "$f/build.cdx.json" "$f/image.cdx.json")"

# x/a: the build's has the license. x/b: the image's does.
check "a component both name is written once, with the licenses either has" \
	"b1 b3 i2 i3 i4" "$(refs <<<"$out")"
check "the document is the image's" "ghcr.io/example/app" "$(jq -r .metadata.component.name <<<"$out")"
check "a serial number of its own, version 1" "urn:uuid:merged 1" "$(jq -r '"\(.serialNumber) \(.version)"' <<<"$out")"
check "no dependency graph" "false" "$(jq 'has("dependencies")' <<<"$out")"
check "tools from all, once each" "1" "$(jq '.metadata.tools.components | length' <<<"$out")"

tie_b='{"bomFormat":"CycloneDX","components":[{"bom-ref":"b","purl":"pkg:golang/x@v1"}]}'
tie_i='{"bomFormat":"CycloneDX","components":[{"bom-ref":"i","purl":"pkg:golang/x@v1?type=module"}]}'
check "on a tie the build's is kept" "b" \
	"$(merge <(printf '%s' "$tie_b") <(printf '%s' "$tie_i") | refs)"

check "the image alone comes out as itself, less the graph" "i1 i2 i3 i4" \
	"$(merge "$f/image.cdx.json" | refs)"

two_builds="$(merge "$f/build.cdx.json" <(printf '%s' '{"bomFormat":"CycloneDX","components":[{"bom-ref":"n1","type":"library","purl":"pkg:npm/left-pad@1.3.0"}]}') "$f/image.cdx.json")"
check "two build documents and the image" "b1 b3 i2 i3 i4 n1" "$(refs <<<"$two_builds")"

exit "$fail"
