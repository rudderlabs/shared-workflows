# image-join

Joins per-platform images, already pushed by digest, into one multi-arch index and
writes it to one or more tags. Use it after native per-platform build jobs that push
untagged images (for example `rudderlabs/build-scan-push-action` with
`push-by-digest: "true"`), so the repository holds only the final tags.

```yaml
- id: join
  uses: rudderlabs/shared-workflows/actions/image-join@<sha>
  with:
    image: registry.example.com/team/app   # repository only: no tag, no digest
    tags: |
      1.2.3
    children: |
      linux/amd64@${{ needs.build.outputs.amd64 }}
      linux/arm64@${{ needs.build.outputs.arm64 }}
# steps.join.outputs.digest is the index digest
```

The caller logs in to the registry first. Children are `<os>/<arch>[/<variant>]@sha256:<digest>`,
one per line, and must already exist in `image`.

Before anything is written, every child must pass:

- it is a single-platform image manifest, not an index or an attestation manifest
- its config platform equals the declared platform (`arm64/v8` = `arm64`, `amd64/v1` = `amd64`)
- its `org.opencontainers.image.revision` label equals `revision` (default: the run's commit)
- no two children share a platform or a digest

Then `imagetools create --dry-run` must produce an index with exactly the declared
children. A tag that already holds an index with exactly these children is not
rewritten, so a re-run is a no-op. After the write, the index is re-read by digest
and every tag must resolve to it.

Build each child with `provenance: false` and `sbom: false`: with attestations the
push is an index, which the join refuses.

This is a correctness check, not a security control: it catches stale or mismatched
children, not a malicious builder or registry. If a post-write check fails the step
fails, and tags already written are not rolled back.

Test locally (needs docker with buildx and jq): `bash tests/image-join/test_join.sh`.
