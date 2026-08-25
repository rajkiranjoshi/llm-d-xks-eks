# llm-d on EKS

Infrastructure manifests for deploying [llm-d](https://github.com/llm-d/llm-d) on AWS Elastic Kubernetes Service (EKS).

## Components

- **[local-storage/](local-storage/)** — Helm chart that pools instance NVMe SSDs into RAID-0 arrays on GPU worker nodes, plus a model download job for pre-caching HuggingFace models.
- **[pvc-storage/](pvc-storage/)** — Setup script and Helm values for the AWS EBS CSI driver, enabling dynamic EBS-backed PVC provisioning via the `gp2` StorageClass.
- **[monitoring/](monitoring/)** — Prometheus exporter and Grafana dashboard for EFA/RDMA network observability across GPU nodes.
- **[rbac/](rbac/)** — ClusterRoles for multi-tenant access (`llmd-user`, `llmd-admin`).
- **[user-mgmt.sh](user-mgmt.sh)** — Script to create/remove users, manage roles, and generate kubeconfigs.

## User management

`user-mgmt.sh` manages multi-tenant access to the cluster. Each user gets an isolated namespace (`<username>-dev`), a ServiceAccount, and RBAC bindings. Requires cluster-admin (or equivalent) on the target cluster.

```bash
# Add a user with the default llmd-user role
./user-mgmt.sh add alice

# Add a user with admin privileges
./user-mgmt.sh add bob --admin

# List all users and their roles
./user-mgmt.sh list

# Promote / demote admin access
./user-mgmt.sh promote alice
./user-mgmt.sh demote alice

# Temporarily revoke access (preserves namespace and resources)
./user-mgmt.sh suspend alice
./user-mgmt.sh resume alice

# Generate a standalone kubeconfig for the user
./user-mgmt.sh kubeconfig alice > ~/.kube/config.eks-alice

# Remove a user entirely
./user-mgmt.sh remove alice
```

| Role | Description |
| ---- | ----------- |
| `llmd-user` | Deploy llm-d workloads, manage related CRDs (Gateway API, GAIE, LeaderWorkerSet), and use cluster-scoped RBAC needed by Helm charts |
| `llmd-admin` | Full cluster-admin privileges |

User namespaces are labeled with `pod-security.kubernetes.io/enforce=privileged` to allow GPU and RDMA workloads that require `IPC_LOCK` and `hostPath` volumes.
