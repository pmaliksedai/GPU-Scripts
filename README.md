# GPU-Scripts

Automated GKE Node Pool MIG Setup with Dynamic Resource Allocation (DRA) support.

## Quick Start

```bash
./gke-nodepool-mig-setup.sh <CLUSTER_NAME> <REGION>
```

## Features

- **Automatic GPU node pool discovery** - Finds existing A100, A30, H100, L40S pools
- **Complete configuration preservation** - Maintains all original pool settings
- **Smart duplicate prevention** - Skips existing MIG-enabled pools
- **DRA driver installation** - Sets up NVIDIA DRA driver with quota fix
- **ResourceClass creation** - Creates MIG profile definitions
- **Interactive operation** - Prompts for confirmation at key steps

## Documentation

See [GKE-MIG-Setup-Documentation.md](./GKE-MIG-Setup-Documentation.md) for complete details.

## Recent Updates

- Fixed DRA driver priority class quota issues
- Added smart pool name truncation for 40-char limit  
- Enhanced error handling and duplicate prevention
- Updated to use NVIDIA DRA driver v25.8.1
