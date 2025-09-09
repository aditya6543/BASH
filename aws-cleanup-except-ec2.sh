#!/usr/bin/env bash
# aws-cleanup-except-ec2.sh
# Aggressive cleanup across all regions excluding EC2 instances.
# Defaults to dry-run. Use --execute to perform deletions.
#
# Usage:
#   ./aws-cleanup-except-ec2.sh              # dry run (safe)
#   ./aws-cleanup-except-ec2.sh --execute    # actual deletion
#   ./aws-cleanup-except-ec2.sh --execute --keep-tag "Protect=yes"
#
# WARNING: This is destructive. Review carefully.
# The author is not responsible for accidental deletions.
#
# REQUIREMENT: Bash (not sh or dash)

set -euo pipefail

# --- Configuration ---
DRY_RUN=true
KEEP_TAG_KEY=""
KEEP_TAG_VAL=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  arg="$1"
  case $arg in
    --execute)
      DRY_RUN=false
      shift
      ;;
    --keep-tag=*)
      kv="${arg#--keep-tag=}"
      if [[ "$kv" != *"="* ]]; then
        echo "Error: Invalid format for --keep-tag. Use KEY=VALUE" >&2
        exit 1
      fi
      KEEP_TAG_KEY="${kv%%=*}"
      KEEP_TAG_VAL="${kv#*=}"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--execute] [--keep-tag KEY=VALUE]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Prerequisite Check ---
if ! command -v aws &>/dev/null; then
  echo "Error: AWS CLI is not installed. Please install it to continue." >&2
  exit 1
fi

echo "=== AWS CLEANUP SCRIPT (excludes EC2) ==="
echo "DRY_RUN: $DRY_RUN"
if [[ -n "$KEEP_TAG_KEY" ]]; then
  echo "Will skip resources with tag: $KEEP_TAG_KEY=$KEEP_TAG_VAL"
fi
echo ""

# --- Helper Functions ---
aws_regions() {
  aws ec2 describe-regions --query "Regions[].RegionName" --output text
}

run_or_echo() {
  if $DRY_RUN; then
    printf "[DRY-RUN] %q " "$@"
    printf "\n"
  else
    echo "[EXECUTE] $*"
    "$@" || { echo "⚠️ Command failed, skipping: $*" >&2; }
  fi
}

wait_if_executing() {
  if ! $DRY_RUN; then
    desc="$1"; shift
    echo "Waiting for $desc..."
    aws "$@" || { echo "⚠️ Wait failed for $desc, continuing..." >&2; }
  fi
}

# --- Tag Filter Helper ---
check_keep_tag() {
  local resource_arn="$1"
  local region="$2"
  local service="$3" # e.g., rds, s3, eks
  [[ -z "$KEEP_TAG_KEY" ]] && return 1  # no filter → not skipped

  case "$service" in
    s3)
      tags_json=$(aws s3api get-bucket-tagging --bucket "$resource_arn" 2>/dev/null || echo "")
      ;;
    rds)
      tags_json=$(aws rds list-tags-for-resource --resource-name "$resource_arn" --region "$region" 2>/dev/null || echo "")
      ;;
    eks)
      tags_json=$(aws eks list-tags-for-resource --resource-arn "$resource_arn" --region "$region" 2>/dev/null || echo "")
      ;;
    elbv2)
      tags_json=$(aws elbv2 describe-tags --resource-arns "$resource_arn" --region "$region" 2>/dev/null || echo "")
      ;;
    ecr)
      tags_json=$(aws ecr list-tags-for-resource --resource-arn "$resource_arn" --region "$region" 2>/dev/null || echo "")
      ;;
    *)
      return 1
      ;;
  esac

  if [[ -n "$tags_json" ]]; then
    match=$(echo "$tags_json" | tr -d '[:space:]' | grep -o "\"Key\":\"$KEEP_TAG_KEY\",\"Value\":\"$KEEP_TAG_VAL\"" || echo "")
    if [[ -n "$match" ]]; then
      echo "Skipping $service resource ($resource_arn) due to keep-tag"
      return 0
    fi
  fi

  return 1
}

