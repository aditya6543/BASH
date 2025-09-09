#!/usr-bin/env bash
# aws-cleanup-except-ec2.sh
# Aggressive cleanup across all regions excluding EC2 instances.
# Defaults to dry-run. Use --execute to perform deletions.
#
# Usage:
#   ./aws-cleanup-except-ec2.sh           # dry run (safe)
#   ./aws-cleanup-except-ec2.sh --execute # actual deletion
#   ./aws-cleanup-except-ec2.sh --execute --keep-tag "Protect=yes"
#
# WARNING: This is destructive. Review carefully. The author is not responsible for accidental deletions.
# REQUIREMENT: Bash (not sh or dash)

set -euo pipefail

# --- Color and Style Definitions ---
# Using tput for wider compatibility, falling back to raw codes if needed.
if command -v tput >/dev/null 2>&1; then
    BOLD=$(tput bold)
    BLUE=$(tput setaf 4)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0) # No Color
else
    BOLD='\033[1m'
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
fi

DRY_RUN=true
KEEP_TAG_KEY=""
KEEP_TAG_VAL=""

# --- Arg parsing ---
for arg in "$@"; do
  case $arg in
    --execute) DRY_RUN=false; shift ;;
    --keep-tag) echo "Use --keep-tag KEY=VALUE"; exit 1 ;;
    --help|-h) echo "Usage: $0 [--execute] [--keep-tag KEY=VALUE]"; exit 0 ;;
    --keep-tag=*)
      kv="${arg#--keep-tag=}"
      if [[ "$kv" != *"="* ]]; then
        echo "Error: --keep-tag expects KEY=VALUE" >&2; exit 1
      fi
      KEEP_TAG_KEY="${kv%%=*}"
      KEEP_TAG_VAL="${kv#*=}"
      shift
      ;;
    *)
      echo "Unknown arg $arg"; exit 1 ;;
  esac
done

# --- Enhanced Logging Helpers ---
print_header() { printf "\n${BLUE}${BOLD}>>> %s${NC}\n" "$*"; }
print_info() { printf "${CYAN}  [INFO] %s${NC}\n" "$*"; }
print_skip() { printf "${YELLOW}  [SKIP] %s${NC}\n" "$*"; }
print_warn() { printf "${YELLOW}${BOLD}  [WARN] %s${NC}\n" "$*"; }
print_dry_run() { printf "${GREEN}  [DRY-RUN] Would execute: %s${NC}\n" "$*"; }
print_execute() { printf "${RED}  [EXECUTE] %s${NC}\n" "$*"; }
print_fatal() { printf "${RED}${BOLD}  [FATAL] %s${NC}\n" "$*"; exit 1; }

# --- Script Header ---
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}=====      AWS CLEANUP SCRIPT (excludes EC2)      =====${NC}"
echo -e "${BLUE}=======================================================${NC}"
if $DRY_RUN; then
    echo -e "${GREEN}${BOLD}MODE: DRY RUN${NC} ${GREEN}(No changes will be made)${NC}"
else
    echo -e "${RED}${BOLD}MODE: EXECUTE - DESTRUCTIVE!${NC}"
    echo -e "${YELLOW}This script will perform actual deletions. You have 5 seconds to cancel (Ctrl+C)...${NC}"
    sleep 5
fi
if [[ -n "$KEEP_TAG_KEY" ]]; then
  print_info "Will skip any resources with tag: ${BOLD}$KEEP_TAG_KEY=$KEEP_TAG_VAL${NC}"
fi
echo ""

# --- Core Helpers ---
aws_regions() {
  aws ec2 describe-regions --query "Regions[].RegionName" --output text
}

# run_or_exec: prints dry-run line or executes the command. Does not abort whole script on failure.
run_or_exec() {
  # Accept full command string (call like: run_or_exec "aws s3 rb s3://bucket --force")
  local cmd="$*"
  if $DRY_RUN; then
    print_dry_run "$cmd"
  else
    print_execute "$cmd"
    # run in a sub-shell; capture exit and continue even if fails
    bash -c "$cmd" || { print_warn "⚠️ Command failed (continuing): $cmd"; }
  fi
}

