#!/bin/bash

# GKE Node Pool with MIG Setup Script
# This script automates the process of listing, describing, creating, and verifying GKE node pools with MIG configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required parameters are provided
if [ $# -lt 3 ]; then
    echo "Usage: $0 <CLUSTER_NAME> <REGION> <GPU_CLASS>"
    echo "Example: $0 sedai-gpu-cluster us-central1 mig-dra"
    exit 1
fi

CLUSTER_NAME="$1"
REGION="$2"
GPU_CLASS="$3"

print_status "Starting GKE Node Pool MIG setup for cluster: $CLUSTER_NAME"

# Step 1: List GPU node pools in the cluster
print_status "Step 1: Listing GPU node pools in cluster $CLUSTER_NAME"
gcloud container node-pools list \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --filter="config.accelerators:* AND (config.accelerators.acceleratorType~nvidia-tesla-a100 OR config.accelerators.acceleratorType~nvidia-tesla-a30 OR config.accelerators.acceleratorType~nvidia-h100 OR config.accelerators.acceleratorType~nvidia-l40s)" \
  --format="table(
    name,
    status,
    config.machineType,
    initialNodeCount,
    config.accelerators.acceleratorType
  )"

# Get list of GPU node pool names
GPU_POOLS=($(gcloud container node-pools list \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --filter="config.accelerators:* AND (config.accelerators.acceleratorType~nvidia-tesla-a100 OR config.accelerators.acceleratorType~nvidia-tesla-a30 OR config.accelerators.acceleratorType~nvidia-h100 OR config.accelerators.acceleratorType~nvidia-l40s)" \
  --format="value(name)"))

