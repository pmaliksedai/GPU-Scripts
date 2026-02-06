# GKE Node Pool MIG Setup Script Documentation

## Overview

This document describes the automated script for setting up Multi-Instance GPU (MIG) enabled node pools in Google Kubernetes Engine (GKE). The script automatically discovers existing GPU node pools and creates MIG-enabled replicas with all original configurations preserved.

## Script Features

### Automatic Discovery
- Lists all GPU node pools in a GKE cluster using advanced filtering
- Supports multiple GPU types: A100, A30, H100, L40S
- Filters for active GPU node pools only

### Configuration Preservation
The script automatically extracts and preserves all original node pool configurations:
- Machine type and hardware specifications
- Image type and disk configuration
- Service account and OAuth scopes
- Autoscaling settings (if enabled)
- Management settings (auto-repair, auto-upgrade)
- Pod constraints and node locations
- GPU accelerator type and count

### MIG Configuration
- Adds MIG-specific labels: `nvidia.com/mig.config=mixed`
- Applies custom GPU class labels: `workload.gke.io/gpu-class=<user-defined>`
- Sets appropriate node taints for GPU workloads

## Prerequisites

### Required Tools
- `gcloud` CLI configured with appropriate permissions
- `kubectl` configured to access the target cluster
- `helm` (for GPU Operator installation)

### Required Permissions
- Container Developer or Kubernetes Engine Developer role
- Permissions to create and manage node pools
- Access to install cluster-wide resources (GPU Operator)

## Usage

### Basic Execution
```bash
./gke-nodepool-mig-setup.sh <CLUSTER_NAME> <REGION> <GPU_CLASS>
```

### Parameters
- `CLUSTER_NAME`: Name of the GKE cluster
- `REGION`: GCP region where the cluster is located
- `GPU_CLASS`: Unique identifier for the GPU class (e.g., "mig-dra")

### Example
```bash
./gke-nodepool-mig-setup.sh sedai-gpu-cluster us-central1 mig-dra
```

## Script Workflow

### Step 1: Discovery and Listing
```bash
gcloud container node-pools list \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --filter="config.accelerators:* AND (config.accelerators.acceleratorType~nvidia-tesla-a100 OR config.accelerators.acceleratorType~nvidia-tesla-a30 OR config.accelerators.acceleratorType~nvidia-h100 OR config.accelerators.acceleratorType~nvidia-l40s)"
```

### Step 2: Configuration Extraction
For each discovered node pool, the script extracts:
- Hardware configuration (machine type, disk, image)
- Security settings (service account, OAuth scopes)
- Scaling and management policies
- GPU specifications
- Network and location settings

### Step 3: MIG-Enabled Pool Creation
Creates new node pools with naming convention: `<original-name>-mig-enabled`

Example command structure:
```bash
gcloud container node-pools create "gpu-pool-2g-mig-enabled" \
  --cluster="sedai-gpu-cluster" \
  --region="us-central1" \
  --machine-type="a2-highgpu-2g" \
  --accelerator type="nvidia-tesla-a100",count="2" \
  --node-labels nvidia.com/mig.config=mixed,workload.gke.io/gpu-class="mig-dra" \
  --node-taints nvidia.com/gpu=present:NoSchedule \
  [... all other preserved configurations ...]
```

### Step 4: Verification
- Compares new pool configuration with original
- Verifies MIG-enabled nodes are created
- Checks node labels and taints

### Step 5: GPU Operator Installation
Optionally installs NVIDIA GPU Operator with DRA support:
```bash
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set mig.strategy=mixed \
  --set devicePlugin.enabled=false \
  --set dra.enabled=true
```

### Step 6: ResourceClass Creation
Creates Kubernetes ResourceClass objects for different MIG profiles:
- `nvidia-a100-mig-1g-10gb` (1g.10gb profile)
- `nvidia-a100-mig-2g-10gb` (2g.10gb profile)  
- `nvidia-a100-mig-3g-40gb` (3g.40gb profile)

## Output Files

The script generates several configuration files:

### Per Node Pool
- `old-nodepool-<pool-name>.yaml`: Original pool configuration
- `new-nodepool-<pool-name>-mig-enabled.yaml`: New MIG pool configuration

### ResourceClasses
- `nvidia-a100-mig-1g-10gb.yaml`
- `nvidia-a100-mig-2g-10gb.yaml`
- `nvidia-a100-mig-3g-40gb.yaml`

## Configuration Details

### Node Labels Applied
```yaml
nvidia.com/mig.config: mixed
workload.gke.io/gpu-class: <user-defined>
```

### Node Taints Applied
```yaml
nvidia.com/gpu: present:NoSchedule
```

### Supported GPU Types
- nvidia-tesla-a100
- nvidia-tesla-a30
- nvidia-h100
- nvidia-l40s

## Troubleshooting

### Common Issues

#### Empty Node Count Error
**Error**: `invalid int value: ''`
**Solution**: Script automatically defaults NUM_NODES to 1 if not specified

#### OAuth Scope Format Error
**Error**: `Scope does not exist`
**Solution**: Script converts semicolon-separated scopes to comma-separated format

#### Invalid Label Format
**Error**: `Invalid field 'resource_labels.key'`
**Solution**: Uses `--node-labels` instead of `--labels` for Kubernetes-style labels

### Verification Commands

Check MIG-enabled nodes:
```bash
kubectl get nodes -l workload.gke.io/gpu-class=<GPU_CLASS> -L nvidia.com/mig.config
```

Debug node GPU configuration:
```bash
kubectl debug node/<NODE_NAME> -it --image=busybox
nvidia-smi -L
```

Verify GPU Operator:
```bash
kubectl get pods -n gpu-operator
```

## Best Practices

### Planning
- Review existing node pool configurations before running
- Plan for workload migration from original to MIG-enabled pools
- Consider resource quotas and cluster capacity

### Execution
- Run during maintenance windows
- Monitor node creation progress
- Verify MIG device availability before workload deployment

### Post-Deployment
- Test MIG functionality with sample workloads
- Update deployment manifests to use ResourceClasses
- Monitor resource utilization and scaling behavior

## Security Considerations

- Script preserves original OAuth scopes and service accounts
- Node taints prevent non-GPU workloads from scheduling
- ResourceClasses provide controlled access to MIG resources

## Limitations

- Requires manual workload migration to new pools
- GPU Operator installation is cluster-wide (one-time setup)
- MIG configuration is fixed at pool creation time
- Script assumes standard GKE node pool configurations

## Support and Maintenance

- Keep gcloud CLI updated for latest GKE features
- Monitor NVIDIA GPU Operator releases for updates
- Review GKE release notes for MIG-related changes
- Validate script compatibility with new GPU types as they become available