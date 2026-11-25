#!/usr/bin/env bash
# Joins single-platform image manifests (by digest) into one index and writes it to every tag in JOIN_TAGS.
# Env: JOIN_IMAGE JOIN_TAGS JOIN_CHILDREN JOIN_REVISION. Output: digest -> $GITHUB_OUTPUT (if set) and stdout.
# Nothing is written to the registry until every check passes. Tags that already hold exactly these children are left alone.
set -euo pipefail

fail() { echo "::error::join: $*" >&2; exit 1; }

DIGEST_RE='^sha256:[0-9a-f]{64}$'
CHILD_RE='^([a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?)@(sha256:[0-9a-f]{64})$'
IMAGE_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
REV_RE='^[0-9a-f]{40,64}$'

: "${JOIN_IMAGE:?}" "${JOIN_TAGS:?}" "${JOIN_CHILDREN:?}" "${JOIN_REVISION:?}"
[[ "$JOIN_IMAGE" =~ $IMAGE_RE ]] || fail "image is not a bare repository reference"
tags=()
while IFS= read -r t; do
  t="${t//[$'\t\r ']/}"
  [ -z "$t" ] && continue
  [[ "$t" =~ $TAG_RE ]] || fail "tag is malformed"
  for x in "${tags[@]}"; do [ "$x" = "$t" ] && continue 2; done
  tags+=("$t")
done <<< "$JOIN_TAGS"
[ "${#tags[@]}" -ge 1 ] || fail "no tags"
[[ "$JOIN_REVISION" =~ $REV_RE ]] || fail "revision is not a lowercase hex commit id"

normalize() { # arm64/v8 == arm64, amd64/v1 == amd64
  local p="$1"
  case "$p" in
    */arm64/v8) p="${p%/v8}" ;;
    */amd64/v1) p="${p%/v1}" ;;
  esac
  printf '%s' "$p"
}

platforms=()
digests=()
while IFS= read -r line; do
  line="${line//[$'\t\r ']/}"
  [ -z "$line" ] && continue
  [[ "$line" =~ $CHILD_RE ]] || fail "child entry malformed (want os/arch[/variant]@sha256:<64 hex>)"
  p="$(normalize "${BASH_REMATCH[1]}")"
  d="${BASH_REMATCH[3]}"
  for i in "${!platforms[@]}"; do
    [ "${platforms[$i]}" = "$p" ] && fail "duplicate platform $p"
    [ "${digests[$i]}" = "$d" ] && fail "duplicate digest $d"
  done
  platforms+=("$p")
  digests+=("$d")
done <<< "$JOIN_CHILDREN"
[ "${#platforms[@]}" -ge 1 ] || fail "no children"

for i in "${!platforms[@]}"; do
  p="${platforms[$i]}" d="${digests[$i]}" ref="$JOIN_IMAGE@${digests[$i]}"
  raw="$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null)" || fail "$p: $d not found in image repository"
  jq -e '(has("manifests") | not) and (.config != null) and ((.layers // []) | all(.mediaType != "application/vnd.in-toto+json"))' <<< "$raw" >/dev/null \
    || fail "$p: $d is an index or attestation manifest, not a single-platform image"
  cfg="$(docker buildx imagetools inspect "$ref" --format '{{json .Image}}' 2>/dev/null)" || fail "$p: cannot read config of $d"
  actual="$(jq -r '[.os, .architecture, (.variant // empty)] | join("/")' <<< "$cfg")"
  actual="$(normalize "$actual")"
  [ "$actual" = "$p" ] || fail "$p: $d has platform $(printf '%s' "$actual" | tr -cd 'a-z0-9/') (declared $p)"
  rev="$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' <<< "$cfg")"
  [ "$rev" = "$JOIN_REVISION" ] || fail "$p: $d revision label does not match expected revision"
done

declared="$(for i in "${!platforms[@]}"; do printf '%s@%s\n' "${platforms[$i]}" "${digests[$i]}"; done | sort | jq -R . | jq -sc .)"
index_set='[.manifests[] | ((.platform.os + "/" + .platform.architecture + (if .platform.variant then "/" + .platform.variant else "" end)
  | if endswith("/arm64/v8") or endswith("/amd64/v1") then sub("/v[0-9]+$"; "") else . end) + "@" + .digest)] | sort'

sources=()
for i in "${!digests[@]}"; do sources+=("$JOIN_IMAGE@${digests[$i]}"); done

# Re-run guard: a tag that already holds an index with exactly these children is kept as is.
pending=() kept=""
for t in "${tags[@]}"; do
  cur="$(docker buildx imagetools inspect --raw "$JOIN_IMAGE:$t" 2>/dev/null)" || { pending+=("$t"); continue; }
  if jq -e --argjson want "$declared" "has(\"manifests\") and (($index_set) == \$want)" <<< "$cur" >/dev/null; then
    d="$(docker buildx imagetools inspect "$JOIN_IMAGE:$t" --format '{{json .Manifest}}' | jq -r '.digest')"
    [ -z "$kept" ] || [ "$kept" = "$d" ] || { pending+=("$t"); continue; }
    kept="$d"
  else
    pending+=("$t")
  fi
done

if [ "${#pending[@]}" -eq 0 ]; then
  echo "all ${#tags[@]} tags already hold index $kept with these children; nothing written"
  index="$kept"
else
  targets=()
  for t in "${pending[@]}"; do targets+=(--tag "$JOIN_IMAGE:$t"); done

  dry="$(docker buildx imagetools create --dry-run "${targets[@]}" "${sources[@]}" 2>/dev/null)" || fail "dry-run index creation failed"
  jq -e --argjson want "$declared" "($index_set) == \$want" <<< "$dry" >/dev/null || fail "dry-run index does not contain exactly the declared children"

  meta="$(mktemp)"
  trap 'rm -f "$meta"' EXIT
  docker buildx imagetools create --metadata-file "$meta" "${targets[@]}" "${sources[@]}" >/dev/null 2>&1 \
    || fail "index publish failed: a tag in this set may be immutable and hold other content, or the role cannot push"
  index="$(jq -er '."containerimage.descriptor".digest' "$meta")"
  [[ "$index" =~ $DIGEST_RE ]] || fail "publish returned no index digest"

  post="$(docker buildx imagetools inspect --raw "$JOIN_IMAGE@$index" 2>/dev/null)" || fail "published index not readable"
  jq -e --argjson want "$declared" "($index_set) == \$want" <<< "$post" >/dev/null || fail "published index does not contain exactly the declared children"
  [ -z "$kept" ] || [ "$kept" = "$index" ] || echo "::warning::join: kept tags hold $kept, new tags hold $index (same children, different index bytes)"
fi

for t in "${tags[@]}"; do
  tagged="$(docker buildx imagetools inspect "$JOIN_IMAGE:$t" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest')"
  [ "$tagged" = "$index" ] || [ "$tagged" = "$kept" ] || fail "tag $t does not resolve to the published index"
done

echo "index $index with ${#digests[@]} children on ${#tags[@]} tags (${#pending[@]} written)"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'digest=%s\n' "$index" >> "$GITHUB_OUTPUT"
printf 'digest=%s\n' "$index"
