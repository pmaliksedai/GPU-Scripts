# GKE Node Pool MIG Setup Script Documentation

## Overview

This document describes the enhanced automated script for setting up Multi-Instance GPU (MIG) enabled node pools in Google Kubernetes Engine (GKE). The script automatically discovers existing GPU node pools and creates **three MIG-enabled node pools per original pool**, each with different MIG partition sizes (1g.5gb, 2g.10gb, 3g.20gb), preserves all original configurations, and sets up Dynamic Resource Allocation (DRA) driver support.

## Script Features

### Automatic Discovery
- Lists all GPU node pools in a GKE cluster using advanced filtering
- Supports multiple GPU types: A100, A30, H100, L40S
- Filters for active GPU node pools only
- Checks node counts and skips empty pools
- Prevents duplicate MIG-enabled pool creation
- Intelligently skips pools with MIG naming patterns (-mig-1g-, -mig-2g-, -mig-3g-)

### Configuration Preservation
The script automatically extracts and preserves all original node pool configurations:
- Machine type and hardware specifications
- Image type and disk configuration
- Service account and OAuth scopes
- **Enhanced autoscaling**: Always enables autoscaling with smart defaults
  - If original had autoscaling: preserves min/max values
  - If original was fixed size: enables autoscaling with min=1, max=original_node_count
- **Zero initial nodes**: All pools start with 0 nodes for cost optimization
- Management settings (auto-repair, auto-upgrade)
- Pod constraints and node locations
- **GPU accelerator configuration**: type, count, and gpu-driver-version
- **Security settings**: Shielded VMs with integrity monitoring, secure boot disabled
- Node locations and zone distribution

### MIG Configuration
- **Three partition sizes per original pool**: Creates separate node pools for 1g.5gb, 2g.10gb, and 3g.20gb MIG instances
- **Enhanced naming convention**: `<original-name>-mig-1g-5gb`, `<original-name>-mig-2g-10gb`, `<original-name>-mig-3g-20gb`
- **GPU partition size parameter**: Uses `gpu-partition-size` in accelerator configuration
- Adds MIG-specific labels: `nvidia.com/mig.config=mixed`
- **Custom node affinity labels**: `sedai.nodepool.affinity=<pool-name>` for precise workload placement
- Sets appropriate node taints for GPU workloads: `nvidia.com/gpu=present:NoSchedule`
- Automatically truncates pool names to meet 40-character limit

### DRA Driver Support
- **GPU Operator configuration management removed**: Script no longer modifies clusterpolicy
- Checks for Dynamic Resource Allocation (DRA) support in the cluster
- **Enhanced DRA installation**: Uses `helm upgrade -i` with external configuration file
- **Version updated**: Now installs DRA driver v25.8.1
- **Configuration file based**: Uses `dra-driver-gcp.yaml` for all DRA settings
- **Idempotent installation**: Supports multiple runs safely

## Prerequisites

### Required Tools
- `gcloud` CLI configured with appropriate permissions
- `kubectl` configured to access the target cluster
- `helm` (for DRA driver installation)

### Required Files
- **`dra-driver-gcp.yaml`**: DRA driver configuration file (must be in script directory)

### Required Permissions
- Container Developer or Kubernetes Engine Developer role
- Permissions to create and manage node pools
- Access to install cluster-wide resources (DRA driver)
- Helm repository access for NVIDIA charts

## Usage

### Basic Execution
```bash
./gke-nodepool-mig-setup.sh <CLUSTER_NAME> <REGION>
```

### Parameters
- `CLUSTER_NAME`: Name of the GKE cluster
- `REGION`: GCP region where the cluster is located

### Example
```bash
./gke-nodepool-mig-setup.sh sedai-gpu-cluster us-central1
```

## Script Workflow

### Step 1: GPU Operator Configuration (Removed)
- **Note**: GPU Operator clusterpolicy modification has been removed from the script
- Users must ensure GPU Operator is properly configured externally

