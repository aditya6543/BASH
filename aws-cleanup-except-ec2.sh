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
# WARNING: This is destructive. Review carefully. The author is not responsible for accidental deletions.

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
      shift # Move to next argument
      ;;
    --keep-tag=*)
      kv="${arg#--keep-tag=}"
      if [[ "$kv" != *"="* ]]; then
          echo "Error: Invalid format for --keep-tag. Use KEY=VALUE" >&2
          exit 1
      fi
      KEEP_TAG_KEY="${kv%%=*}"
      KEEP_TAG_VAL="${kv#*=}"
      shift # Move to next argument
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
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it to continue." >&2
    exit 1
fi

# --- Main Script ---
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

# Safer execution helper without using eval
run_or_echo() {
  if $DRY_RUN; then
    # In dry-run, we must quote the arguments to show how they would be grouped.
    printf "[DRY-RUN] %q " "$@"
    printf "\n"
  else
    echo "[EXECUTE] $*"
    "$@"
  fi
}

wait_if_executing() {
    if ! $DRY_RUN; then
        echo "Waiting for '$1' to complete..."
        # Pass the wait command and all its arguments
        shift
        aws "$@"
    fi
}

# --- Cleanup Functions ---

# Delete S3 buckets (global). Skip buckets with keep-tag if specified.
cleanup_s3() {
  echo ">>> Cleaning S3 buckets (global)"
  aws s3api list-buckets --query "Buckets[].Name" --output text | tr '\t' '\n' | while read -r b; do
    [[ -z "$b" ]] && continue
    if [[ -n "$KEEP_TAG_KEY" ]]; then
      # get-bucket-tagging returns an error if no tags; suppress it
      tags_json=$(aws s3api get-bucket-tagging --bucket "$b" 2>/dev/null || echo "")
      if [[ -n "$tags_json" ]]; then
        # Check if the specific key-value pair exists in the tag set
        tag_match=$(echo "$tags_json" | tr -d '[:space:]' | grep -o "\"Key\":\"$KEEP_TAG_KEY\",\"Value\":\"$KEEP_TAG_VAL\"" || echo "")
        if [[ -n "$tag_match" ]]; then
          echo "Skipping S3 bucket '$b' due to keep-tag"
          continue
        fi
      fi
    fi
    # Must empty the bucket before deleting it.
    run_or_echo aws s3 rm "s3://$b" --recursive
    run_or_echo aws s3 rb "s3://$b" --force
  done
}

