#!/usr/bin/env bash
#
# Installs the AWS EBS CSI driver on an EKS cluster so that the gp2
# StorageClass can dynamically provision EBS-backed PersistentVolumeClaims.
#
# Prerequisites:
#   - helm, kubectl, aws CLI installed
#   - KUBECONFIG pointing at the target cluster
#   - AWS credentials configured (aws configure) with EC2/EBS permissions
#
# Usage:
#   ./setup.sh                    # install / upgrade
#   ./setup.sh --uninstall        # remove the driver
#
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NAMESPACE="kube-system"
RELEASE_NAME="aws-ebs-csi-driver"
CHART_REPO="https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Uninstall path ──────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> Uninstalling EBS CSI driver..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete secret aws-secret -n "$NAMESPACE" 2>/dev/null || true
  echo "Done."
  exit 0
fi

# ── Pre-flight checks ──────────────────────────────────────────────
echo "==> Checking prerequisites..."
for cmd in helm kubectl aws; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd is not installed" >&2; exit 1; }
done
kubectl cluster-info &>/dev/null || { echo "ERROR: cannot reach cluster" >&2; exit 1; }

# ── Bump IMDS hop limit on all nodes ──────────────────────────────
# EKS defaults HttpPutResponseHopLimit to 1, which blocks pods from
# reaching the Instance Metadata Service. The EBS CSI controller needs
# IMDS access to discover its region and AZ when not using IRSA/Pod
# Identity, so we raise the limit to 2.
echo "==> Ensuring IMDS hop limit is 2 on all nodes..."
for INSTANCE_ID in $(kubectl get nodes -o json \
    | jq -r '.items[].spec.providerID' | sed 's|.*/||'); do
  HOP_LIMIT=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' \
    --output text 2>/dev/null)
  if [[ "$HOP_LIMIT" -lt 2 ]]; then
    echo "    Updating $INSTANCE_ID (was $HOP_LIMIT)..."
    aws ec2 modify-instance-metadata-options \
      --instance-id "$INSTANCE_ID" \
      --http-put-response-hop-limit 2 \
      --region "$REGION" --output text &>/dev/null
  fi
done

# ── Helm repo ─────────────────────────────────────────────────────
echo "==> Adding Helm repo..."
helm repo add aws-ebs-csi-driver "$CHART_REPO" 2>/dev/null || true
helm repo update aws-ebs-csi-driver

# ── AWS credentials secret ────────────────────────────────────────
echo "==> Creating AWS credentials secret in $NAMESPACE..."
AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)"
AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)"

kubectl create secret generic aws-secret \
  --namespace "$NAMESPACE" \
  --from-literal=key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Install / upgrade ────────────────────────────────────────────
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
  ACTION="upgrade"
else
  ACTION="install"
fi

echo "==> Helm $ACTION $RELEASE_NAME..."
helm "$ACTION" "$RELEASE_NAME" aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace "$NAMESPACE" \
  -f "$SCRIPT_DIR/values.yaml"

echo "==> Waiting for controller rollout..."
kubectl rollout status deployment/ebs-csi-controller \
  -n "$NAMESPACE" --timeout=120s

echo ""
echo "==> EBS CSI driver pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aws-ebs-csi-driver -o wide

echo ""
echo "Done. The gp2 StorageClass can now provision EBS volumes."
echo "Verify with:  kubectl apply -f $SCRIPT_DIR/test-pvc.yaml"