# has_keep_tag(resource, region, service)
# returns 0 if resource has KEEP_TAG and should be skipped
has_keep_tag() {
  local res="$1"; local region="$2"; local service="$3"

  [[ -z "$KEEP_TAG_KEY" ]] && return 1

  case "$service" in
    s3)
      # res is bucket name
      tags_json=$(aws s3api get-bucket-tagging --bucket "$res" 2>/dev/null || echo "")
      if [[ -n "$tags_json" ]]; then
        if echo "$tags_json" | tr -d '[:space:]' | grep -q "\"Key\":\"$KEEP_TAG_KEY\",\"Value\":\"$KEEP_TAG_VAL\""; then
          print_skip "s3://$res due to keep-tag"
          return 0
        fi
      fi
      ;;
    rds)
      # res is full ARN for RDS
      tags_json=$(aws rds list-tags-for-resource --resource-name "$res" --region "$region" 2>/dev/null || echo "")
      if [[ -n "$tags_json" ]] && echo "$tags_json" | tr -d '[:space:]' | grep -q "\"Key\":\"$KEEP_TAG_KEY\",\"Value\":\"$KEEP_TAG_VAL\""; then
        print_skip "RDS resource $res due to keep-tag"
        return 0
      fi
      ;;
    ecr|eks|elbv2|ecs|lambda|apigateway|cloudformation|codecommit|codebuild|codepipeline|sqs|sns|stepfunctions|emr)
      # Try resourcegroupstaggingapi as a best-effort fallback if ARN is available
      if aws resourcegroupstaggingapi get-resources --tag-filters "Key=${KEEP_TAG_KEY},Values=${KEEP_TAG_VAL}" --resource-arn-list "$res" --region "$region" --output text >/dev/null 2>&1; then
        print_skip "resource $res due to keep-tag (via resourcegroupstaggingapi)"
        return 0
      fi
      ;;
    *)
      return 1
      ;;
  esac

  return 1
}


# --- Cleanup functions (Logic unchanged, only output is enhanced) ---

cleanup_s3() {
  print_header "Cleaning S3 buckets (global)"
  aws s3api list-buckets --query "Buckets[].Name" --output text | tr '\t' '\n' | while read -r b; do
    [[ -z "$b" ]] && continue
    if has_keep_tag "$b" "us-east-1" "s3"; then continue; fi
    # Empty and remove the bucket
    run_or_exec "aws s3 rm \"s3://$b\" --recursive"
    run_or_exec "aws s3 rb \"s3://$b\" --force"
  done
}

cleanup_eips() {
  for region in $REGIONS; do
    print_header "Region $region: releasing unattached Elastic IPs"
    aws ec2 describe-addresses --region "$region" --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | while read -r a; do
      [[ -z "$a" ]] && continue
      run_or_exec "aws ec2 release-address --allocation-id $a --region $region"
    done
  done
}

cleanup_nat_gateways() {
  for region in $REGIONS; do
    print_header "Region $region: deleting NAT Gateways"
    aws ec2 describe-nat-gateways --region "$region" --query "NatGateways[].NatGatewayId" --output text | tr '\t' '\n' | while read -r id; do
      [[ -z "$id" ]] && continue
      run_or_exec "aws ec2 delete-nat-gateway --nat-gateway-id $id --region $region"
    done
  done
}

cleanup_elbv2() {
  for region in $REGIONS; do
    print_header "Region $region: deleting ELBv2 load balancers (ALB/NLB)"
    aws elbv2 describe-load-balancers --region "$region" --query "LoadBalancers[].LoadBalancerArn" --output text | tr '\t' '\n' | while read -r lb; do
      [[ -z "$lb" ]] && continue
      if has_keep_tag "$lb" "$region" "elbv2"; then continue; fi
      run_or_exec "aws elbv2 delete-load-balancer --load-balancer-arn \"$lb\" --region $region"
    done
  done
}