### Step 2: Discovery and Node Count Analysis
```bash
# Lists GPU node pools with filtering
gcloud container node-pools list \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --filter="config.accelerators:* AND (config.accelerators.acceleratorType~nvidia-tesla-a100 OR config.accelerators.acceleratorType~nvidia-tesla-a30 OR config.accelerators.acceleratorType~nvidia-h100 OR config.accelerators.acceleratorType~nvidia-l40s)"

# Checks node counts and reports warnings for empty pools
```

### Step 3: Smart Pool Processing
For each discovered node pool, the script:
- Skips pools already MIG-enabled (containing "-mig-1g-", "-mig-2g-", "-mig-3g-", or "-mig-enabled")
- Skips pools with 0 nodes
- **Creates three MIG partition pools**: 1g.5gb, 2g.10gb, and 3g.20gb
- Prevents duplicate creation by checking if specific partition pools already exist
- Extracts complete configuration from original pool once, applies to all partitions

### Step 4: Configuration Extraction and Validation
The script preserves all settings including:
- Hardware configuration (machine type, disk, image)
- Security settings (service account, OAuth scopes, shielded VMs)
- **Enhanced scaling policies**: Always enables autoscaling with smart defaults, starts with 0 nodes
- **Complete GPU specifications**: accelerator type, count, and gpu-driver-version mapping
- Network settings and node locations
- Pod constraints and resource limits

### Step 5: MIG-Enabled Pool Creation (Per Partition)
Creates **three node pools per original pool** with partition-specific naming:
- **1g.5gb partition**: `<original-name>-mig-1g-5gb`
- **2g.10gb partition**: `<original-name>-mig-2g-10gb`  
- **3g.20gb partition**: `<original-name>-mig-3g-20gb`
- Automatically truncates names exceeding 40-character limit
- Sets custom affinity label: `sedai.nodepool.affinity=<pool-name>`

Example command structure (for 1g.5gb partition):
```bash
gcloud container node-pools create "gpu-pool-timesliced-mig-1g-5gb" \
  --cluster="sedai-gpu-cluster" \
  --region="us-central1" \
  --machine-type="a2-highgpu-1g" \
  --accelerator type="nvidia-tesla-a100",count="1",gpu-partition-size="1g.5gb",gpu-driver-version="disabled" \
  --enable-autoscaling --min-nodes="1" --max-nodes="3" --num-nodes="0" \
  --node-labels nvidia.com/mig.config=mixed,sedai.nodepool.affinity="gpu-pool-timesliced-mig-1g-5gb" \
  --node-taints nvidia.com/gpu=present:NoSchedule \
  --shielded-integrity-monitoring --no-shielded-secure-boot \
  [... all preserved configurations ...]
```

### Step 5: Pool Verification and Comparison
- Saves original configuration to `old-nodepool-<name>.yaml`
- Saves new configuration to `new-nodepool-<name>-mig-enabled.yaml`
- Provides file comparison recommendations
- Verifies MIG-enabled nodes are created with correct labels

### Step 6: DRA Support Detection and Installation
```bash
# Checks for DRA API resources
kubectl api-resources | grep -q "resourceclaims.*resource.k8s.io"

# Adds NVIDIA Helm repository
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Installs/upgrades NVIDIA DRA driver using external configuration
helm -n nvidia-dra-driver-gpu upgrade -i nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
  --create-namespace \
  -f dra-driver-gcp.yaml \
  --version="v25.8.1"
```

## Companion Files

The script works with several companion YAML files for complete MIG setup:

### MIG Resource Claims (`mig-resource-claims.yaml`)
Individual ResourceClaim examples for each MIG partition size:
- `mig-small-claim` (1g.5gb profile)
- `mig-medium-claim` (2g.10gb profile)  
- `mig-large-claim` (3g.20gb profile)

### Workload Examples (`valid-example.yaml`)
Complete workload examples demonstrating:
- Node affinity targeting specific MIG partition pools
- ResourceClaim usage for DRA
- GPU tolerations and proper scheduling

## Output Files

The script generates several configuration files:

### Per Original Node Pool
- `old-nodepool-<pool-name>.yaml`: Original pool configuration

