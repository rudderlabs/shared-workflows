#!/usr/bin/env bash
# Local harness for actions/image-join/join.sh against a throwaway registry container.
# Needs: docker with buildx, jq. Pulls registry:3 and moby/buildkit if absent. Pushes only to the throwaway registry.
# Run: tests/image-join/test_join.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN="$HERE/../../actions/image-join/join.sh"
RUN_ID="$$"
NET="image-join-test-net-$RUN_ID"
REG="image-join-test-reg-$RUN_ID"
BUILDER="image-join-test-builder-$RUN_ID"
WORK="$(mktemp -d)"
REV="1111111111111111111111111111111111111111"
STALE="2222222222222222222222222222222222222222"
PASS=0
FAILED=0

cleanup() {
  docker buildx rm -f "$BUILDER" >/dev/null 2>&1
  docker rm -f "$REG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

docker network create --label image-join-test=1 "$NET" >/dev/null
docker run -d --rm --network "$NET" --name "$REG" --label image-join-test=1 -p 127.0.0.1::5000 registry:3@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c >/dev/null
PORT="$(docker port "$REG" 5000/tcp | head -1 | sed 's/.*://')"
HOST_IMAGE="localhost:$PORT/app"
BUILD_IMAGE="$REG:5000/app"

cat > "$WORK/buildkitd.toml" <<TOML
[registry."$REG:5000"]
  http = true
TOML
docker buildx create --name "$BUILDER" --driver docker-container \
  --driver-opt "network=$NET" --buildkitd-config "$WORK/buildkitd.toml" >/dev/null
docker buildx inspect --bootstrap --builder "$BUILDER" >/dev/null

mkdir "$WORK/ctx"
printf 'FROM scratch\nARG M\nCOPY m /m\n' > "$WORK/ctx/Dockerfile"

# build_leg <platform> <revision> <leg-tag> [extra build flags]  -> prints image digest
build_leg() {
  local platform="$1" rev="$2" leg="$3"; shift 3
  printf '%s %s %s\n' "$platform" "$rev" "$leg" > "$WORK/ctx/m"
  docker buildx build --builder "$BUILDER" --platform "$platform" \
    --label "org.opencontainers.image.revision=$rev" --provenance=false --sbom=false "$@" \
    --push -t "$BUILD_IMAGE:$leg" --metadata-file "$WORK/md.json" "$WORK/ctx" >/dev/null 2>&1 || { echo "BUILD-FAILED"; return 1; }
  jq -r '."containerimage.digest"' "$WORK/md.json"
}

tag_digest() {
  docker buildx imagetools inspect "$HOST_IMAGE:$1" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest' 2>/dev/null || true
}

index_summary() { # <digest> -> sorted platform@digest
  docker buildx imagetools inspect --raw "$HOST_IMAGE@$1" | jq -r '[.manifests[] | (.platform.os + "/" + .platform.architecture + (if .platform.variant then "/" + .platform.variant else "" end)) + "@" + .digest] | sort | .[]'
}

OUT=""
RC=0
run_join() { # <tags (newline-separated)> <revision> <children...>
  local tag="$1" rev="$2"; shift 2
  local children
  children="$(printf '%s\n' "$@")"
  OUT="$(JOIN_IMAGE="$HOST_IMAGE" JOIN_TAGS="$tag" JOIN_CHILDREN="$children" JOIN_REVISION="$rev" GITHUB_OUTPUT= bash "$JOIN" 2>&1)"
  RC=$?
}

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n      rc=%s out=%s\n' "$1" "$RC" "$OUT"; }
expect_ok() { [ "$RC" -eq 0 ] && ok "$1" || bad "$1"; }
expect_fail() { # <name> <tag> <expected-tag-digest|absent> <msg-substring>
  if [ "$RC" -ne 0 ] && [[ "$OUT" == *"$4"* ]] && [ "$(tag_digest "$2")" = "$3" ] ; then ok "$1"; else bad "$1 (tag now: $(tag_digest "$2"), wanted $3)"; fi
}
absent() { [ -z "$(tag_digest "$1")" ] && echo absent || tag_digest "$1"; }

AMD="$(build_leg linux/amd64 "$REV" leg-amd64)"
ARM="$(build_leg linux/arm64 "$REV" leg-arm64)"
V7="$(build_leg linux/arm/v7 "$REV" leg-armv7)"
STALE_ARM="$(build_leg linux/arm64 "$STALE" leg-arm64-stale)"
for d in "$AMD" "$ARM" "$V7" "$STALE_ARM"; do [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "setup failed: $d"; exit 2; }; done
FAKE="sha256:$(printf 'f%.0s' $(seq 64))"

# 1. two platforms
run_join t-two "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
GOT="$(printf '%s\n' "$OUT" | sed -n 's/^digest=//p' | tail -1)"
WANT="$(printf '%s\n' "linux/amd64@$AMD" "linux/arm64@$ARM" | sort)"
if [ "$RC" -eq 0 ] && [ "$GOT" = "$(tag_digest t-two)" ] && [ "$(index_summary "$GOT")" = "$WANT" ]; then ok "happy path: 2 platforms, index = exactly both children, output digest = tag digest"; else bad "happy path: 2 platforms"; fi

# 2. three platforms
run_join t-three "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM" "linux/arm/v7@$V7"
GOT="$(printf '%s\n' "$OUT" | sed -n 's/^digest=//p' | tail -1)"
WANT="$(printf '%s\n' "linux/amd64@$AMD" "linux/arm64@$ARM" "linux/arm/v7@$V7" | sort)"
if [ "$RC" -eq 0 ] && [ "$GOT" = "$(tag_digest t-three)" ] && [ "$(index_summary "$GOT")" = "$WANT" ]; then ok "happy path: 3 platforms incl. linux/arm/v7"; else bad "happy path: 3 platforms"; fi

# 3. one platform: allowed
run_join t-one "$REV" "linux/amd64@$AMD"
if [ "$RC" -eq 0 ] && [ "$(index_summary "$(tag_digest t-one)")" = "linux/amd64@$AMD" ]; then ok "single child allowed, index has exactly that child"; else bad "single child"; fi

# 4. arm64/v8 alias of arm64
run_join t-alias "$REV" "linux/amd64@$AMD" "linux/arm64/v8@$ARM"
expect_ok "declared linux/arm64/v8 matches arm64 image"

# 5. stale revision on one leg
run_join t-stale "$REV" "linux/amd64@$AMD" "linux/arm64@$STALE_ARM"
expect_fail "stale revision on one leg: fails, tag absent" t-stale "" "revision label does not match"
case "$OUT" in *"$STALE"*) RC=0; bad "stale revision value leaked to log";; *) ok "stale label value not echoed to log";; esac

