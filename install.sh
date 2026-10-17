#!/usr/bin/env bash
# Puts syft, oras and cosign on PATH, at the versions action.yml pins, each
# checked against a checksum pinned here -- not one fetched beside the binary,
# which would only prove the download matches itself.
#
#   install.sh <dir> <sign: true|false>
set -euo pipefail

dir="$1"
sign="$2"
mkdir -p "$dir"

case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) echo "sbom-attach: no pinned tools for $(uname -m)" >&2; exit 1 ;;
esac

SYFT_VERSION=1.54.1
ORAS_VERSION=1.3.4
COSIGN_VERSION=3.1.3

declare -A SUM=(
	[syft-amd64]=c069905b391cc4c20a5ba65ad5c10be2a7ba074f8ea6ad203e24d14e303dad47
	[syft-arm64]=dfdf0537610113edbefe1f1fc6548bc957b2d77439636ec824fcf0e10d46d054
	[oras-amd64]=f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454
	[oras-arm64]=15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399
	[cosign-amd64]=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
	[cosign-arm64]=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a
)

fetch() {
	local url="$1" out="$2" sum="$3"
	curl -fsSL --retry 3 -o "$out" "$url"
	echo "${sum}  ${out}" | sha256sum -c --quiet -
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${arch}.tar.gz" \
	"$tmp/syft.tgz" "${SUM[syft-$arch]}"
tar -xzf "$tmp/syft.tgz" -C "$dir" syft

fetch "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${arch}.tar.gz" \
	"$tmp/oras.tgz" "${SUM[oras-$arch]}"
tar -xzf "$tmp/oras.tgz" -C "$dir" oras

if [ "$sign" = true ]; then
	fetch "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${arch}" \
		"$dir/cosign" "${SUM[cosign-$arch]}"
	chmod +x "$dir/cosign"
fi

command -v jq >/dev/null || { echo "sbom-attach: jq is not on PATH" >&2; exit 1; }
"$dir/syft" version | sed -n 's/^Version: */syft /p'
"$dir/oras" version | sed -n 's/^Version: */oras /p'
if [ "$sign" = true ]; then "$dir/cosign" version 2>&1 | sed -n 's/^GitVersion: */cosign /p'; fi