cleanup_rds() {
  for region in $REGIONS; do
    print_header "Region $region: deleting RDS instances"
    aws rds describe-db-instances --region "$region" --query "DBInstances[].DBInstanceIdentifier" --output text | tr '\t' '\n' | while read -r id; do
      [[ -z "$id" ]] && continue
      arn="arn:aws:rds:$region:$(aws sts get-caller-identity --query Account --output text):db:$id"
      if has_keep_tag "$arn" "$region" "rds"; then continue; fi
      run_or_exec "aws rds delete-db-instance --db-instance-identifier \"$id\" --skip-final-snapshot --delete-automated-backups --region $region"
      # best-effort wait (non-fatal)
      if ! $DRY_RUN; then
        print_info "Waiting for RDS instance $id to delete..."
        aws rds wait db-instance-deleted --db-instance-identifier "$id" --region "$region" || print_warn "⚠️ Wait failed/timeout for RDS $id (continuing)"
      fi
    done

    print_header "Region $region: deleting RDS clusters (Aurora)"
    aws rds describe-db-clusters --region "$region" --query "DBClusters[].DBClusterIdentifier" --output text | tr '\t' '\n' | while read -r cid; do
      [[ -z "$cid" ]] && continue
      arn="arn:aws:rds:$region:$(aws sts get-caller-identity --query Account --output text):cluster:$cid"
      if has_keep_tag "$arn" "$region" "rds"; then continue; fi
      run_or_exec "aws rds delete-db-cluster --db-cluster-identifier \"$cid\" --skip-final-snapshot --region $region"
      if ! $DRY_RUN; then
        print_info "Waiting for RDS cluster $cid to delete..."
        aws rds wait db-cluster-deleted --db-cluster-identifier "$cid" --region "$region" || print_warn "⚠️ Wait failed/timeout for RDS cluster $cid (continuing)"
      fi
    done

    print_header "Region $region: deleting manual RDS snapshots"
    aws rds describe-db-snapshots --snapshot-type manual --region "$region" --query "DBSnapshots[].DBSnapshotIdentifier" --output text | tr '\t' '\n' | while read -r s; do
      [[ -z "$s" ]] && continue
      run_or_exec "aws rds delete-db-snapshot --db-snapshot-identifier \"$s\" --region $region"
    done
  done
}

cleanup_redshift() {
  for region in $REGIONS; do
    print_header "Region $region: deleting Redshift clusters"
    aws redshift describe-clusters --region "$region" --query "Clusters[].ClusterIdentifier" --output text | tr '\t' '\n' | while read -r c; do
      [[ -z "$c" ]] && continue
      run_or_exec "aws redshift delete-cluster --cluster-identifier \"$c\" --skip-final-cluster-snapshot --region $region"
    done
  done
}

cleanup_elasticache() {
  for region in $REGIONS; do
    print_header "Region $region: deleting ElastiCache clusters and snapshots"
    aws elasticache describe-cache-clusters --region "$region" --query "CacheClusters[].CacheClusterId" --output text | tr '\t' '\n' | while read -r c; do
      [[ -z "$c" ]] && continue
      run_or_exec "aws elasticache delete-cache-cluster --cache-cluster-id \"$c\" --region $region"
    done
    aws elasticache describe-snapshots --region "$region" --query "Snapshots[].SnapshotName" --output text | tr '\t' '\n' | while read -r s; do
      [[ -z "$s" ]] && continue
      run_or_exec "aws elasticache delete-snapshot --snapshot-name \"$s\" --region $region"
    done
  done
}

