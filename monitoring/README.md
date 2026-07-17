# Monitoring (EKS / EFA)

## Hardware note

| Platform | NICs per GPU node | Device names (typical) |
| --- | --- | --- |
| AKS (previous) | **8×** NVIDIA ConnectX-7 | `mlx5_0` … `mlx5_7` |
| EKS p5.48xlarge | **32×** AWS Elastic Fabric Adapter | `rdmap*` |

Dashboard variables and “devices present” counts should be judged against **32** on EKS, not the old 8-HCA AKS layout.

## EFA metrics

On AKS this directory scraped DOCA Telemetry (`doca-telemetry-rdma`). On EKS, EFA NIC counters come from sysfs:

```text
/sys/class/infiniband/<device>/ports/<port>/hw_counters/*
```

See [Monitor an Elastic Fabric Adapter](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-working-monitor.html).

The `llmd` kube-prometheus-stack node-exporter DaemonSet is overridden to use AWS’s EFA-patched image (`public.ecr.aws/hpc-cloud/efa-node-exporter`), which exposes `node_amazonefa_*` on the existing `:9100` scrape. Configure via [prometheus-stack-values.yaml](prometheus-stack-values.yaml):

```bash
helm upgrade llmd prometheus-community/kube-prometheus-stack \
  -n llm-d-monitoring \
  -f monitoring/prometheus-stack-values.yaml
```

Verify on a GPU/EFA node:

```bash
curl -s http://<node-ip>:9100/metrics | grep node_amazonefa
```

## Dashboard (Grafana sidecar ConfigMap)

Grafana in `llm-d-monitoring` is the `llmd` kube-prometheus-stack chart with the **dashboard sidecar** enabled (`grafana.sidecar.dashboards.enabled: true`, `searchNamespace: ALL`). The sidecar watches ConfigMaps (and Secrets) labeled `grafana_dashboard: "1"`, writes their `.json` keys under `/tmp/dashboards`, and Grafana provisions them on a short interval (default ~30s). Manual UI import is not required.

### Files

| File | Role |
| --- | --- |
| [efa-rdma-network-dashboard.json](efa-rdma-network-dashboard.json) | Source dashboard JSON (edit this) |
| [efa-rdma-network-dashboard-configmap.yaml](efa-rdma-network-dashboard-configmap.yaml) | Kubernetes ConfigMap that wraps the JSON for the sidecar |

Dashboard title: **RDMA Network — EFA Traffic** (`uid: efa-rdma-device-traffic`).

Per-node TX vs RX uses **Node A** / **Node B** dropdowns (not “All”). On load they default to the first and second `instance` values (alphabetical): Node B’s query excludes Node A, so this stays “first two” on any cluster size. Change either dropdown to compare a different pair.

### Apply / update

```bash
# Apply (or re-apply after editing the ConfigMap YAML)
kubectl apply -f monitoring/efa-rdma-network-dashboard-configmap.yaml
```

Within about 30 seconds the sidecar reloads and the dashboard appears in Grafana. Confirm:

```bash
kubectl get configmap -A -l grafana_dashboard=1 | grep efa-rdma
# Optional: Grafana API (admin password from helm values)
kubectl exec -n llm-d-monitoring deploy/llmd-grafana -c grafana -- \
  curl -s -u admin:$GRAFANA_ADMIN_PASSWORD \
  'http://localhost:3000/api/dashboards/uid/efa-rdma-device-traffic' | head
```

### Regenerate the ConfigMap from the JSON

After editing `efa-rdma-network-dashboard.json`, rebuild the tracked ConfigMap (label is required):

```bash
kubectl create configmap efa-rdma-network-dashboard \
  -n llm-d-monitoring \
  --from-file=efa-rdma-network-dashboard.json=monitoring/efa-rdma-network-dashboard.json \
  --dry-run=client -o yaml \
| sed '/^metadata:/a\  labels:\n    grafana_dashboard: "1"' \
> monitoring/efa-rdma-network-dashboard-configmap.yaml

kubectl apply -f monitoring/efa-rdma-network-dashboard-configmap.yaml
```

Requirements for the sidecar to pick it up:

- Label `grafana_dashboard: "1"` on the ConfigMap
- Data key ending in `.json` (e.g. `efa-rdma-network-dashboard.json`)
- Namespace searchable by the sidecar (`searchNamespace: ALL` is already set on this stack)

### Metric mapping (DOCA → EFA)

| DOCA (old) | EFA (new) |
| --- | --- |
| `port_xmit_data` / `port_rcv_data` | `node_amazonefa_tx_bytes` / `node_amazonefa_rx_bytes` |
| `port_xmit_packets` / `port_rcv_packets` | `node_amazonefa_tx_pkts` / `node_amazonefa_rx_pkts` |
| `hca` / `source` labels | `device` / `instance` |
| IB port state | `node_amazonefa_info` (device present) |

Also includes EFA send/recv bandwidth panels (`node_amazonefa_{send,recv}_bytes`), with `rdma_read` / `rdma_write` overlaid. On this stack, bulk traffic typically lands on **send/recv** (and matches TX/RX); the RDMA READ/WRITE verb counters often stay near zero unless the application issues those verbs.

### Link state (LinkUp)

`node_amazonefa_info` only means the device is **present**. Physical **LinkUp** comes from sysfs:

```text
/sys/class/infiniband/<device>/ports/<port>/phys_state   # 5: LinkUp
/sys/class/infiniband/<device>/ports/<port>/state        # 4: ACTIVE
```

Those are not emitted by the EFA node-exporter image (state metrics are commented out) and the stock InfiniBand collector fails on EFA nodes. Deploy [efa-link-state-exporter.yaml](efa-link-state-exporter.yaml) for:

- `node_efa_port_phys_state{device,port,phys_state}` — LinkUp / Sleep / …
- `node_efa_port_state{device,port,state}` — ACTIVE / DOWN / …

```bash
kubectl apply -f monitoring/efa-link-state-exporter.yaml
```

### Error / impairment counters

| Metric | Meaning |
| --- | --- |
| `node_amazonefa_rx_drops` | Packets dropped on the **local** EFA RX path |
| `node_amazonefa_retrans_pkts` / `_bytes` | EFA SRD **retransmissions** (path loss/congestion recovered) |
| `node_amazonefa_retrans_timeout_events` | Retransmit **timed out** → path change (more serious than a recovered retransmit) |
| `unresponsive_remote_events` / `impaired_remote_conn_events` | Remote endpoint unhealthy / impaired |

Path loss recovered by SRD often shows **retrans_*** rising while **rx_drops stays 0** (drops are not counted on the receiving NIC). Dashboard error stats use Grafana **range queries** with the **diff** reducer (last−first over the selected window) so short bursts are not missed by an instant `rate()`/`increase([$__range])` evaluated at the end of a short window (Prometheus range selectors are left-open).
