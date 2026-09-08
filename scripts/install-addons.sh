#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

# Chart versions are explicit so two installations from the same commit are
# reproducible. Change them only through a reviewed and tested upgrade.
INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-4.15.1}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.21.1}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

kubectl get nodes

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version "${INGRESS_NGINX_CHART_VERSION}" \
  --atomic \
  --wait \
  --timeout "${HELM_TIMEOUT}" \
  --values platform/ingress-nginx/values.yaml

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_CHART_VERSION}" \
  --atomic \
  --wait \
  --timeout "${HELM_TIMEOUT}" \
  --values platform/cert-manager/values.yaml

kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