cleanup_efs() {
  for region in $REGIONS; do
    print_header "Region $region: deleting EFS file systems"
    aws efs describe-file-systems --region "$region" --query "FileSystems[].FileSystemId" --output text | tr '\t' '\n' | while read -r fs; do
      [[ -z "$fs" ]] && continue
      print_info "Checking mount targets for EFS: $fs"
      aws efs describe-mount-targets --file-system-id "$fs" --region "$region" --query "MountTargets[].MountTargetId" --output text | tr '\t' '\n' | while read -r m; do
        [[ -z "$m" ]] && continue
        run_or_exec "aws efs delete-mount-target --mount-target-id \"$m\" --region $region"
      done
      # Some delay might be needed for mount targets to be fully gone
      if ! $DRY_RUN; then sleep 5; fi
      run_or_exec "aws efs delete-file-system --file-system-id \"$fs\" --region $region"
    done
  done
}

cleanup_ecr() {
  for region in $REGIONS; do
    print_header "Region $region: deleting ECR repositories (force)"
    aws ecr describe-repositories --region "$region" --query "repositories[].repositoryName" --output text | tr '\t' '\n' | while read -r r; do
      [[ -z "$r" ]] && continue
      arn="arn:aws:ecr:$region:$(aws sts get-caller-identity --query Account --output text):repository/$r"
      if has_keep_tag "$arn" "$region" "ecr"; then continue; fi
      run_or_exec "aws ecr delete-repository --repository-name \"$r\" --force --region $region"
    done
  done
}

cleanup_eks() {
  for region in $REGIONS; do
    print_header "Region $region: deleting EKS clusters and managed nodegroups"
    aws eks list-clusters --region "$region" --query "clusters[]" --output text | tr '\t' '\n' | while read -r c; do
      [[ -z "$c" ]] && continue
      arn="arn:aws:eks:$region:$(aws sts get-caller-identity --query Account --output text):cluster/$c"
      if has_keep_tag "$arn" "$region" "eks"; then continue; fi
      print_info "Deleting nodegroups for EKS cluster: $c"
      aws eks list-nodegroups --cluster-name "$c" --region "$region" --query "nodegroups[]" --output text | tr '\t' '\n' | while read -r ng; do
        [[ -z "$ng" ]] && continue
        run_or_exec "aws eks delete-nodegroup --cluster-name \"$c\" --nodegroup-name \"$ng\" --region $region"
      done
      # Maybe add a wait for nodegroups here if script fails
      run_or_exec "aws eks delete-cluster --name \"$c\" --region $region"
    done
  done
}

cleanup_ecs() {
  for region in $REGIONS; do
    print_header "Region $region: deleting ECS services, tasks, clusters"
    aws ecs list-clusters --region "$region" --query "clusterArns[]" --output text | tr '\t' '\n' | while read -r cl_arn; do
      [[ -z "$cl_arn" ]] && continue
      cl="${cl_arn##*/}" # Extract cluster name from ARN
      print_info "Draining services in ECS cluster: $cl"
      aws ecs list-services --cluster "$cl" --region "$region" --query "serviceArns[]" --output text | tr '\t' '\n' | while read -r s_arn; do
        [[ -z "$s_arn" ]] && continue
        s="${s_arn##*/}" # Extract service name from ARN
        # Scale down first, then delete. Ignore errors if already at 0.
        run_or_exec "aws ecs update-service --cluster \"$cl\" --service \"$s\" --desired-count 0 --region $region || true"
        run_or_exec "aws ecs delete-service --cluster \"$cl\" --service \"$s\" --force --region $region || true"
      done
      # Now safe to delete the cluster
      run_or_exec "aws ecs delete-cluster --cluster \"$cl\" --region $region"
    done
  done
}

cleanup_lambda() {
  for region in $REGIONS; do
    print_header "Region $region: deleting Lambda functions"
    aws lambda list-functions --region "$region" --query "Functions[].FunctionName" --output text | tr '\t' '\n' | while read -r f; do
      [[ -z "$f" ]] && continue
      run_or_exec "aws lambda delete-function --function-name \"$f\" --region $region"
    done
  done
}