### Per MIG Partition Pool (3 files per original pool)
- `new-nodepool-<pool-name>-mig-1g-5gb.yaml`: 1g.5gb MIG pool configuration
- `new-nodepool-<pool-name>-mig-2g-10gb.yaml`: 2g.10gb MIG pool configuration  
- `new-nodepool-<pool-name>-mig-3g-20gb.yaml`: 3g.20gb MIG pool configuration

## Configuration Details

### Node Labels Applied
```yaml
nvidia.com/mig.config: mixed
sedai.nodepool.affinity: <pool-name>-mig-<partition>
```

### Example Labels by Partition
```yaml
# 1g.5gb partition
sedai.nodepool.affinity: gpu-pool-timesliced-mig-1g-5gb

# 2g.10gb partition  
sedai.nodepool.affinity: gpu-pool-timesliced-mig-2g-10gb

# 3g.20gb partition
sedai.nodepool.affinity: gpu-pool-timesliced-mig-3g-20gb
```

### Node Taints Applied
```yaml
nvidia.com/gpu: present:NoSchedule
```

### Supported GPU Types and MIG Partition Sizes
- **nvidia-tesla-a100**: Supports 1g.5gb, 2g.10gb, 3g.20gb partitions
- **nvidia-tesla-a30**: Limited MIG support  
- **nvidia-h100**: Supports MIG partitioning
- **nvidia-l40s**: No MIG support (script will create pools but without partition-size parameter)

## Troubleshooting

### Common Issues

#### DRA Driver Priority Class Quota Error
**Error**: `Insufficient quota to match these scopes: [{PriorityClass In [system-node-critical system-cluster-critical]}]`
**Solution**: Script automatically creates custom values file (`dra-values.yaml`) to override priority classes and avoid quota constraints

#### Empty Node Count Error
**Error**: `invalid int value: ''`
**Solution**: Script automatically defaults NUM_NODES to 1 if not specified and skips pools with 0 nodes

#### OAuth Scope Format Error
**Error**: `Scope does not exist`
**Solution**: Script converts semicolon-separated scopes to comma-separated format automatically

#### Pool Already Exists
**Warning**: Script intelligently skips creation of pools that already exist or have corresponding MIG-enabled versions

#### DRA Support Missing
**Error**: DRA API resources not found
**Solution**: Ensure cluster has Kubernetes 1.26+ and DRA feature gates enabled

### Verification Commands

Check MIG-enabled nodes by partition:
```bash
# Check 1g.5gb partition nodes
kubectl get nodes -l sedai.nodepool.affinity=<POOL_NAME>-mig-1g-5gb -L nvidia.com/mig.config

# Check 2g.10gb partition nodes  
kubectl get nodes -l sedai.nodepool.affinity=<POOL_NAME>-mig-2g-10gb -L nvidia.com/mig.config

# Check 3g.20gb partition nodes
kubectl get nodes -l sedai.nodepool.affinity=<POOL_NAME>-mig-3g-20gb -L nvidia.com/mig.config

# Check all MIG nodes
kubectl get nodes -l nvidia.com/mig.config=mixed
```

Debug node GPU configuration:
```bash
kubectl debug node/<NODE_NAME> -it --image=busybox
nvidia-smi -L
```

Verify DRA Driver:
```bash
kubectl get pods -n nvidia-dra-driver-gpu
kubectl get resourceclasses
```

Check DRA support:
```bash
kubectl api-resources | grep resourceclaims
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
- DRA driver installation is cluster-wide (one-time setup)
- MIG configuration is fixed at pool creation time
- Script assumes standard GKE node pool configurations
- Pool names are automatically truncated to meet 40-character limit
- Requires DRA support (Kubernetes 1.26+) for full functionality

## Support and Maintenance

- Keep gcloud CLI updated for latest GKE features
- Monitor NVIDIA DRA driver releases for updates
- Review GKE release notes for MIG and DRA-related changes
- Validate script compatibility with new GPU types as they become available
- Keep Helm charts updated from NVIDIA's NGC registry