if [ ${#GPU_POOLS[@]} -eq 0 ]; then
    print_error "No GPU node pools found in cluster $CLUSTER_NAME"
    exit 1
fi

print_status "Found ${#GPU_POOLS[@]} GPU node pool(s): ${GPU_POOLS[*]}"

echo ""
print_status "Processing each GPU node pool..."

# Step 2: Process each GPU node pool
for OLD_POOL_NAME in "${GPU_POOLS[@]}"; do
    echo ""
    print_status "=== Processing node pool: $OLD_POOL_NAME ==="
    
    NEW_POOL_NAME="${OLD_POOL_NAME}-mig-enabled"
    
    print_status "Step 2a: Describing old node pool $OLD_POOL_NAME"
    gcloud container node-pools describe "$OLD_POOL_NAME" \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" \
      --format=yaml > "old-nodepool-${OLD_POOL_NAME}.yaml"

    print_status "Old node pool configuration saved to old-nodepool-${OLD_POOL_NAME}.yaml"

    # Extract key configuration from the old pool
    print_status "Extracting configuration from old node pool..."

    MACHINE_TYPE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.machineType)")
    IMAGE_TYPE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.imageType)")
    DISK_TYPE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.diskType)")
    DISK_SIZE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.diskSizeGb)")
    SERVICE_ACCOUNT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.serviceAccount)")
    NUM_NODES=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(initialNodeCount)")
    NUM_NODES="${NUM_NODES:-1}"
    ACCELERATOR_TYPE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.accelerators[0].acceleratorType)")
    ACCELERATOR_COUNT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.accelerators[0].acceleratorCount)")
    
    # Extract additional settings
    OAUTH_SCOPES=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.oauthScopes[])" | tr '\n' ',' | sed 's/,$//')
    AUTOSCALING_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.enabled)")
    AUTOSCALING_MIN=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.minNodeCount)")
    AUTOSCALING_MAX=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.maxNodeCount)")
    AUTOREPAIR_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(management.autoRepair)")
    AUTOUPGRADE_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(management.autoUpgrade)")
    MAX_PODS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(maxPodsConstraint.maxPodsPerNode)")
    NODE_LOCATIONS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(locations[])" | tr '\n' ',' | sed 's/,$//')

    print_status "Extracted configuration for $OLD_POOL_NAME:"
    echo "  Machine Type: $MACHINE_TYPE"
    echo "  Image Type: $IMAGE_TYPE"
    echo "  Disk Type: $DISK_TYPE"
    echo "  Disk Size: $DISK_SIZE GB"
    echo "  Service Account: $SERVICE_ACCOUNT"
    echo "  Node Count: $NUM_NODES"
    echo "  Accelerator Type: $ACCELERATOR_TYPE"
    echo "  Accelerator Count: $ACCELERATOR_COUNT"
    echo "  OAuth Scopes: $OAUTH_SCOPES"
    echo "  Autoscaling Enabled: $AUTOSCALING_ENABLED"
    if [ "$AUTOSCALING_ENABLED" = "True" ]; then
        echo "  Autoscaling Min: $AUTOSCALING_MIN"
        echo "  Autoscaling Max: $AUTOSCALING_MAX"
    fi
    echo "  Auto Repair: $AUTOREPAIR_ENABLED"
    echo "  Auto Upgrade: $AUTOUPGRADE_ENABLED"
    echo "  Max Pods Per Node: $MAX_PODS"
    echo "  Node Locations: $NODE_LOCATIONS"

    echo ""
    read -p "Press Enter to continue with creating the new MIG-enabled node pool for $OLD_POOL_NAME..."

    # Step 3: Create new node pool with MIG configuration
    print_status "Step 3: Creating new MIG-enabled node pool $NEW_POOL_NAME"

    # Build the gcloud command with all extracted settings
    CREATE_CMD="gcloud container node-pools create \"$NEW_POOL_NAME\" \
      --cluster=\"$CLUSTER_NAME\" \
      --region=\"$REGION\" \
      --machine-type=\"$MACHINE_TYPE\" \
      --image-type=\"$IMAGE_TYPE\" \
      --disk-type=\"$DISK_TYPE\" \
      --disk-size=\"$DISK_SIZE\" \
      --service-account=\"$SERVICE_ACCOUNT\" \
      --accelerator type=\"$ACCELERATOR_TYPE\",count=\"$ACCELERATOR_COUNT\" \
      --node-labels nvidia.com/mig.config=mixed,workload.gke.io/gpu-class=\"$GPU_CLASS\" \
      --node-taints nvidia.com/gpu=present:NoSchedule"

    # Add OAuth scopes if present
    if [ -n "$OAUTH_SCOPES" ]; then
        # Convert semicolons to commas if they exist in the scopes
        OAUTH_SCOPES=$(echo "$OAUTH_SCOPES" | sed 's/;/,/g')
        CREATE_CMD="$CREATE_CMD --scopes=\"$OAUTH_SCOPES\""
    else
        CREATE_CMD="$CREATE_CMD --scopes=\"https://www.googleapis.com/auth/cloud-platform\""
    fi

    # Add autoscaling settings if enabled
    if [ "$AUTOSCALING_ENABLED" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --enable-autoscaling --min-nodes=\"$AUTOSCALING_MIN\" --max-nodes=\"$AUTOSCALING_MAX\""
    else
        CREATE_CMD="$CREATE_CMD --num-nodes=\"$NUM_NODES\""
    fi

    # Add management settings
    if [ "$AUTOREPAIR_ENABLED" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --enable-autorepair"
    fi
    if [ "$AUTOUPGRADE_ENABLED" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --enable-autoupgrade"
    fi

    # Add max pods constraint if present
    if [ -n "$MAX_PODS" ] && [ "$MAX_PODS" != "" ]; then
        CREATE_CMD="$CREATE_CMD --max-pods-per-node=\"$MAX_PODS\""
    fi

    # Add node locations if present
    if [ -n "$NODE_LOCATIONS" ] && [ "$NODE_LOCATIONS" != "" ]; then
        CREATE_CMD="$CREATE_CMD --node-locations=\"$NODE_LOCATIONS\""
    fi

    print_status "Executing: $CREATE_CMD"
    eval "$CREATE_CMD"

    print_status "New node pool $NEW_POOL_NAME created successfully"

    echo ""
    read -p "Press Enter to continue with verification..."

    # Step 4: Verify the new pool configuration
    print_status "Step 4: Verifying new node pool configuration"
    gcloud container node-pools describe "$NEW_POOL_NAME" \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" > "new-nodepool-${NEW_POOL_NAME}.yaml"

    print_status "New node pool configuration saved to new-nodepool-${NEW_POOL_NAME}.yaml"
    print_warning "Compare new-nodepool-${NEW_POOL_NAME}.yaml with old-nodepool-${OLD_POOL_NAME}.yaml to verify configuration"
    
    echo ""
    print_status "=== Completed processing $OLD_POOL_NAME ==="
    echo ""
done

# Step 5: Verify MIG is active on nodes
print_status "Step 5: Verifying MIG configuration on nodes"
print_status "Checking for MIG-enabled nodes..."

kubectl get nodes -l workload.gke.io/gpu-class="$GPU_CLASS" \
  -L nvidia.com/mig.config || print_warning "No MIG nodes found yet (may take time for nodes to be ready)"

echo ""
print_status "Step 6: Installing NVIDIA GPU Operator with DRA (if not already installed)"
print_warning "This step installs the GPU operator cluster-wide. Only run once per cluster."

read -p "Do you want to install the NVIDIA GPU Operator? (y/N): " install_operator

if [[ $install_operator =~ ^[Yy]$ ]]; then
    print_status "Adding NVIDIA Helm repository..."
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
    helm repo update

    print_status "Installing GPU Operator..."
    helm install gpu-operator nvidia/gpu-operator \
      --namespace gpu-operator \
      --create-namespace \
      --set mig.strategy=mixed \
      --set devicePlugin.enabled=false \
      --set dra.enabled=true

    print_status "Verifying GPU Operator installation..."
    kubectl get pods -n gpu-operator
else
    print_warning "Skipping GPU Operator installation"
fi

# Step 7: Create ResourceClasses
print_status "Step 7: Creating ResourceClasses for MIG profiles"

cat > nvidia-a100-mig-1g-10gb.yaml << EOF
apiVersion: resource.k8s.io/v1beta1
kind: ResourceClass
metadata:
  name: nvidia-a100-mig-1g-10gb
driverName: gpu.nvidia.com
parameters:
  migProfile: "1g.10gb"
EOF

cat > nvidia-a100-mig-2g-10gb.yaml << EOF
apiVersion: resource.k8s.io/v1beta1
kind: ResourceClass
metadata:
  name: nvidia-a100-mig-2g-10gb
driverName: gpu.nvidia.com
parameters:
  migProfile: "2g.10gb"
EOF

cat > nvidia-a100-mig-3g-40gb.yaml << EOF
apiVersion: resource.k8s.io/v1beta1
kind: ResourceClass
metadata:
  name: nvidia-a100-mig-3g-40gb
driverName: gpu.nvidia.com
parameters:
  migProfile: "3g.40gb"
EOF

print_status "ResourceClass YAML files created:"
echo "  - nvidia-a100-mig-1g-10gb.yaml"
echo "  - nvidia-a100-mig-2g-10gb.yaml"
echo "  - nvidia-a100-mig-3g-40gb.yaml"

read -p "Do you want to apply these ResourceClasses? (y/N): " apply_resources

if [[ $apply_resources =~ ^[Yy]$ ]]; then
    kubectl apply -f nvidia-a100-mig-1g-10gb.yaml
    kubectl apply -f nvidia-a100-mig-2g-10gb.yaml
    kubectl apply -f nvidia-a100-mig-3g-40gb.yaml
    print_status "ResourceClasses applied successfully"
else
    print_warning "ResourceClasses created but not applied"
fi

print_status "Setup complete!"
print_status "Summary of created files:"
for OLD_POOL_NAME in "${GPU_POOLS[@]}"; do
    NEW_POOL_NAME="${OLD_POOL_NAME}-mig-enabled"
    echo "  - old-nodepool-${OLD_POOL_NAME}.yaml (original pool configuration)"
    echo "  - new-nodepool-${NEW_POOL_NAME}.yaml (new MIG-enabled pool configuration)"
done
echo "  - nvidia-a100-mig-1g-10gb.yaml (ResourceClass for 1g.10gb)"
echo "  - nvidia-a100-mig-2g-10gb.yaml (ResourceClass for 2g.10gb)"
echo "  - nvidia-a100-mig-3g-40gb.yaml (ResourceClass for 3g.40gb)"

print_warning "Next steps:"
print_warning "1. Wait for new nodes to be ready"
print_warning "2. Verify MIG devices with: kubectl debug node/<NODE_NAME> -it --image=busybox"
print_warning "3. Run 'nvidia-smi -L' on the node to see MIG devices"
print_warning "4. Test workloads using the new ResourceClasses"