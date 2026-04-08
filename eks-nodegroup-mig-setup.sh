#!/bin/bash

# EKS Node Group with MIG Setup Script
# This script automates the process of listing, describing, creating, and verifying EKS node groups with MIG configuration

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
    echo "Example: $0 sedai-gpu-cluster us-west-2"
    exit 1
fi

CLUSTER_NAME="$1"
REGION="$2"

print_status "Starting EKS Node Group MIG setup for cluster: $CLUSTER_NAME"

# Verify AWS CLI is configured
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS CLI is not configured or credentials are invalid"
    exit 1
fi

# Verify cluster exists
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1; then
    print_error "EKS cluster $CLUSTER_NAME not found in region $REGION"
    exit 1
fi

# Step 1: GPU Operator configuration management removed
# Note: GPU Operator clusterpolicy changes have been removed from this script
print_status "Step 1: Skipping GPU Operator configuration (removed from script)"

echo ""

# Step 2: List GPU node groups in the cluster
print_status "Step 2: Listing GPU node groups in cluster $CLUSTER_NAME"

# Get all node groups first
ALL_NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --query 'nodegroups[]' --output text)

if [ -z "$ALL_NODEGROUPS" ]; then
    print_error "No node groups found in cluster $CLUSTER_NAME"
    exit 1
fi

# Filter for GPU node groups by checking instance types
GPU_NODEGROUPS=()
for nodegroup in $ALL_NODEGROUPS; do
    # Get instance types for this node group
    INSTANCE_TYPES=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$REGION" --query 'nodegroup.instanceTypes[]' --output text)
    
    # Check if any instance type is GPU-enabled (p3, p4, g4, g5, etc.)
    for instance_type in $INSTANCE_TYPES; do
        if [[ "$instance_type" =~ ^(p3|p4|p5|g4|g5|g6).*$ ]]; then
            GPU_NODEGROUPS+=("$nodegroup")
            break
        fi
    done
done

if [ ${#GPU_NODEGROUPS[@]} -eq 0 ]; then
    print_error "No GPU node groups found in cluster $CLUSTER_NAME"
    exit 1
fi

print_status "Found ${#GPU_NODEGROUPS[@]} GPU node group(s): ${GPU_NODEGROUPS[*]}"

# Display GPU node group details
echo ""
echo "GPU Node Groups Summary:"
echo "========================"
printf "%-25s %-15s %-20s %-10s %-15s\n" "NAME" "STATUS" "INSTANCE_TYPE" "NODES" "GPU_TYPE"
echo "------------------------------------------------------------------------------------"

for nodegroup in "${GPU_NODEGROUPS[@]}"; do
    DETAILS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$REGION" --query 'nodegroup.[status,instanceTypes[0],scalingConfig.currentSize]' --output text)
    read -r status instance_type current_size <<< "$DETAILS"
    
    # Map instance type to GPU type
    case "$instance_type" in
        p3.*) gpu_type="V100" ;;
        p4.*) gpu_type="A100" ;;
        p5.*) gpu_type="H100" ;;
        g4.*) gpu_type="T4" ;;
        g5.*) gpu_type="A10G" ;;
        g6.*) gpu_type="L4" ;;
        *) gpu_type="Unknown" ;;
    esac
    
    printf "%-25s %-15s %-20s %-10s %-15s\n" "$nodegroup" "$status" "$instance_type" "$current_size" "$gpu_type"
done

echo ""

# Check node count in each node group
print_status "Checking node counts in GPU node groups..."
for nodegroup in "${GPU_NODEGROUPS[@]}"; do
    current_size=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$nodegroup" --region "$REGION" --query 'nodegroup.scalingConfig.currentSize' --output text)
    
    if [ "$current_size" -eq 0 ]; then
        print_warning "Node group '$nodegroup' has 0 nodes"
    elif [ "$current_size" -gt 10 ]; then
        print_warning "Node group '$nodegroup' has a high node count: $current_size nodes"
    else
        print_status "Node group '$nodegroup' has $current_size node(s)"
    fi
done

echo ""
print_status "Processing each GPU node group..."