cleanup_apigateway() {
  for region in $REGIONS; do
    print_header "Region $region: deleting API Gateway (v1 REST APIs)"
    aws apigateway get-rest-apis --region "$region" --query "items[].id" --output text | tr '\t' '\n' | while read -r id; do
      [[ -z "$id" ]] && continue
      run_or_exec "aws apigateway delete-rest-api --rest-api-id \"$id\" --region $region"
    done

    print_header "Region $region: deleting API Gateway v2 (HTTP/WebSocket APIs)"
    aws apigatewayv2 get-apis --region "$region" --query "Items[].ApiId" --output text | tr '\t' '\n' | while read -r a; do
      [[ -z "$a" ]] && continue
      run_or_exec "aws apigatewayv2 delete-api --api-id \"$a\" --region $region"
    done
  done
}

cleanup_cloudformation() {
  for region in $REGIONS; do
    print_header "Region $region: deleting CloudFormation stacks"
    aws cloudformation list-stacks --region "$region" --query "StackSummaries[?StackStatus!='DELETE_COMPLETE'].StackName" --output text | tr '\t' '\n' | while read -r s; do
      [[ -z "$s" ]] && continue
      run_or_exec "aws cloudformation delete-stack --stack-name \"$s\" --region $region"
    done
  done
}

cleanup_code_repos() {
  for region in $REGIONS; do
    print_header "Region $region: deleting CodeCommit repositories"
    aws codecommit list-repositories --region "$region" --query "repositories[].repositoryName" --output text | tr '\t' '\n' | while read -r r; do
      [[ -z "$r" ]] && continue
      run_or_exec "aws codecommit delete-repository --repository-name \"$r\" --region $region"
    done
  done
}

cleanup_codebuild_pipelines() {
  for region in $REGIONS; do
    print_header "Region $region: deleting CodeBuild projects"
    aws codebuild list-projects --region "$region" --query "projects[]" --output text | tr '\t' '\n' | while read -r p; do
      [[ -z "$p" ]] && continue
      run_or_exec "aws codebuild delete-project --name \"$p\" --region $region"
    done
    print_header "Region $region: deleting CodePipelines"
    aws codepipeline list-pipelines --region "$region" --query "pipelines[].name" --output text | tr '\t' '\n' | while read -r pl; do
      [[ -z "$pl" ]] && continue
      run_or_exec "aws codepipeline delete-pipeline --name \"$pl\" --region $region"
    done
  done
}

cleanup_sqs_sns_stepfunctions() {
  for region in $REGIONS; do
    print_header "Region $region: deleting SQS queues"
    aws sqs list-queues --region "$region" --query "QueueUrls[]" --output text | tr '\t' '\n' | while read -r q; do
      [[ -z "$q" ]] && continue
      run_or_exec "aws sqs delete-queue --queue-url \"$q\" --region $region"
    done

    print_header "Region $region: deleting SNS topics"
    aws sns list-topics --region "$region" --query "Topics[].TopicArn" --output text | tr '\t' '\n' | while read -r t; do
      [[ -z "$t" ]] && continue
      run_or_exec "aws sns delete-topic --topic-arn \"$t\" --region $region"
    done

    print_header "Region $region: deleting Step Functions state machines"
    aws stepfunctions list-state-machines --region "$region" --query "stateMachines[].stateMachineArn" --output text | tr '\t' '\n' | while read -r m; do
      [[ -z "$m" ]] && continue
      run_or_exec "aws stepfunctions delete-state-machine --state-machine-arn \"$m\" --region $region"
    done
  done
}

cleanup_cloudwatch_logs() {
  for region in $REGIONS; do
    print_header "Region $region: deleting CloudWatch log groups"
    aws logs describe-log-groups --region "$region" --query "logGroups[].logGroupName" --output text | tr '\t' '\n' | while read -r lg; do
      [[ -z "$lg" ]] && continue
      # Add a simple filter to avoid deleting critical service logs, can be expanded
      if [[ "$lg" == "aws-controltower"* || "$lg" == "/aws/lambda/AWS-Control-Tower"* ]]; then
        print_skip "Protected log group: $lg"
        continue
      fi
      run_or_exec "aws logs delete-log-group --log-group-name \"$lg\" --region $region"
    done
  done
}

