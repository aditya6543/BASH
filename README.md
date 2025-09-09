<div align="center">

🌊 AWS Universal Cleanup Script 🌊
(Non-EC2)

</div>

<div align="center">

</div>

This script is a powerful tool designed to perform an aggressive cleanup of common, non-EC2 resources across all available AWS regions. Its primary purpose is to help reduce cloud costs by finding and deleting lingering resources that are often forgotten after testing or development.

It's built with safety as a priority, defaulting to a "dry run" mode and providing a robust mechanism to protect specific resources from deletion.

⚠️ DANGER: EXTREMELY DESTRUCTIVE SCRIPT ⚠️
-  This script is designed to PERMANENTLY DELETE AWS resources.
-  When run in '--execute' mode, the actions are IRREVERSIBLE.
!  Always run in dry-run mode first to review what will be deleted.
!  Use the '--keep-tag' feature to protect critical infrastructure.
!  USE AT YOUR OWN RISK.

Table of Contents
✨ Features

❌ What It Does NOT Delete

📋 Prerequisites

🚀 Usage Guide

⚙️ Command-Line Flags

📜 License

✨ Features
The script systematically scans all AWS regions to find and delete resources.

<details>
<summary><strong>Click to expand the full list of targeted resources</strong></summary>

🌐 Global:

✅ S3 Buckets (attempts to empty them first)

📍 Per-Region:

✅ Unattached Elastic IPs (EIPs)

✅ NAT Gateways

✅ ELBv2 Load Balancers (ALB/NLB)

✅ RDS DB Instances & Clusters (skips final snapshot)

✅ Manual RDS Snapshots

✅ Redshift Clusters (skips final snapshot)

✅ ElastiCache Clusters & Snapshots

✅ EFS File Systems (and their mount targets)

✅ ECR Repositories (forced delete)

✅ EKS Clusters (and their nodegroups)

✅ ECS Clusters, Services, and Tasks

✅ Lambda Functions

✅ API Gateway v1 (REST) and v2 (HTTP/WebSocket)

✅ CloudFormation Stacks

✅ CodeCommit, CodeBuild, and CodePipeline resources

✅ SQS Queues, SNS Topics, and Step Functions State Machines

✅ CloudWatch Log Groups

✅ EC2 Snapshots not attached to a current AMI

✅ Active EMR Clusters

</details>

❌ What It Does NOT Delete (By Design)
To prevent breaking active environments, this script intentionally ignores:

❌ EC2 Instances

❌ EBS Volumes (especially those attached to instances)

❌ VPCs, Subnets, Security Groups, Route Tables (high risk of breaking dependencies)

❌ IAM Users, Roles, Policies, and Groups

❌ Route53 Hosted Zones and Records

❌ AWS Organizations or Account-level settings

🛡️ Any resource protected by the --keep-tag flag.

📋 Prerequisites
Bash: The script must be run with bash, not sh or dash.

AWS CLI v2: Ensure the AWS CLI is installed and accessible in your PATH.

Configured AWS Credentials: Your environment must have credentials with permissions to list and delete all the resources listed above. This can be done via:

aws configure (profile in ~/.aws/credentials)

Environment variables (AWS_ACCESS_KEY_ID, etc.)

An EC2 Instance Role

🚀 Usage Guide
1. Make the script executable
chmod +x aws-cleanup-except-ec2.sh

2. Run a Dry Run (Safe Mode ✅)
This is the recommended first step. It will print all the commands that would be executed without actually deleting anything. Review this "kill list" carefully.

./aws-cleanup-except-ec2.sh

Output will be prefixed with [DRY-RUN] in green.

3. Protect Critical Resources (Safety Shield 🛡️)
Use the --keep-tag flag to protect any resource with a specific tag. This is the script's most important safety feature.

# Dry run, but simulate skipping any resource tagged with 'Protect=true'
./aws-cleanup-except-ec2.sh --keep-tag "Protect=true"

You will see [SKIP] messages for any resources that have this tag.

4. Execute Deletion (Destructive Mode 🔥)
Once you have reviewed the dry run and are certain you want to proceed, add the --execute flag.

# Run deletion, but protect resources tagged 'Project=CriticalApp'
./aws-cleanup-except-ec2.sh --execute --keep-tag "Project=CriticalApp"

Output for deletion commands will be prefixed with [EXECUTE] in red.

⚙️ Command-Line Flags
--execute: Switches the script from its default dry-run mode to live execution mode.

--keep-tag KEY=VALUE: Specifies a tag to identify resources that should NOT be deleted.

--help, -h: Displays a brief usage message.

📜 License
This project is licensed under the MIT License.