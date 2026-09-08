#!/usr/bin/env bash
# Resolve every pinned workload image against its registry. This slower network
# check complements `make check`, which intentionally remains offline-friendly.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
kubectl kustomize "${KUSTOMIZE_PATH:-.}" > "${rendered}"

mapfile -t image_refs < <(
  awk '
    $1 == "image:" { print $2 }
    $1 == "-" && $2 == "image:" { print $3 }
  ' "${rendered}" | sort -u
)

inspect_image() {
  local image_ref="$1"

  if command -v docker >/dev/null 2>&1; then
    if docker buildx version >/dev/null 2>&1; then
      docker buildx imagetools inspect "${image_ref}" >/dev/null
    else
      docker manifest inspect "${image_ref}" >/dev/null
    fi
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    podman manifest inspect "${image_ref}" >/dev/null
    return
  fi

  echo "Error: docker (with buildx or manifest support) or podman is required." >&2
  exit 1
}

for image_ref in "${image_refs[@]}"; do
  printf 'Verifying %s ... ' "${image_ref}"
  inspect_image "${image_ref}"
  printf 'ok\n'
done

echo "All pinned image references resolve in their registries."