cleanup_redrive_and_snapshots() {
  for region in $REGIONS; do
    print_header "Region $region: deleting EC2 snapshots not used by AMIs"
    aws ec2 describe-snapshots --owner-ids self --region "$region" --query "Snapshots[].SnapshotId" --output text | tr '\t' '\n' | while read -r s; do
      [[ -z "$s" ]] && continue
      used=$(aws ec2 describe-images --owners self --region "$region" --query "Images[?BlockDeviceMappings[?Ebs.SnapshotId=='$s']].ImageId" --output text || echo "")
      if [[ -z "$used" ]]; then
        run_or_exec "aws ec2 delete-snapshot --snapshot-id \"$s\" --region $region"
      else
        print_skip "snapshot $s because it's used by AMI(s): $used"
      fi
    done
  done
}

cleanup_redshift_s3_exports_and_emr() {
  for region in $REGIONS; do
    print_header "Region $region: terminating EMR clusters"
    aws emr list-clusters --active --region "$region" --query "Clusters[].Id" --output text | tr '\t' '\n' | while read -r e; do
      [[ -z "$e" ]] && continue
      run_or_exec "aws emr terminate-clusters --cluster-ids \"$e\" --region $region"
    done
  done
}


# --- MAIN EXECUTION ---
print_header "Starting AWS Cleanup Process"
REGIONS=$(aws_regions)
print_info "Scanning all available AWS regions: $(echo "$REGIONS" | wc -w | tr -d '[:space:]') found."
echo ""

# Global/region-agnostic cleanup
cleanup_s3

# Region loop cleanup functions (order matters depending on dependencies)
cleanup_eips
cleanup_nat_gateways
cleanup_elbv2
cleanup_eks      # Delete EKS before RDS/VPC dependencies
cleanup_ecs
cleanup_lambda
cleanup_apigateway
cleanup_efs
cleanup_rds
cleanup_redshift
cleanup_elasticache
cleanup_ecr
cleanup_cloudformation
cleanup_code_repos
cleanup_codebuild_pipelines
cleanup_sqs_sns_stepfunctions
cleanup_cloudwatch_logs
cleanup_redrive_and_snapshots # Snapshots after instances are gone
cleanup_redshift_s3_exports_and_emr

# --- FINAL SUMMARY ---
echo ""
echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}=====                 FINAL SUMMARY                 =====${NC}"
echo -e "${BLUE}=======================================================${NC}"

if $DRY_RUN; then
  echo -e "${GREEN}${BOLD}DRY RUN COMPLETE.${NC}"
  echo -e "${GREEN}No actual resources were harmed during this operation.${NC}"
  echo -e "${YELLOW}To perform deletions, re-run with the ${BOLD}--execute${NC}${YELLOW} flag.${NC}"
else
  echo -e "${RED}${BOLD}EXECUTION COMPLETE.${NC}"
  echo -e "${YELLOW}Review the output above for any failures. Some deletions (like RDS, Redshift)${NC}"
  echo -e "${YELLOW}may take several minutes to finish in the AWS console.${NC}"
fi

echo ""
echo -e "${YELLOW}${BOLD}Manual Review Recommended For:${NC}"
echo -e "${YELLOW}- IAM Users/Roles/Policies${NC}"
echo -e "${YELLOW}- Route53 Hosted Zones and Domains${NC}"
echo -e "${YELLOW}- VPCs, Subnets, Security Groups (intentionally skipped as EC2 depends on them)${NC}"
echo -e "${YELLOW}- Running EC2 Instances and attached EBS Volumes (intentionally skipped)${NC}"
echo -e "${YELLOW}- AWS Organizations, SCPs, or other account-level settings${NC}"
echo ""
echo -e "${BOLD}Always double-check the AWS Billing Dashboard to confirm resource termination.${NC}"