# 6. missing digest
run_join t-missing "$REV" "linux/amd64@$AMD" "linux/arm64@$FAKE"
expect_fail "digest not in repository: fails, tag absent" t-missing "" "not found"

# 7. swapped platforms
run_join t-swap "$REV" "linux/amd64@$ARM" "linux/arm64@$AMD"
expect_fail "swapped platforms: fails, tag absent" t-swap "" "declared"

# 8. declared variant mismatch
run_join t-var "$REV" "linux/amd64@$AMD" "linux/arm/v6@$V7"
expect_fail "declared linux/arm/v6 for v7 image: fails, tag absent" t-var "" "declared"

# 9. attestation / index children
printf 'FROM scratch\nCOPY m /m\n' > "$WORK/ctx/Dockerfile"
printf 'att\n' > "$WORK/ctx/m"
docker buildx build --builder "$BUILDER" --platform linux/amd64 --label "org.opencontainers.image.revision=$REV" \
  --provenance=true --push -t "$BUILD_IMAGE:leg-att" --metadata-file "$WORK/md.json" "$WORK/ctx" >/dev/null 2>&1
ATT_INDEX="$(jq -r '."containerimage.digest"' "$WORK/md.json")"
ATT_MANIFEST="$(docker buildx imagetools inspect --raw "$HOST_IMAGE@$ATT_INDEX" | jq -r '.manifests[] | select(.platform.os == "unknown") | .digest')"
run_join t-idx "$REV" "linux/amd64@$ATT_INDEX" "linux/arm64@$ARM"
expect_fail "index digest as a child: fails, tag absent" t-idx "" "not a single-platform image"
if [[ "$ATT_MANIFEST" =~ ^sha256: ]]; then
  run_join t-att "$REV" "linux/amd64@$AMD" "linux/arm64@$ATT_MANIFEST"
  expect_fail "attestation manifest as a child: fails, tag absent" t-att "" "not a single-platform image"
