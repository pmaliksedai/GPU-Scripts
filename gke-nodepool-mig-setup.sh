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
if [ $# -lt 2 ]; then
    echo "Usage: $0 <CLUSTER_NAME> <REGION>"
    echo "Example: $0 sedai-gpu-cluster us-central1"
    exit 1
fi

CLUSTER_NAME="$1"
REGION="$2"

print_status "Starting GKE Node Pool MIG setup for cluster: $CLUSTER_NAME"

# Step 1: GPU Operator configuration management removed
# Note: GPU Operator clusterpolicy changes have been removed from this script
print_status "Step 1: Skipping GPU Operator configuration (removed from script)"

echo ""

# Step 2: List GPU node pools in the cluster
print_status "Step 2: Listing GPU node pools in cluster $CLUSTER_NAME"
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

# Check node count in each pool
print_status "Checking node counts in GPU node pools..."
while IFS= read -r pool_name; do
    if [[ -n "$pool_name" ]]; then
        node_count=$(gcloud container node-pools describe "$pool_name" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(initialNodeCount)")
        
        # Handle empty or null node count (treat as 0)
        if [[ -z "$node_count" || "$node_count" == "" ]]; then
            node_count=0
        fi
        
        if [[ "$node_count" =~ ^[0-9]+$ ]]; then
            if [ "$node_count" -eq 0 ]; then
                print_warning "Node pool '$pool_name' has 0 nodes"
            elif [ "$node_count" -gt 10 ]; then
                print_warning "Node pool '$pool_name' has a high node count: $node_count nodes"
            else
                print_status "Node pool '$pool_name' has $node_count node(s)"
            fi
        fi
    fi
done < <(gcloud container node-pools list \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --filter="config.accelerators:* AND (config.accelerators.acceleratorType~nvidia-tesla-a100 OR config.accelerators.acceleratorType~nvidia-tesla-a30 OR config.accelerators.acceleratorType~nvidia-h100 OR config.accelerators.acceleratorType~nvidia-l40s)" \
  --format="value(name)")

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

# Step 3: Process each GPU node pool
for OLD_POOL_NAME in "${GPU_POOLS[@]}"; do
    echo ""
    
    # Skip pools that are already MIG-enabled (check for various MIG naming patterns)
    if [[ "$OLD_POOL_NAME" == *"-mig-enabled"* || "$OLD_POOL_NAME" == *"-mig-1g-"* || "$OLD_POOL_NAME" == *"-mig-2g-"* || "$OLD_POOL_NAME" == *"-mig-3g-"* ]]; then
        print_warning "Skipping $OLD_POOL_NAME as it appears to be already MIG-enabled"
        continue
    fi
    
    print_status "=== Processing node pool: $OLD_POOL_NAME ==="
    
    # Define MIG partition configurations
    declare -a MIG_PARTITIONS=(
        "1g.5gb"
        "2g.10gb" 
        "3g.20gb"
    )
    
    # Process each MIG partition size
    for PARTITION_SIZE in "${MIG_PARTITIONS[@]}"; do
        echo ""
        print_status "--- Creating MIG partition: $PARTITION_SIZE for $OLD_POOL_NAME ---"
        
        # Create partition-specific pool name
        PARTITION_SUFFIX=$(echo "$PARTITION_SIZE" | tr '.' '-')  # Convert 1g.5gb to 1g-5gb
        BASE_NEW_NAME="${OLD_POOL_NAME}-mig-${PARTITION_SUFFIX}"
        
        # Ensure new pool name is under 40 characters
        if [ ${#BASE_NEW_NAME} -le 40 ]; then
            NEW_POOL_NAME="$BASE_NEW_NAME"
        else
            # Truncate base name to fit 40 char limit
            SUFFIX_LENGTH=$((${#PARTITION_SUFFIX} + 5))  # -mig- + partition suffix
            MAX_BASE_LENGTH=$((40 - $SUFFIX_LENGTH))
            TRUNCATED_BASE="${OLD_POOL_NAME:0:$MAX_BASE_LENGTH}"
            NEW_POOL_NAME="${TRUNCATED_BASE}-mig-${PARTITION_SUFFIX}"
        fi
        
        # Check if pool with this partition already exists
        if gcloud container node-pools describe "$NEW_POOL_NAME" \
            --cluster "$CLUSTER_NAME" \
            --region "$REGION" \
            --quiet > /dev/null 2>&1; then
            print_warning "Node pool $NEW_POOL_NAME already exists. Skipping creation."
            continue
        fi
        
        GPU_CLASS="$NEW_POOL_NAME"
    
    # Check if the current node pool has 0 nodes and skip if so
    CURRENT_NODE_COUNT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(initialNodeCount)")
    
    # Handle empty or null node count (treat as 0)
    if [[ -z "$CURRENT_NODE_COUNT" || "$CURRENT_NODE_COUNT" == "" ]]; then
        CURRENT_NODE_COUNT=0
    fi
    
    if [ "$CURRENT_NODE_COUNT" -eq 0 ]; then
        print_warning "Skipping node pool '$OLD_POOL_NAME' as it has 0 nodes"
        print_status "=== Skipped processing $OLD_POOL_NAME (0 nodes) ==="
        continue
    fi
    
    print_status "Step 3a: Describing old node pool $OLD_POOL_NAME"
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
    GPU_DRIVER_VERSION=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.accelerators[0].gpuDriverInstallationConfig.gpuDriverVersion)")
    
    # Extract additional settings
    OAUTH_SCOPES=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.oauthScopes[])" | tr '\n' ',' | sed 's/,$//')
    AUTOSCALING_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.enabled)")
    AUTOSCALING_MIN=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.minNodeCount)")
    AUTOSCALING_MAX=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(autoscaling.maxNodeCount)")
    AUTOREPAIR_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(management.autoRepair)")
    AUTOUPGRADE_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(management.autoUpgrade)")
    MAX_PODS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(maxPodsConstraint.maxPodsPerNode)")
    NODE_LOCATIONS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(locations[])" | tr '\n' ',' | sed 's/,$//')
    
    # Extract spot instance and preemptibility settings
    PREEMPTIBLE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.preemptible)")
    SPOT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.spot)")
    
    # Extract network and security settings
    BOOT_DISK_KMS_KEY=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.bootDiskKmsKey)")
    LOCAL_SSD_COUNT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.localSsdCount)")
    SHIELDED_INSTANCE_ENABLED=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.shieldedInstanceConfig.enableIntegrityMonitoring)")
    SHIELDED_SECURE_BOOT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.shieldedInstanceConfig.enableSecureBoot)")
    
    # Extract taint and label settings
    NODE_LABELS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.labels)" 2>/dev/null | sed 's/;/,/g')
    RESOURCE_LABELS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(resourceLabels)" 2>/dev/null | sed 's/;/,/g')
    # Extract taints and convert to gcloud format
    EXISTING_TAINTS=""
    
    # Try to get taints in a more direct way
    TAINT_COUNT=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.taints[].key)" 2>/dev/null | wc -l)
    
    if [[ "$TAINT_COUNT" -gt 0 ]]; then
        # Get taint components separately
        TAINT_KEYS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.taints[].key)" 2>/dev/null | tr '\n' '|')
        TAINT_VALUES=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.taints[].value)" 2>/dev/null | tr '\n' '|')
        TAINT_EFFECTS=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.taints[].effect)" 2>/dev/null | tr '\n' '|')
        
        # Convert to proper format
        IFS='|' read -ra KEYS <<< "$TAINT_KEYS"
        IFS='|' read -ra VALUES <<< "$TAINT_VALUES"  
        IFS='|' read -ra EFFECTS <<< "$TAINT_EFFECTS"
        
        TAINT_LIST=""
        for i in "${!KEYS[@]}"; do
            if [[ -n "${KEYS[i]}" ]]; then
                key="${KEYS[i]}"
                value="${VALUES[i]:-}"
                effect="${EFFECTS[i]:-}"
                
                # Convert effect format
                case "$effect" in
                    "NO_SCHEDULE") effect="NoSchedule" ;;
                    "PREFER_NO_SCHEDULE") effect="PreferNoSchedule" ;;
                    "NO_EXECUTE") effect="NoExecute" ;;
                esac
                
                # Build taint string
                if [[ -n "$value" && "$value" != "" ]]; then
                    TAINT_LIST="${TAINT_LIST}${key}=${value}:${effect},"
                else
                    TAINT_LIST="${TAINT_LIST}${key}:${effect},"
                fi
            fi
        done
        
        # Remove trailing comma
        EXISTING_TAINTS="${TAINT_LIST%,}"
    fi
    
    # Combine node labels and resource labels
    EXISTING_LABELS=""
    if [ -n "$NODE_LABELS" ] && [ "$NODE_LABELS" != "" ]; then
        EXISTING_LABELS="$NODE_LABELS"
    fi
    if [ -n "$RESOURCE_LABELS" ] && [ "$RESOURCE_LABELS" != "" ]; then
        if [ -n "$EXISTING_LABELS" ]; then
            EXISTING_LABELS="$EXISTING_LABELS,$RESOURCE_LABELS"
        else
            EXISTING_LABELS="$RESOURCE_LABELS"
        fi
    fi
    
    # Extract resource settings
    MIN_CPU_PLATFORM=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.minCpuPlatform)")
    RESERVATION_AFFINITY=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.reservationAffinity.consumeReservationType)")
    SANDBOX_TYPE=$(gcloud container node-pools describe "$OLD_POOL_NAME" --cluster "$CLUSTER_NAME" --region "$REGION" --format="value(config.sandboxConfig.type)")

    print_status "Extracted configuration for $OLD_POOL_NAME:"
    echo "  Machine Type: $MACHINE_TYPE"
    echo "  Image Type: $IMAGE_TYPE"
    echo "  Disk Type: $DISK_TYPE"
    echo "  Disk Size: $DISK_SIZE GB"
    echo "  Service Account: $SERVICE_ACCOUNT"
    echo "  Node Count: $NUM_NODES"
    echo "  Accelerator Type: $ACCELERATOR_TYPE"
    echo "  Accelerator Count: $ACCELERATOR_COUNT"
    echo "  GPU Driver Version: $GPU_DRIVER_VERSION"
    echo "  Preemptible: $PREEMPTIBLE"
    echo "  Spot: $SPOT"
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
    echo "  Local SSD Count: $LOCAL_SSD_COUNT"
    echo "  Min CPU Platform: $MIN_CPU_PLATFORM"
    echo "  Node Labels: $NODE_LABELS"
    echo "  Resource Labels: $RESOURCE_LABELS"
    echo "  Combined Labels: $EXISTING_LABELS"
    echo "  Existing Taints: $EXISTING_TAINTS"

    echo ""
    read -p "Press Enter to continue with creating the new MIG-enabled node pool for $OLD_POOL_NAME..."

    # Check if new node pool already exists
    print_status "Checking if node pool $NEW_POOL_NAME already exists..."
    if gcloud container node-pools describe "$NEW_POOL_NAME" \
        --cluster "$CLUSTER_NAME" \
        --region "$REGION" \
        --quiet > /dev/null 2>&1; then
        print_warning "Node pool $NEW_POOL_NAME already exists. Skipping creation."
        print_status "=== Skipped processing $OLD_POOL_NAME (pool already exists) ==="
        continue
    fi

    # Step 3b: Create new node pool with MIG configuration
    print_status "Step 3b: Creating new MIG-enabled node pool $NEW_POOL_NAME"

    # Merge existing node labels with MIG labels
    MIG_LABELS="nvidia.com/mig.config=mixed,sedai.nodepool.affinity=\"$GPU_CLASS\""
    if [ -n "$NODE_LABELS" ] && [ "$NODE_LABELS" != "" ]; then
        COMBINED_NODE_LABELS="$NODE_LABELS,$MIG_LABELS"
    else
        COMBINED_NODE_LABELS="$MIG_LABELS"
    fi

    # Merge existing taints with GPU taint
    GPU_TAINT="nvidia.com/gpu=present:NoSchedule"
    if [ -n "$EXISTING_TAINTS" ] && [ "$EXISTING_TAINTS" != "" ]; then
        # Check if GPU taint already exists to avoid duplicates
        if [[ "$EXISTING_TAINTS" == *"nvidia.com/gpu=present:NoSchedule"* ]]; then
            COMBINED_TAINTS="$EXISTING_TAINTS"
        else
            COMBINED_TAINTS="$EXISTING_TAINTS,$GPU_TAINT"
        fi
    else
        COMBINED_TAINTS="$GPU_TAINT"
    fi

    # Build accelerator configuration with MIG partition size and optional GPU driver version
    ACCELERATOR_CONFIG="type=\"$ACCELERATOR_TYPE\",count=\"$ACCELERATOR_COUNT\",gpu-partition-size=\"$PARTITION_SIZE\""
    if [ -n "$GPU_DRIVER_VERSION" ] && [ "$GPU_DRIVER_VERSION" != "" ] && [ "$GPU_DRIVER_VERSION" != "null" ]; then
        # Map GPU driver version to valid gcloud values (default, latest, disabled)
        case "$GPU_DRIVER_VERSION" in
            "INSTALLATION_DISABLED"|"installation_disabled")
                GPU_DRIVER_MAPPED="disabled"
                ;;
            "DEFAULT"|"default")
                GPU_DRIVER_MAPPED="default"
                ;;
            "LATEST"|"latest")
                GPU_DRIVER_MAPPED="latest"
                ;;
            *)
                # For any other value, use default
                GPU_DRIVER_MAPPED="default"
                ;;
        esac
        ACCELERATOR_CONFIG="$ACCELERATOR_CONFIG,gpu-driver-version=$GPU_DRIVER_MAPPED"
    fi

    # Build the gcloud command with all extracted settings
    CREATE_CMD="gcloud container node-pools create \"$NEW_POOL_NAME\" \
      --cluster=\"$CLUSTER_NAME\" \
      --region=\"$REGION\" \
      --machine-type=\"$MACHINE_TYPE\" \
      --image-type=\"$IMAGE_TYPE\" \
      --disk-type=\"$DISK_TYPE\" \
      --disk-size=\"$DISK_SIZE\" \
      --service-account=\"$SERVICE_ACCOUNT\" \
      --accelerator $ACCELERATOR_CONFIG \
      --node-labels \"$COMBINED_NODE_LABELS\" \
      --node-taints \"$COMBINED_TAINTS\""

    # Add OAuth scopes if present
    if [ -n "$OAUTH_SCOPES" ]; then
        # Convert semicolons to commas if they exist in the scopes
        OAUTH_SCOPES=$(echo "$OAUTH_SCOPES" | sed 's/;/,/g')
        CREATE_CMD="$CREATE_CMD --scopes=\"$OAUTH_SCOPES\""
    else
        CREATE_CMD="$CREATE_CMD --scopes=\"https://www.googleapis.com/auth/cloud-platform\""
    fi

    # Add autoscaling settings - always enable autoscaling for MIG pools with 0 initial nodes
    if [ "$AUTOSCALING_ENABLED" = "True" ]; then
        # Original pool had autoscaling enabled, use original min/max values but start with 0 nodes
        CREATE_CMD="$CREATE_CMD --enable-autoscaling --min-nodes=\"$AUTOSCALING_MIN\" --max-nodes=\"$AUTOSCALING_MAX\" --num-nodes=\"0\""
    else
        # Original pool didn't have autoscaling, enable with min=1, max=original_node_count, start with 0 nodes
        CREATE_CMD="$CREATE_CMD --enable-autoscaling --min-nodes=\"1\" --max-nodes=\"$NUM_NODES\" --num-nodes=\"0\""
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

    # Add spot/preemptible settings
    if [ "$SPOT" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --spot"
    elif [ "$PREEMPTIBLE" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --preemptible"
    fi

    # Add local SSD count if present
    if [ -n "$LOCAL_SSD_COUNT" ] && [ "$LOCAL_SSD_COUNT" != "0" ] && [ "$LOCAL_SSD_COUNT" != "" ]; then
        CREATE_CMD="$CREATE_CMD --local-ssd-count=\"$LOCAL_SSD_COUNT\""
    fi

    # Add min CPU platform if present
    if [ -n "$MIN_CPU_PLATFORM" ] && [ "$MIN_CPU_PLATFORM" != "" ]; then
        CREATE_CMD="$CREATE_CMD --min-cpu-platform=\"$MIN_CPU_PLATFORM\""
    fi

    # Add boot disk KMS key if present
    if [ -n "$BOOT_DISK_KMS_KEY" ] && [ "$BOOT_DISK_KMS_KEY" != "" ]; then
        CREATE_CMD="$CREATE_CMD --boot-disk-kms-key=\"$BOOT_DISK_KMS_KEY\""
    fi

    # Add shielded instance settings - disable secure boot for MIG compatibility
    if [ "$SHIELDED_INSTANCE_ENABLED" = "True" ]; then
        CREATE_CMD="$CREATE_CMD --shielded-integrity-monitoring --no-shielded-secure-boot"
    else
        # For new pools, enable integrity monitoring but disable secure boot
        CREATE_CMD="$CREATE_CMD --shielded-integrity-monitoring --no-shielded-secure-boot"
    fi

    # Add reservation affinity if present
    if [ -n "$RESERVATION_AFFINITY" ] && [ "$RESERVATION_AFFINITY" != "" ]; then
        CREATE_CMD="$CREATE_CMD --reservation-affinity=\"$RESERVATION_AFFINITY\""
    fi

    # Add sandbox type if present
    if [ -n "$SANDBOX_TYPE" ] && [ "$SANDBOX_TYPE" != "" ]; then
        CREATE_CMD="$CREATE_CMD --sandbox=\"$SANDBOX_TYPE\""
    fi

    # Add resource labels if they exist
    if [ -n "$RESOURCE_LABELS" ] && [ "$RESOURCE_LABELS" != "" ]; then
        CREATE_CMD="$CREATE_CMD --labels=\"$RESOURCE_LABELS\""
    fi

    print_status "Executing: $CREATE_CMD"
    eval "$CREATE_CMD"

    print_status "New node pool $NEW_POOL_NAME created successfully"

    echo ""
    read -p "Press Enter to continue with verification..."

    # Step 3c: Verify the new pool configuration
    print_status "Step 3c: Verifying new node pool configuration"
    gcloud container node-pools describe "$NEW_POOL_NAME" \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" > "new-nodepool-${NEW_POOL_NAME}.yaml"

    print_status "New node pool configuration saved to new-nodepool-${NEW_POOL_NAME}.yaml"
    print_warning "Compare new-nodepool-${NEW_POOL_NAME}.yaml with old-nodepool-${OLD_POOL_NAME}.yaml to verify configuration"
    
    echo ""
    done  # End of partition loop
    
    print_status "=== Completed processing $OLD_POOL_NAME ==="
    echo ""
done  # End of pool loop

# Step 4: Verify MIG is active on nodes
print_status "Step 4: Verifying MIG configuration on nodes"
print_status "Checking for MIG-enabled nodes..."

kubectl get nodes -l sedai.nodepool.affinity="$GPU_CLASS" \
  -L nvidia.com/mig.config || print_warning "No MIG nodes found yet (may take time for nodes to be ready)"

echo ""
print_status "Step 5: Installing NVIDIA DRA Driver (if not already installed)"

# Check if DRA is supported in the cluster
print_status "Checking for DRA support in the cluster..."
if kubectl api-resources | grep -q "resourceclaims.*resource.k8s.io"; then
    print_status "DRA support detected in cluster"
    
    read -p "Do you want to install the NVIDIA DRA Driver? (y/N): " install_dra

    if [[ $install_dra =~ ^[Yy]$ ]]; then
        print_status "Adding NVIDIA Helm repository..."
        helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
        helm repo update

        print_status "Installing/Upgrading DRA Driver using configuration file..."
        # Check if dra-driver-gcp.yaml exists in current directory
        if [ -f "dra-driver-gcp.yaml" ]; then
            helm -n nvidia-dra-driver-gpu upgrade -i nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
              --create-namespace \
              -f dra-driver-gcp.yaml \
              --version="v25.8.1"
            
            print_status "DRA Driver installed/upgraded successfully"
        else
            print_error "dra-driver-gcp.yaml configuration file not found in current directory"
            print_error "Please ensure dra-driver-gcp.yaml is available before running this script"
            exit 1
        fi

        print_status "Verifying DRA Driver installation..."
        kubectl get pods -n nvidia-dra-driver-gpu
    else
        print_warning "Skipping DRA Driver installation"
    fi
else
    print_error "DRA (Dynamic Resource Allocation) is not supported in this cluster"
    print_error "DRA requires Kubernetes 1.26+ with specific feature gates enabled"
    print_warning "For GKE, you need to enable the DRA feature in cluster configuration"
    print_warning "Skipping DRA Driver installation"
fi


print_status "Setup complete!"
print_status "Summary of created files:"
for OLD_POOL_NAME in "${GPU_POOLS[@]}"; do
    # Ensure new pool name is under 40 characters
    CANDIDATE_NAME="${OLD_POOL_NAME}-mig-enabled"
    if [ ${#CANDIDATE_NAME} -le 40 ]; then
        NEW_POOL_NAME="$CANDIDATE_NAME"
    else
        # Truncate base name to fit 40 char limit with -mig-enabled suffix (12 chars)
        MAX_BASE_LENGTH=$((40 - 12))
        TRUNCATED_BASE="${OLD_POOL_NAME:0:$MAX_BASE_LENGTH}"
        NEW_POOL_NAME="${TRUNCATED_BASE}-mig-enabled"
    fi
    echo "  - old-nodepool-${OLD_POOL_NAME}.yaml (original pool configuration)"
    echo "  - new-nodepool-${NEW_POOL_NAME}.yaml (new MIG-enabled pool configuration)"
done

print_warning "Next steps:"
print_warning "1. Wait for new nodes to be ready"
print_warning "2. Verify MIG devices with: kubectl debug node/<NODE_NAME> -it --image=busybox"
print_warning "3. Run 'nvidia-smi -L' on the node to see MIG devices"
print_warning "4. Test workloads using the new ResourceClasses"