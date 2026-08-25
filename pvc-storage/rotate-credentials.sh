#!/usr/bin/env bash
#
# Rotates the AWS credentials used by the EBS CSI driver.
# Reads fresh credentials from your local AWS CLI config and patches
# the kube-system/aws-secret, then restarts the controller.
#
set -euo pipefail

NAMESPACE="kube-system"

echo "==> Reading current AWS credentials..."
AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)"
AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)"

echo "==> Updating kube-system/aws-secret..."
kubectl create secret generic aws-secret \
  --namespace "$NAMESPACE" \
  --from-literal=key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=access_key="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Restarting EBS CSI controller to pick up new credentials..."
kubectl rollout restart deployment/ebs-csi-controller -n "$NAMESPACE"
kubectl rollout status deployment/ebs-csi-controller -n "$NAMESPACE" --timeout=120s

echo "Done. Controller is running with updated credentials."