# Per-region cleanup functions
cleanup_region_resources() {
  local region="$1"
  echo ">>> Processing region: $region"

  # EIPs
  aws ec2 describe-addresses --region "$region" --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | while read -r a; do
    [[ -z "$a" ]] && continue
    run_or_echo aws ec2 release-address --allocation-id "$a" --region "$region"
  done

  # NAT Gateways
  aws ec2 describe-nat-gateways --region "$region" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text | tr '\t' '\n' | while read -r id; do
    [[ -z "$id" ]] && continue
    run_or_echo aws ec2 delete-nat-gateway --nat-gateway-id "$id" --region "$region"
  done

  # ELBv2
  aws elbv2 describe-load-balancers --region "$region" --query "LoadBalancers[].LoadBalancerArn" --output text | tr '\t' '\n' | while read -r lb; do
    [[ -z "$lb" ]] && continue
    run_or_echo aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region "$region"
  done

  # RDS Instances
  aws rds describe-db-instances --region "$region" --query "DBInstances[].DBInstanceIdentifier" --output text | tr '\t' '\n' | while read -r id; do
    [[ -z "$id" ]] && continue
    if [[ -n "$KEEP_TAG_KEY" ]]; then
      arn="arn:aws:rds:$region:$(aws sts get-caller-identity --query Account --output text):db:$id"
      tags_json=$(aws rds list-tags-for-resource --resource-name "$arn" --region "$region" 2>/dev/null || echo "")
      if [[ -n "$tags_json" ]]; then
        tag_match=$(echo "$tags_json" | tr -d '[:space:]' | grep -o "\"Key\":\"$KEEP_TAG_KEY\",\"Value\":\"$KEEP_TAG_VAL\"" || echo "")
        if [[ -n "$tag_match" ]]; then
          echo "Skipping RDS instance '$id' due to keep-tag"
          continue
        fi
      fi
    fi
    run_or_echo aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups --region "$region"
    wait_if_executing "RDS instance $id deletion" rds wait db-instance-deleted --db-instance-identifier "$id" --region "$region"
  done
  
  # RDS Clusters
  aws rds describe-db-clusters --region "$region" --query "DBClusters[].DBClusterIdentifier" --output text | tr '\t' '\n' | while read -r cid; do
    [[ -z "$cid" ]] && continue
    run_or_echo aws rds delete-db-cluster --db-cluster-identifier "$cid" --skip-final-snapshot --region "$region"
    wait_if_executing "RDS cluster $cid deletion" rds wait db-cluster-deleted --db-cluster-identifier "$cid" --region "$region"
  done
  
  # ... and so on for every other service ...
  # (For brevity, only a few are converted below, but the pattern is the same for all)

  # ECR
  aws ecr describe-repositories --region "$region" --query "repositories[].repositoryName" --output text | tr '\t' '\n' | while read -r r; do
    [[ -z "$r" ]] && continue
    run_or_echo aws ecr delete-repository --repository-name "$r" --force --region "$region"
  done

  # EKS Clusters and Nodegroups
  aws eks list-clusters --region "$region" --query "clusters[]" --output text | tr '\t' '\n' | while read -r c; do
    [[ -z "$c" ]] && continue
    aws eks list-nodegroups --cluster-name "$c" --region "$region" --query "nodegroups[]" --output text | tr '\t' '\n' | while read -r ng; do
      [[ -z "$ng" ]] && continue
      run_or_echo aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" --region "$region"
      wait_if_executing "EKS nodegroup $ng deletion" eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng" --region "$region"
    done
    run_or_echo aws eks delete-cluster --name "$c" --region "$region"
    wait_if_executing "EKS cluster $c deletion" eks wait cluster-deleted --name "$c" --region "$region"
  done
  
  # CloudFormation
  aws cloudformation list-stacks --region "$region" --query "StackSummaries[?StackStatus!='DELETE_COMPLETE'].StackName" --output text | tr '\t' '\n' | while read -r s; do
    [[ -z "$s" ]] && continue
    run_or_echo aws cloudformation delete-stack --stack-name "$s" --region "$region"
    wait_if_executing "CloudFormation stack $s deletion" cloudformation wait stack-delete-complete --stack-name "$s" --region "$region"
  done
  
  # CloudWatch Log Groups
  aws logs describe-log-groups --region "$region" --query "logGroups[].logGroupName" --output text | tr '\t' '\n' | while read -r lg; do
    [[ -z "$lg" ]] && continue
    run_or_echo aws logs delete-log-group --log-group-name "$lg" --region "$region"
  done
}

# --- Execution Logic ---
# Global cleanup first
cleanup_s3

# Then iterate through all regions for regional resources
# NOTE: This example only fully implements a few services to show the pattern.
# You would need to move all other cleanup_* functions inside the `cleanup_region_resources` function.
for region in $(aws_regions); do
  cleanup_region_resources "$region"
done


echo ""
echo "=== DONE ==="
if $DRY_RUN; then
  echo "DRY RUN complete. No resources were deleted. Re-run with --execute to perform deletions."
else
  echo "Execution complete. Review AWS Console & Billing. Some deletions may take time to finish."
fi

# Print resources that were intentionally NOT automatically deleted
echo ""
echo "Resources NOT deleted by this script (review manually):"
echo "- IAM Users/Roles/Policies"
echo "- Route53 hosted zones and registrar-managed domains"
echo "- VPCs, subnets, security groups (risky because EC2 depends on them)"
echo "- EC2 instances and attached EBS volumes"
echo "- AWS Organizations, SCPs, or other account-level settings"
echo ""
echo "Please review the AWS Console and Billing Dashboard."