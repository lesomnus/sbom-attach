# sbom-attach

A GitHub Action that attaches an SBOM to an image you just pushed. For each image it:

1. **scans the image** with [syft](https://github.com/anchore/syft): the base's packages, the language packages installed in it, and the module list a Go binary carries;
2. **merges in what the build knows** and the image cannot show, if you give it any (see below);
3. **attaches the result** as a CycloneDX referrer (`application/vnd.cyclonedx+json`), so a scanner finds it without pulling the image;
4. **signs it**: a keyless [Sigstore](https://www.sigstore.dev/) attestation made with `cosign attest --type cyclonedx`, using the job's OIDC token.

```yaml
permissions:
  contents: read
  packages: write   # to push the referrer
  id-token: write   # to sign

steps:
  - uses: docker/login-action@v4
    with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }

  - id: build
    uses: docker/bake-action@v7
    with: { push: true }

  - uses: lesomnus/sbom-attach@v1
    with:
      metadata: ${{ steps.build.outputs.metadata }}
```

It reuses whatever registry login earlier steps made (`~/.docker/config.json`).

## What the image cannot show

An image scan finds what is in the image. Some of what an image was built from is not visible in it:

| | Why the image hides it | Give the action |
|---|---|---|
| **Bundled JavaScript**: vite, webpack, esbuild | The `node_modules` tree is folded into one file. | `source: .` scans the checkout's lockfiles. Dev dependencies are left out, since they are not shipped. |
| **Licenses of Go modules** | The binary lists its modules, but the license files are in the module cache, not the image. | `go-remote-licenses: "true"`, or `build-sbom:` with a scan made beside the module cache. |
| **Anything your build already describes** | | `build-sbom:` with one CycloneDX JSON file per line. |

**Go is not scanned from source**, even with `source: .`. The binary in the image already carries its exact module list, while `go.mod` also lists test and tool dependencies. The default `source-catalogers` is `javascript,python`.

### How the merge works

Components with the same purl are written once. Qualifiers such as `?arch=` and `?type=module` are ignored when comparing, because different scans disagree on them. Components without a purl (files, the operating system) are matched by type and name. Of two matching copies, the one with more licenses is kept; on a tie, the build's copy wins.

The rest of the document comes from the image scan, so `metadata.component` is the image. The merged document gets a fresh serial number and no dependency graph, because the graph would refer to `bom-ref`s from documents that were merged away.

`cyclonedx-cli merge` does not deduplicate. In our test it listed every Go module twice.

## Inputs

| input | default | |
|---|---|---|
| `images` | | `name@sha256:…`, one per line. **Tags are refused**: attach to exactly what was pushed. |
| `metadata` | | The `metadata` output of `docker/bake-action` or `docker/build-push-action`. Every entry with an `image.name` and a `containerimage.digest` is used. Combines with `images`. |
| `source` | | A directory to scan for build-side packages, usually `.`. |
| `source-catalogers` | `javascript,python` | syft catalogers for `source`, selected by tag. |
| `build-sbom` | | CycloneDX JSON files from the build, one per line. |
| `platform` | `linux/amd64` | Which platform of a multi-platform image to scan. |
| `go-remote-licenses` | `false` | Look up Go module licenses on the module proxy. |
| `attach` | `true` | Attach the plain CycloneDX referrer. |
| `sign` | `true` | Attach a signed attestation as well. Needs `id-token: write`. |
| `plain-http` | `false` | Talk to the registry over HTTP (for a local test registry). |

Outputs: `dir` (one directory per image) and `sboms` (`ref=path` per line).

## Verifying

```sh
cosign verify-attestation --type cyclonedx \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/<owner>/[^/]+/\.github/workflows/.+@refs/heads/main$' \
  <image>@<digest>
```

This proves the SBOM was made by a workflow on your `main` and has not changed since. It does **not** prove the SBOM is complete: a dependency that leaves no trace in the image or the build's lockfiles (a static C++ library, a Rust binary built without `cargo auditable`) is in neither scan.

**The signature is public.** Sigstore's transparency log records the repository, workflow, commit and image digest of every signing. Set `sign: "false"` if that is not acceptable.

## Tools

syft 1.54.1, oras 1.3.4 and cosign 3.1.3 are downloaded for linux amd64 or arm64. Each download is checked against a checksum pinned in [`install.sh`](install.sh), not against a checksum file fetched next to it. `jq` must already be on the runner, which it is on GitHub's runners.