else
  RC=1; OUT="no attestation manifest found in test setup"; bad "attestation manifest as a child"
fi

# 10. duplicates
run_join t-dupp "$REV" "linux/amd64@$AMD" "linux/amd64@$ARM"
expect_fail "duplicate platform: fails, tag absent" t-dupp "" "duplicate platform"
run_join t-dupd "$REV" "linux/amd64@$AMD" "linux/arm64@$AMD"
expect_fail "duplicate digest: fails, tag absent" t-dupd "" "duplicate digest"

# 11. malformed inputs
run_join 'bad;tag' "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
[ "$RC" -ne 0 ] && ok "malformed tag rejected" || bad "malformed tag rejected"
run_join t-mal "$REV" "linux/amd64@$AMD" "linux/arm64:latest"
[ "$RC" -ne 0 ] && ok "malformed child entry rejected" || bad "malformed child entry rejected"
run_join t-mal "not-a-sha" "linux/amd64@$AMD" "linux/arm64@$ARM"
[ "$RC" -ne 0 ] && ok "malformed revision rejected" || bad "malformed revision rejected"

# 12. pre-existing tag survives failures
run_join t-pre "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
OLD="$(tag_digest t-pre)"
run_join t-pre "$REV" "linux/amd64@$AMD" "linux/arm64@$STALE_ARM"
expect_fail "pre-existing tag, stale leg: fails, tag still old digest" t-pre "$OLD" "revision label does not match"
run_join t-pre "$REV" "linux/amd64@$AMD" "linux/arm64@$FAKE"
expect_fail "pre-existing tag, missing leg: fails, tag still old digest" t-pre "$OLD" "not found"
run_join t-pre "$REV" "linux/amd64@$ARM" "linux/arm64@$AMD"
expect_fail "pre-existing tag, swapped platforms: fails, tag still old digest" t-pre "$OLD" "declared"

# 13. re-run with the same children: nothing written, same digest
run_join t-pre "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"nothing written"* ]] && [ "$(tag_digest t-pre)" = "$OLD" ]; then ok "re-run with same children: no write, tag unchanged"; else bad "re-run no-op"; fi

# 14. several tags in one call resolve to one index
run_join "$(printf 't-m1\nt-m2\nt-m1\n')" "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
if [ "$RC" -eq 0 ] && [ -n "$(tag_digest t-m1)" ] && [ "$(tag_digest t-m1)" = "$(tag_digest t-m2)" ]; then ok "multi-tag: both tags, one index, duplicate tag ignored"; else bad "multi-tag"; fi

# 15. moving tag that holds other children is rewritten
run_join t-mv "$REV" "linux/amd64@$AMD"
run_join t-mv "$REV" "linux/amd64@$AMD" "linux/arm64@$ARM"
if [ "$RC" -eq 0 ] && [ "$(index_summary "$(tag_digest t-mv)")" = "$(printf '%s\n' "linux/amd64@$AMD" "linux/arm64@$ARM" | sort)" ]; then ok "moving tag with other children is moved"; else bad "moving tag"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
