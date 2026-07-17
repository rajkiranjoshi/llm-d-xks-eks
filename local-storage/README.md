# Local NVMe Storage

Helm chart that pools instance NVMe SSDs into a single RAID-0 array on each GPU
worker node, providing high-throughput local storage for model weights.

Designed for EKS clusters with instances that have multiple NVMe instance store
volumes (e.g. p5.48xlarge with 8× 3.5 TB NVMe drives).

## What it does

A privileged DaemonSet runs on every node matching the configured `nodeSelector`
and:

1. Discovers all unpartitioned, unmounted NVMe disks (skips the boot volume and
   any AMI-auto-mounted drives like `/mnt/scratch`).
2. Creates a RAID-0 (`md0`) array across them, or re-assembles an existing one.
3. Formats the array with XFS and mounts it at the configured `mountPath`.
4. Creates a `models/` subdirectory for HuggingFace model cache.

On subsequent restarts the DaemonSet detects the existing array and skips
creation.

## Deployment

```bash
helm install local-nvme-storage ./local-storage -n kube-system
```

Override values as needed:

```bash
helm install local-nvme-storage ./local-storage -n kube-system \
  --set mountPath=/mnt/nvme \
  --set nodeSelector.role=gpu
```

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `mountPath` | `/mnt/nvme` | Host path where the RAID array is mounted |
| `nodeSelector` | `role: gpu` | Node selector for the DaemonSet |
| `tolerations` | nvidia.com/gpu NoSchedule | Tolerations for GPU node taints |

## Model download job

`model-download-job.yaml` is a standalone Job (not part of the Helm chart) that
downloads HuggingFace models onto the RAID storage. It runs one pod per GPU node
using pod anti-affinity so each node gets a local copy of all models.

Prerequisites:
- The RAID must be mounted (deploy the Helm chart first).
- A Kubernetes secret `hf-secret` with your HuggingFace token:

```bash
kubectl create secret generic hf-secret \
  --from-literal=HF_TOKEN=<your-token>
```

Run the job:

```bash
kubectl apply -f local-storage/model-download-job.yaml
```

## Serving pods

Mount the model cache in your vLLM or inference pods via `hostPath`:

```yaml
volumes:
  - name: model-cache
    hostPath:
      path: /mnt/nvme/models
      type: Directory
```
