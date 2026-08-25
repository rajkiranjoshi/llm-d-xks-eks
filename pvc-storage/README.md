# PVC Storage (EBS CSI Driver)

Installs the [AWS EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
via its upstream Helm chart, enabling dynamic provisioning of EBS-backed
PersistentVolumeClaims through the `gp2` StorageClass.

## Background

Since Kubernetes 1.23 the in-tree `kubernetes.io/aws-ebs` provisioner has been
migrated to the out-of-tree CSI driver (`ebs.csi.aws.com`). Without the driver
installed, PVCs using the `gp2` StorageClass stay in `Pending` indefinitely.

## For users

The cluster provides a `gp2` StorageClass backed by AWS EBS. Use it whenever
your workload needs persistent storage — for example, storing benchmark results
so a second pod can retrieve them after the first completes.

### Creating a PVC

Add a PVC to your namespace and reference it from your pod:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-results
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp2
  resources:
    requests:
      storage: 10Gi          # adjust as needed
```

Mount it in your pod (or Job):

```yaml
spec:
  containers:
    - name: app
      volumeMounts:
        - mountPath: /data
          name: results
  volumes:
    - name: results
      persistentVolumeClaim:
        claimName: my-results
```

### Things to know

- **PVC stays `Pending` until a pod uses it** — the `gp2` StorageClass uses
  `WaitForFirstConsumer` binding mode, so the volume is only provisioned once
  a pod referencing the PVC is scheduled to a node. This is normal.
- **Access mode is `ReadWriteOnce`** — the EBS volume can be mounted by one
  node at a time. If you need a second pod to read the data, make sure the
  first pod has finished and released the volume, or schedule both pods on the
  same node.
- **Clean up when done** — EBS volumes cost money while they exist.
  Delete PVCs you no longer need: `kubectl delete pvc <name>`.

### GPU node pods

If your pod needs to run on a GPU node, add the toleration so it can be
scheduled there:

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

---

## Admin guide

Everything below is for cluster administrators setting up or maintaining the
EBS CSI driver.

## Prerequisites

- `helm`, `kubectl`, `aws` CLI installed
- `KUBECONFIG` pointing at the target EKS cluster
- AWS credentials configured (`aws configure`) with EC2/EBS permissions

Required IAM permissions:

| Action | Purpose |
|---|---|
| `ec2:CreateVolume`, `ec2:DeleteVolume` | Provision / clean up EBS volumes |
| `ec2:AttachVolume`, `ec2:DetachVolume` | Attach volumes to nodes |
| `ec2:DescribeVolumes`, `ec2:DescribeInstances`, `ec2:DescribeAvailabilityZones` | Driver discovery |
| `ec2:CreateTags`, `ec2:DeleteTags` | Tag volumes with PVC metadata |
| `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:DescribeSnapshots` | Snapshot support |
| `ec2:ModifyInstanceMetadataOptions` | IMDS hop limit fix (setup only) |

## Quick start

```bash
export KUBECONFIG=~/.kube/config.eks

# Install the EBS CSI driver
./pvc-storage/setup.sh

# Verify with a test PVC + pod
kubectl apply -f pvc-storage/test-pvc.yaml
kubectl get pvc ebs-test-pvc          # should become Bound
kubectl logs ebs-test-pod             # should print "EBS volume works!"
kubectl delete -f pvc-storage/test-pvc.yaml
```

## What the setup script does

1. **IMDS hop limit** — Checks all nodes and bumps `HttpPutResponseHopLimit`
   from 1 to 2 where needed. EKS defaults to 1 which blocks pods from
   reaching the Instance Metadata Service; the CSI controller needs IMDS to
   resolve its region and availability zone.

2. **Helm repo** — Adds the upstream `aws-ebs-csi-driver` chart repo.

3. **AWS credentials secret** — Reads `aws_access_key_id` /
   `aws_secret_access_key` from your local AWS CLI config and creates (or
   updates) a `kube-system/aws-secret` Kubernetes Secret. Both the controller
   and node DaemonSet pods mount this secret via environment variables.

4. **Helm install** — Installs (or upgrades) the chart with
   `pvc-storage/values.yaml` and waits for the controller rollout.

## Credential rotation

When your AWS access key is rotated, update the cluster:

```bash
./pvc-storage/rotate-credentials.sh
```

This patches the `aws-secret` and restarts the controller pods.

## Uninstall

```bash
./pvc-storage/setup.sh --uninstall
```

## Files

| File | Description |
|---|---|
| `setup.sh` | Install / upgrade / uninstall the EBS CSI driver |
| `rotate-credentials.sh` | Rotate the AWS credentials secret |
| `values.yaml` | Helm values for the EBS CSI driver chart |
| `test-pvc.yaml` | Smoke-test PVC and pod |

## Future improvement: migrate to EKS Pod Identity

The static-credentials approach works but requires periodic rotation. The
recommended upgrade is to switch to
[EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
with a dedicated IAM role — the `eks-pod-identity-agent` is already installed
on this cluster.

### Required IAM permissions

The IAM user performing the migration needs:

| Permission | Purpose |
|---|---|
| `iam:CreateRole` | Create a dedicated role for the driver |
| `iam:AttachRolePolicy` | Attach `AmazonEBSCSIDriverPolicy` to the role |
| `eks:CreatePodIdentityAssociation` | Map the role to the driver's service account |

### Migration steps

```bash
CLUSTER_NAME=eks-ore
REGION=us-west-2
ROLE_NAME=EBS-CSI-Driver-Role

# 1. Create an IAM role with the Pod Identity trust policy
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "pods.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'

# 2. Attach the AWS-managed EBS CSI policy
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# 3. Associate the role with the controller service account
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text)

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --namespace kube-system \
  --service-account ebs-csi-controller-sa \
  --role-arn "$ROLE_ARN"

# 4. Remove the static credentials and restart the controller
kubectl delete secret aws-secret -n kube-system
kubectl rollout restart deployment/ebs-csi-controller -n kube-system
kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=120s

# 5. Verify — existing PVCs should continue working, new ones should provision
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

After migrating, the `controller.env` and `node.env` secret references in
`values.yaml` can be removed on the next `helm upgrade`.
