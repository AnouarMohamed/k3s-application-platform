#!/usr/bin/env bash
# Purpose: Validates Kubernetes manifests for security, stability, and project-specific best practices.
# This script is intended to be run in CI/CD pipelines or locally before applying changes.
#
# Key Checks:
# 1. Floating Tags: Ensures no images use the ':latest' tag, which is non-deterministic.
# 2. Network Policies: Blocks deprecated broad internal allow policies.
# 3. Image Digests: Verifies that production app manifests use SHA256 digests for immutability.

set -Eeuo pipefail

# Ensure we are in the repository root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

KUSTOMIZE_PATH="${KUSTOMIZE_PATH:-.}"

# Create a temporary file for the fully rendered kustomize output
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT

# Render the complete set of manifests
kubectl kustomize "${KUSTOMIZE_PATH}" > "${rendered}"

# Check 1: No floating ':latest' tags.
# Why: Using 'latest' makes deployments unpredictable as the image content can change without notice.
# It also makes rollbacks harder. We enforce specific versions or digests.
if grep -RInE 'image: .+:latest($|@)' apps "${rendered}"; then
  echo "Error: Floating latest image tag found. Use specific version tags or digests." >&2
  exit 1
fi

# Check 2: No deprecated broad internal allow policies.
# Why: The project moved to more granular network policies. Broad 'allow-apps-internal' policies
# violate the principle of least privilege.
if grep -RIn 'name: allow-apps-internal' policies "${rendered}"; then
  echo "Error: Deprecated broad namespace-wide internal allow policy found. Update network policies." >&2
  exit 1
fi

# Check 3: Mandatory image digests for every rendered workload.
# Why: checking that one digest exists is insufficient; one forgotten image tag
# would still drift. Parse both common YAML forms (`image:` and `- image:`).
mapfile -t image_refs < <(
  awk '
    $1 == "image:" { print $2 }
    $1 == "-" && $2 == "image:" { print $3 }
  ' "${rendered}" | sort -u
)

if (( ${#image_refs[@]} == 0 )); then
  echo "Error: No workload image references found in rendered manifests." >&2
  exit 1
fi

for image_ref in "${image_refs[@]}"; do
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "Error: Image is not pinned to a full SHA256 digest: ${image_ref}" >&2
    exit 1
  fi
done

if grep -nE 'image: .+:(latest|stable)(@|$)' "${rendered}"; then
  echo "Error: Floating platform image tag found in rendered manifests." >&2
  exit 1
fi

echo "Manifest check passed successfully."