# Step 3: Process each GPU node group
for OLD_NODEGROUP_NAME in "${GPU_NODEGROUPS[@]}"; do
    echo ""
    
    # Skip node groups that are already MIG-enabled (check for various MIG naming patterns)
    if [[ "$OLD_NODEGROUP_NAME" == *"-mig-enabled"* || "$OLD_NODEGROUP_NAME" == *"-mig-1g-"* || "$OLD_NODEGROUP_NAME" == *"-mig-2g-"* || "$OLD_NODEGROUP_NAME" == *"-mig-3g-"* ]]; then
        print_warning "Skipping $OLD_NODEGROUP_NAME as it appears to be already MIG-enabled"
        continue
    fi
    
    print_status "=== Processing node group: $OLD_NODEGROUP_NAME ==="
    
    # Check if the current node group has 0 nodes and skip if so
    CURRENT_NODE_COUNT=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$OLD_NODEGROUP_NAME" --region "$REGION" --query 'nodegroup.scalingConfig.currentSize' --output text)
    
    if [ "$CURRENT_NODE_COUNT" -eq 0 ]; then
        print_warning "Skipping node group '$OLD_NODEGROUP_NAME' as it has 0 nodes"
        print_status "=== Skipped processing $OLD_NODEGROUP_NAME (0 nodes) ==="
        continue
    fi
    
    # Define MIG partition configurations
    declare -a MIG_PARTITIONS=(
        "1g.5gb"
        "2g.10gb" 
        "3g.20gb"
    )
    
    # Process each MIG partition size
    for PARTITION_SIZE in "${MIG_PARTITIONS[@]}"; do
        echo ""
        print_status "--- Creating MIG partition: $PARTITION_SIZE for $OLD_NODEGROUP_NAME ---"
        
        # Create partition-specific node group name
        PARTITION_SUFFIX=$(echo "$PARTITION_SIZE" | tr '.' '-')  # Convert 1g.5gb to 1g-5gb
        BASE_NEW_NAME="${OLD_NODEGROUP_NAME}-mig-${PARTITION_SUFFIX}"
        
        # Ensure new node group name is under 63 characters (EKS limit)
        if [ ${#BASE_NEW_NAME} -le 63 ]; then
            NEW_NODEGROUP_NAME="$BASE_NEW_NAME"
        else
            # Truncate base name to fit 63 char limit
            SUFFIX_LENGTH=$((${#PARTITION_SUFFIX} + 5))  # -mig- + partition suffix
            MAX_BASE_LENGTH=$((63 - $SUFFIX_LENGTH))
            TRUNCATED_BASE="${OLD_NODEGROUP_NAME:0:$MAX_BASE_LENGTH}"
            NEW_NODEGROUP_NAME="${TRUNCATED_BASE}-mig-${PARTITION_SUFFIX}"
        fi
        
        # Check if node group with this partition already exists
        if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NEW_NODEGROUP_NAME" --region "$REGION" > /dev/null 2>&1; then
            print_warning "Node group $NEW_NODEGROUP_NAME already exists. Skipping creation."
            continue
        fi
        
        GPU_CLASS="$NEW_NODEGROUP_NAME"
    
        print_status "Step 3a: Describing old node group $OLD_NODEGROUP_NAME"
        aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$OLD_NODEGROUP_NAME" --region "$REGION" > "old-nodegroup-${OLD_NODEGROUP_NAME}.yaml"

        print_status "Old node group configuration saved to old-nodegroup-${OLD_NODEGROUP_NAME}.yaml"

        # Extract key configuration from the old node group
        print_status "Extracting configuration from old node group..."

        # Get node group details
        NODEGROUP_CONFIG=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$OLD_NODEGROUP_NAME" --region "$REGION" --query 'nodegroup')
        
        INSTANCE_TYPES=$(echo "$NODEGROUP_CONFIG" | jq -r '.instanceTypes[]' | tr '\n' ',' | sed 's/,$//')
        AMI_TYPE=$(echo "$NODEGROUP_CONFIG" | jq -r '.amiType // "AL2_x86_64_GPU"')
        CAPACITY_TYPE=$(echo "$NODEGROUP_CONFIG" | jq -r '.capacityType // "ON_DEMAND"')
        NODE_ROLE=$(echo "$NODEGROUP_CONFIG" | jq -r '.nodeRole')
        SUBNETS=$(echo "$NODEGROUP_CONFIG" | jq -r '.subnets[]' | tr '\n' ',' | sed 's/,$//')
        SECURITY_GROUPS=$(echo "$NODEGROUP_CONFIG" | jq -r '.remoteAccess.sourceSecurityGroups[]? // empty' | tr '\n' ',' | sed 's/,$//')
        KEY_PAIR=$(echo "$NODEGROUP_CONFIG" | jq -r '.remoteAccess.ec2SshKey // empty')
        DISK_SIZE=$(echo "$NODEGROUP_CONFIG" | jq -r '.diskSize // 20')
        
        # Scaling configuration
        MIN_SIZE=$(echo "$NODEGROUP_CONFIG" | jq -r '.scalingConfig.minSize // 1')
        MAX_SIZE=$(echo "$NODEGROUP_CONFIG" | jq -r '.scalingConfig.maxSize // 3')
        DESIRED_SIZE=$(echo "$NODEGROUP_CONFIG" | jq -r '.scalingConfig.desiredSize // 1')
        
        # Update policy
        UPDATE_MAX_UNAVAILABLE=$(echo "$NODEGROUP_CONFIG" | jq -r '.updateConfig.maxUnavailable // 1')
        UPDATE_MAX_UNAVAILABLE_PERCENTAGE=$(echo "$NODEGROUP_CONFIG" | jq -r '.updateConfig.maxUnavailablePercentage // empty')
        
        # Launch template
        LAUNCH_TEMPLATE_ID=$(echo "$NODEGROUP_CONFIG" | jq -r '.launchTemplate.id // empty')
        LAUNCH_TEMPLATE_VERSION=$(echo "$NODEGROUP_CONFIG" | jq -r '.launchTemplate.version // empty')
        
        # Labels and taints
        NODE_LABELS=$(echo "$NODEGROUP_CONFIG" | jq -r '.labels // {}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        EXISTING_TAINTS=$(echo "$NODEGROUP_CONFIG" | jq -r '.taints[]? // empty' | jq -r '"\(.key)=\(.value):\(.effect)"' | tr '\n' ',' | sed 's/,$//')
        
        # Resource tags
        RESOURCE_TAGS=$(echo "$NODEGROUP_CONFIG" | jq -r '.tags // {}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')

        print_status "Extracted configuration for $OLD_NODEGROUP_NAME:"
        echo "  Instance Types: $INSTANCE_TYPES"
        echo "  AMI Type: $AMI_TYPE"
        echo "  Capacity Type: $CAPACITY_TYPE"
        echo "  Node Role: $NODE_ROLE"
        echo "  Subnets: $SUBNETS"
        echo "  Security Groups: $SECURITY_GROUPS"
        echo "  Key Pair: $KEY_PAIR"
        echo "  Disk Size: $DISK_SIZE GB"
        echo "  Min Size: $MIN_SIZE"
        echo "  Max Size: $MAX_SIZE"
        echo "  Desired Size: $DESIRED_SIZE"
        echo "  Launch Template ID: $LAUNCH_TEMPLATE_ID"
        echo "  Launch Template Version: $LAUNCH_TEMPLATE_VERSION"
        echo "  Node Labels: $NODE_LABELS"
        echo "  Existing Taints: $EXISTING_TAINTS"
        echo "  Resource Tags: $RESOURCE_TAGS"

        echo ""
        read -p "Press Enter to continue with creating the new MIG-enabled node group for $OLD_NODEGROUP_NAME..."

        # Check if new node group already exists
        print_status "Checking if node group $NEW_NODEGROUP_NAME already exists..."
        if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NEW_NODEGROUP_NAME" --region "$REGION" > /dev/null 2>&1; then
            print_warning "Node group $NEW_NODEGROUP_NAME already exists. Skipping creation."
            print_status "=== Skipped processing $OLD_NODEGROUP_NAME (node group already exists) ==="
            continue
        fi

        # Step 3b: Create new node group with MIG configuration
        print_status "Step 3b: Creating new MIG-enabled node group $NEW_NODEGROUP_NAME"

        # Create or update launch template with MIG configuration
        LAUNCH_TEMPLATE_NAME="lt-${NEW_NODEGROUP_NAME}"
        
        # Create user data for MIG configuration
        MIG_USER_DATA=$(cat <<EOF | base64 -w 0
#!/bin/bash
/etc/eks/bootstrap.sh $CLUSTER_NAME

# Configure MIG
nvidia-smi -mig 1
nvidia-smi mig -cgi 19,14,9 -C
nvidia-smi mig -lgip -C

# Set MIG mixed mode
echo 'nvidia.com/mig.config: mixed' > /tmp/mig-config
EOF
)

        # Merge existing node labels with MIG labels
        MIG_LABELS="nvidia.com/mig.config=mixed,sedai.nodepool.affinity=$GPU_CLASS"
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

        # Create launch template with MIG configuration
        print_status "Creating launch template for MIG configuration..."
        
        # Build launch template JSON
        LAUNCH_TEMPLATE_DATA=$(cat <<EOF
{
    "ImageId": "ami-0c02c3b0e90bb3570",
    "InstanceType": "$(echo "$INSTANCE_TYPES" | cut -d',' -f1)",
    "UserData": "$MIG_USER_DATA",
    "BlockDeviceMappings": [
        {
            "DeviceName": "/dev/xvda",
            "Ebs": {
                "VolumeSize": $DISK_SIZE,
                "VolumeType": "gp3",
                "DeleteOnTermination": true
            }
        }
    ],
    "TagSpecifications": [
        {
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "$NEW_NODEGROUP_NAME"},
                {"Key": "kubernetes.io/cluster/$CLUSTER_NAME", "Value": "owned"},
                {"Key": "nvidia.com/mig.config", "Value": "mixed"},
                {"Key": "sedai.nodepool.affinity", "Value": "$GPU_CLASS"}
            ]
        }
    ]
}
EOF
)

        # Create the launch template
        LAUNCH_TEMPLATE_RESULT=$(aws ec2 create-launch-template \
            --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
            --launch-template-data "$LAUNCH_TEMPLATE_DATA" \
            --region "$REGION")
        
        CREATED_LAUNCH_TEMPLATE_ID=$(echo "$LAUNCH_TEMPLATE_RESULT" | jq -r '.LaunchTemplate.LaunchTemplateId')
        
        print_status "Created launch template: $CREATED_LAUNCH_TEMPLATE_ID"

        # Build the create node group command
        CREATE_NODEGROUP_JSON=$(cat <<EOF
{
    "clusterName": "$CLUSTER_NAME",
    "nodegroupName": "$NEW_NODEGROUP_NAME",
    "scalingConfig": {
        "minSize": $MIN_SIZE,
        "maxSize": $MAX_SIZE,
        "desiredSize": 0
    },
    "instanceTypes": [$(echo "$INSTANCE_TYPES" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')],
    "amiType": "$AMI_TYPE",
    "nodeRole": "$NODE_ROLE",
    "subnets": [$(echo "$SUBNETS" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')],
    "capacityType": "$CAPACITY_TYPE",
    "diskSize": $DISK_SIZE,
    "launchTemplate": {
        "id": "$CREATED_LAUNCH_TEMPLATE_ID",
        "version": "1"
    },
    "labels": {$(echo "$COMBINED_NODE_LABELS" | sed 's/,/","/g' | sed 's/=/": "/g' | sed 's/^/"/' | sed 's/$/"/')},
    "taints": [
EOF
)

        # Add taints to JSON
        if [ -n "$COMBINED_TAINTS" ] && [ "$COMBINED_TAINTS" != "" ]; then
            IFS=',' read -ra TAINT_ARRAY <<< "$COMBINED_TAINTS"
            TAINT_JSON_PARTS=()
            for taint in "${TAINT_ARRAY[@]}"; do
                if [[ "$taint" == *"="* ]]; then
                    key=$(echo "$taint" | cut -d'=' -f1)
                    value_effect=$(echo "$taint" | cut -d'=' -f2)
                    value=$(echo "$value_effect" | cut -d':' -f1)
                    effect=$(echo "$value_effect" | cut -d':' -f2)
                else
                    key=$(echo "$taint" | cut -d':' -f1)
                    value=""
                    effect=$(echo "$taint" | cut -d':' -f2)
                fi
                
                if [ -n "$value" ]; then
                    TAINT_JSON_PARTS+=("{\"key\": \"$key\", \"value\": \"$value\", \"effect\": \"$effect\"}")
                else
                    TAINT_JSON_PARTS+=("{\"key\": \"$key\", \"effect\": \"$effect\"}")
                fi
            done
            
            # Join taint JSON parts
            TAINTS_JSON=$(IFS=','; echo "${TAINT_JSON_PARTS[*]}")
            CREATE_NODEGROUP_JSON="$CREATE_NODEGROUP_JSON$TAINTS_JSON"
        fi
        
        CREATE_NODEGROUP_JSON="$CREATE_NODEGROUP_JSON]"
        
        # Add tags if they exist
        if [ -n "$RESOURCE_TAGS" ] && [ "$RESOURCE_TAGS" != "" ]; then
            CREATE_NODEGROUP_JSON="$CREATE_NODEGROUP_JSON,\"tags\": {$(echo "$RESOURCE_TAGS" | sed 's/,/","/g' | sed 's/=/": "/g' | sed 's/^/"/' | sed 's/$/"/')}"
        fi
        
        CREATE_NODEGROUP_JSON="$CREATE_NODEGROUP_JSON}"

        # Add remote access if key pair exists
        if [ -n "$KEY_PAIR" ] && [ "$KEY_PAIR" != "" ]; then
            REMOTE_ACCESS_JSON='"remoteAccess": {"ec2SshKey": "'$KEY_PAIR'"'
            if [ -n "$SECURITY_GROUPS" ] && [ "$SECURITY_GROUPS" != "" ]; then
                REMOTE_ACCESS_JSON="$REMOTE_ACCESS_JSON,\"sourceSecurityGroups\": [$(echo "$SECURITY_GROUPS" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')]},"
            else
                REMOTE_ACCESS_JSON="$REMOTE_ACCESS_JSON},"
            fi
            
            # Insert remote access into JSON (before the closing brace)
            CREATE_NODEGROUP_JSON=$(echo "$CREATE_NODEGROUP_JSON" | sed "s/}$/,$REMOTE_ACCESS_JSON}/")
        fi

        print_status "Creating node group with configuration..."
        echo "$CREATE_NODEGROUP_JSON" | jq '.' > "/tmp/${NEW_NODEGROUP_NAME}-create.json"
        
        aws eks create-nodegroup --region "$REGION" --cli-input-json "file:///tmp/${NEW_NODEGROUP_NAME}-create.json"

        print_status "New node group $NEW_NODEGROUP_NAME creation initiated"

        echo ""
        read -p "Press Enter to continue with verification..."

        # Step 3c: Wait for node group to be active and verify configuration
        print_status "Step 3c: Waiting for node group to become active..."
        
        while true; do
            STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NEW_NODEGROUP_NAME" --region "$REGION" --query 'nodegroup.status' --output text)
            case "$STATUS" in
                "ACTIVE")
                    print_status "Node group $NEW_NODEGROUP_NAME is now active"
                    break
                    ;;
                "CREATE_FAILED"|"DELETE_FAILED")
                    print_error "Node group $NEW_NODEGROUP_NAME creation failed with status: $STATUS"
                    exit 1
                    ;;
                *)
                    print_status "Node group status: $STATUS. Waiting..."
                    sleep 30
                    ;;
            esac
        done

        print_status "Verifying new node group configuration"
        aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NEW_NODEGROUP_NAME" --region "$REGION" > "new-nodegroup-${NEW_NODEGROUP_NAME}.yaml"

        print_status "New node group configuration saved to new-nodegroup-${NEW_NODEGROUP_NAME}.yaml"
        print_warning "Compare new-nodegroup-${NEW_NODEGROUP_NAME}.yaml with old-nodegroup-${OLD_NODEGROUP_NAME}.yaml to verify configuration"
        
        echo ""
    done  # End of partition loop
    
    print_status "=== Completed processing $OLD_NODEGROUP_NAME ==="
    echo ""
done  # End of node group loop

# Step 4: Verify MIG is active on nodes
print_status "Step 4: Verifying MIG configuration on nodes"
print_status "Checking for MIG-enabled nodes..."

# Wait for nodes to be ready
print_status "Waiting for nodes to join the cluster..."
sleep 60

kubectl get nodes -l sedai.nodepool.affinity="$GPU_CLASS" \
  -L nvidia.com/mig.config || print_warning "No MIG nodes found yet (may take time for nodes to be ready)"

echo ""
print_status "Step 5: Installing NVIDIA Device Plugin and MIG Manager (if not already installed)"

# Check if NVIDIA device plugin is installed
print_status "Checking for NVIDIA device plugin..."
if kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system > /dev/null 2>&1; then
    print_status "NVIDIA device plugin already installed"
else
    read -p "Do you want to install the NVIDIA device plugin? (y/N): " install_plugin
    
    if [[ $install_plugin =~ ^[Yy]$ ]]; then
        print_status "Installing NVIDIA device plugin..."
        kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml
        print_status "NVIDIA device plugin installed"
    else
        print_warning "Skipping NVIDIA device plugin installation"
    fi
fi

# Check if MIG Manager is installed
print_status "Checking for NVIDIA MIG Manager..."
if kubectl get deployment nvidia-mig-manager -n gpu-operator-resources > /dev/null 2>&1; then
    print_status "NVIDIA MIG Manager already installed"
else
    read -p "Do you want to install NVIDIA MIG Manager? (y/N): " install_mig_manager
    
    if [[ $install_mig_manager =~ ^[Yy]$ ]]; then
        print_status "Installing NVIDIA MIG Manager..."
        
        # Create namespace if it doesn't exist
        kubectl create namespace gpu-operator-resources --dry-run=client -o yaml | kubectl apply -f -
        
        # Apply MIG Manager configuration
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-mig-manager
  namespace: gpu-operator-resources
spec:
  selector:
    matchLabels:
      app: nvidia-mig-manager
  template:
    metadata:
      labels:
        app: nvidia-mig-manager
    spec:
      hostPID: true
      containers:
      - name: nvidia-mig-manager
        image: nvidia/mig-parted:v0.5.5-ubuntu20.04
        imagePullPolicy: Always
        env:
        - name: WITH_REBOOT
          value: "false"
        securityContext:
          privileged: true
        volumeMounts:
        - name: proc
          mountPath: /host/proc
        - name: dev
          mountPath: /host/dev
        command: ["nvidia-mig-parted"]
        args: ["-f", "/etc/mig-parted/config.yaml", "-apply-exit"]
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: dev  
        hostPath:
          path: /dev
      nodeSelector:
        nvidia.com/mig.config: mixed
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
EOF
        
        print_status "NVIDIA MIG Manager installed"
    else
        print_warning "Skipping NVIDIA MIG Manager installation"
    fi
fi

print_status "Setup complete!"
print_status "Summary of created files:"
for OLD_NODEGROUP_NAME in "${GPU_NODEGROUPS[@]}"; do
    # Skip already processed ones
    if [[ "$OLD_NODEGROUP_NAME" == *"-mig-enabled"* || "$OLD_NODEGROUP_NAME" == *"-mig-1g-"* || "$OLD_NODEGROUP_NAME" == *"-mig-2g-"* || "$OLD_NODEGROUP_NAME" == *"-mig-3g-"* ]]; then
        continue
    fi
    
    echo "  - old-nodegroup-${OLD_NODEGROUP_NAME}.yaml (original node group configuration)"
    
    # List all MIG partition node groups created
    for PARTITION_SIZE in "1g-5gb" "2g-10gb" "3g-20gb"; do
        BASE_NEW_NAME="${OLD_NODEGROUP_NAME}-mig-${PARTITION_SIZE}"
        if [ ${#BASE_NEW_NAME} -le 63 ]; then
            NEW_NODEGROUP_NAME="$BASE_NEW_NAME"
        else
            SUFFIX_LENGTH=$((${#PARTITION_SIZE} + 5))
            MAX_BASE_LENGTH=$((63 - $SUFFIX_LENGTH))
            TRUNCATED_BASE="${OLD_NODEGROUP_NAME:0:$MAX_BASE_LENGTH}"
            NEW_NODEGROUP_NAME="${TRUNCATED_BASE}-mig-${PARTITION_SIZE}"
        fi
        echo "  - new-nodegroup-${NEW_NODEGROUP_NAME}.yaml (new MIG-enabled node group configuration)"
    done
done

print_warning "Next steps:"
print_warning "1. Wait for new nodes to be ready"
print_warning "2. Scale up desired capacity for the new node groups as needed"
print_warning "3. Verify MIG devices with: kubectl debug node/<NODE_NAME> -it --image=busybox"
print_warning "4. Run 'nvidia-smi -L' on the node to see MIG devices"
print_warning "5. Test workloads using the new MIG-enabled node groups"
print_warning "6. Consider removing old non-MIG node groups after validation"