# --- Cleanup Functions ---
cleanup_s3() {
  echo ">>> Cleaning S3 buckets (global)"
  aws s3api list-buckets --query "Buckets[].Name" --output text | tr '\t' '\n' | while read -r b; do
    [[ -z "$b" ]] && continue
    if check_keep_tag "$b" "us-east-1" "s3"; then continue; fi
    run_or_echo aws s3 rm "s3://$b" --recursive
    run_or_echo aws s3 rb "s3://$b" --force
  done
}

cleanup_region_resources() {
  local region="$1"
  echo ">>> Processing region: $region"

  # Elastic IPs
  aws ec2 describe-addresses --region "$region" --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | while read -r a; do
    [[ -z "$a" ]] && continue
    run_or_echo aws ec2 release-address --allocation-id "$a" --region "$region"
  done

  # NAT Gateways
  aws ec2 describe-nat-gateways --region "$region" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text | tr '\t' '\n' | while read -r id; do
    [[ -z "$id" ]] && continue
    run_or_echo aws ec2 delete-nat-gateway --nat-gateway-id "$id" --region "$region"
  done

  # RDS Instances
  aws rds describe-db-instances --region "$region" --query "DBInstances[].DBInstanceIdentifier" --output text | tr '\t' '\n' | while read -r id; do
    [[ -z "$id" ]] && continue
    arn="arn:aws:rds:$region:$(aws sts get-caller-identity --query Account --output text):db:$id"
    if check_keep_tag "$arn" "$region" "rds"; then continue; fi
    run_or_echo aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups --region "$region"
    wait_if_executing "RDS instance $id" rds wait db-instance-deleted --db-instance-identifier "$id" --region "$region"
  done

  # RDS Clusters
  aws rds describe-db-clusters --region "$region" --query "DBClusters[].DBClusterIdentifier" --output text | tr '\t' '\n' | while read -r cid; do
    [[ -z "$cid" ]] && continue
    arn="arn:aws:rds:$region:$(aws sts get-caller-identity --query Account --output text):cluster:$cid"
    if check_keep_tag "$arn" "$region" "rds"; then continue; fi
    run_or_echo aws rds delete-db-cluster --db-cluster-identifier "$cid" --skip-final-snapshot --region "$region"
    wait_if_executing "RDS cluster $cid" rds wait db-cluster-deleted --db-cluster-identifier "$cid" --region "$region"
  done

  # ECR
  aws ecr describe-repositories --region "$region" --query "repositories[].repositoryName" --output text | tr '\t' '\n' | while read -r r; do
    [[ -z "$r" ]] && continue
    arn="arn:aws:ecr:$region:$(aws sts get-caller-identity --query Account --output text):repository/$r"
    if check_keep_tag "$arn" "$region" "ecr"; then continue; fi
    run_or_echo aws ecr delete-repository --repository-name "$r" --force --region "$region"
  done

  # EKS
  aws eks list-clusters --region "$region" --query "clusters[]" --output text | tr '\t' '\n' | while read -r c; do
    [[ -z "$c" ]] && continue
    arn="arn:aws:eks:$region:$(aws sts get-caller-identity --query Account --output text):cluster/$c"
    if check_keep_tag "$arn" "$region" "eks"; then continue; fi
    aws eks list-nodegroups --cluster-name "$c" --region "$region" --query "nodegroups[]" --output text | tr '\t' '\n' | while read -r ng; do
      [[ -z "$ng" ]] && continue
      run_or_echo aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" --region "$region"
      wait_if_executing "EKS nodegroup $ng" eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng" --region "$region"
    done
    run_or_echo aws eks delete-cluster --name "$c" --region "$region"
    wait_if_executing "EKS cluster $c" eks wait cluster-deleted --name "$c" --region "$region"
  done
}

# --- Execution ---
cleanup_s3
for region in $(aws_regions); do
  cleanup_region_resources "$region"
done

echo ""
echo "=== DONE ==="
if $DRY_RUN; then
  echo "Dry run complete. No resources were deleted. Re-run with --execute to perform deletions."
else
  echo "Execution complete. Some deletions may take time to finish."
fi

echo ""
echo "Resources NOT deleted by this script:"
echo "- IAM Users/Roles/Policies"
echo "- Route53 hosted zones and domains"
echo "- VPCs, subnets, security groups"
echo "- EC2 instances and attached EBS volumes"
echo "- AWS Organizations / account-level settings"
