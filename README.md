AWS Universal Cleanup Script (Non-EC2)
This script is a powerful tool designed to perform an aggressive cleanup of common, non-EC2 resources across all available AWS regions in an account. Its primary purpose is to help reduce cloud costs by finding and deleting lingering resources that are often forgotten after testing or development.

The script is built with safety as a priority, defaulting to a "dry run" mode and providing a mechanism to protect specific resources from deletion.

⚠️ EXTREMELY DESTRUCTIVE SCRIPT ⚠️
This script is designed to PERMANENTLY DELETE AWS resources. When run in --execute mode, the actions are irreversible.

Always run in dry-run mode first to review the resources targeted for deletion.

Use the --keep-tag feature to protect critical infrastructure.

The author is not responsible for any accidental data loss or infrastructure destruction. USE AT YOUR OWN RISK.

Features
The script systematically scans all AWS regions and deletes the following resources:

Global:

S3 Buckets (will attempt to empty them first)

Per-Region:

Unattached Elastic IPs (EIPs)

NAT Gateways

ELBv2 Load Balancers (ALB/NLB)

RDS DB Instances & Clusters (skips final snapshot)

Manual RDS Snapshots

Redshift Clusters (skips final snapshot)

ElastiCache Clusters & Snapshots

EFS File Systems (and their mount targets)

ECR Repositories (forced delete)

EKS Clusters (and their nodegroups)

ECS Clusters, Services, and Tasks

Lambda Functions

API Gateway v1 (REST) and v2 (HTTP/WebSocket)

CloudFormation Stacks

CodeCommit, CodeBuild, and CodePipeline resources

SQS Queues, SNS Topics, and Step Functions State Machines

CloudWatch Log Groups

EC2 Snapshots not attached to a current AMI

Active EMR Clusters

What It Does NOT Delete (By Design)
To prevent breaking active environments, this script intentionally ignores:

EC2 Instances

EBS Volumes (especially those attached to instances)

VPCs, Subnets, Security Groups, Route Tables (high risk of breaking dependencies)

IAM Users, Roles, Policies, and Groups

Route53 Hosted Zones and Records

AWS Organizations or Account-level settings

Any resource protected by the --keep-tag flag.

Prerequisites
Bash: The script must be run with bash, not sh or dash.

AWS CLI v2: Ensure the AWS CLI is installed and accessible in your PATH.

Configured AWS Credentials: Your environment must be configured with AWS credentials that have sufficient permissions to list and delete all the resources listed in the "Features" section. This can be done via:

aws configure (profile in ~/.aws/credentials)

Environment variables (AWS_ACCESS_KEY_ID, etc.)

An EC2 Instance Role

Usage
Make the script executable:

chmod +x aws-cleanup-except-ec2.sh

Dry Run (Safe Mode - Recommended First Step):
This will print all the commands that would be executed without actually deleting anything. Use this to review the "kill list".

./aws-cleanup-except-ec2.sh

Output will be prefixed with [DRY-RUN] in green.

Protecting Resources with a Tag:
The script's most important safety feature is the --keep-tag. Any resource that has this exact key-value tag will be skipped.

# Dry run, but simulate skipping any resource tagged with 'Protect=true'
./aws-cleanup-except-ec2.sh --keep-tag "Protect=true"

You will see [SKIP] messages for any resources that have this tag.

Execute Mode (DESTRUCTIVE):
Once you have reviewed the dry run and are certain you want to proceed, add the --execute flag.

Warning: This is the final step. There is no confirmation prompt after this.

# Run deletion, but protect resources tagged 'Project=CriticalApp'
./aws-cleanup-except-ec2.sh --execute --keep-tag "Project=CriticalApp"

Output for deletion commands will be prefixed with [EXECUTE] in red.

Command-Line Flags
--execute: Switches the script from its default dry-run mode to live execution mode.

--keep-tag KEY=VALUE: Specifies a tag to identify resources that should NOT be deleted. The script will skip any resource that has this tag.

--help, -h: Displays a brief usage message.

License
This project is licensed under the MIT License.