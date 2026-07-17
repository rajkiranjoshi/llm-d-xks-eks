# llm-d on EKS

Infrastructure manifests for deploying [llm-d](https://github.com/llm-d/llm-d) on AWS Elastic Kubernetes Service (EKS).

## Components

- **[local-storage/](local-storage/)** — Helm chart that pools instance NVMe SSDs into RAID-0 arrays on GPU worker nodes, plus a model download job for pre-caching HuggingFace models.
- **[monitoring/](monitoring/)** — Prometheus exporter and Grafana dashboard for EFA/RDMA network observability across GPU nodes.
