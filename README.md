AWS Environment Cleanup Utility
<p align="center">
<strong>A robust, automated script for comprehensive AWS resource cleanup and cost management.</strong>
</p>

<p align="center">
<img src="https://www.google.com/search?q=https://img.shields.io/badge/Shell_Script-121011%3Fstyle%3Dfor-the-badge%26logo%3Dgnu-bash%26logoColor%3Dwhite" alt="Language: Bash" />
<img src="https://www.google.com/search?q=https://img.shields.io/badge/AWS-232F3E%3Fstyle%3Dfor-the-badge%26logo%3Damazon-aws%26logoColor%3Dwhite" alt="Platform: AWS" />
<img src="https://www.google.com/search?q=https://img.shields.io/badge/License-MIT-yellow.svg%3Fstyle%3Dfor-the-badge" alt="License: MIT" />
</p>

This utility provides a powerful solution for organizations to maintain clean and cost-effective AWS accounts by systematically removing unused and non-critical resources. It is designed with safety as a primary concern, defaulting to a dry-run mode and offering tag-based exclusion to protect essential assets.

The script is ideal for managing non-production environments (Dev, QA, Staging) where resource sprawl can lead to significant, unnecessary costs.

Table of Contents
Urgent Security Warning

Core Features

Business Use Cases

System Prerequisites

Installation and Configuration

Operational Guide

Scope of Operations

Contributing

License

⚠️ Urgent Security Warning
RISK OF PERMANENT DATA LOSS

This script is a powerful and destructive tool designed to permanently delete resources from your AWS account. Operations are irreversible.

Mandatory First Step: Always execute in the default dry-run mode to audit the list of resources targeted for deletion.

Verify Target Account: Ensure your AWS CLI is configured for the correct account and region before execution.

Implement Safeguards: Utilize the --keep-tag functionality to create a clear "safe list" of resources that must not be deleted.

Disclaimer of Liability: The use of this script is entirely at your own risk. The authors and contributors are not liable for any data loss or financial damages incurred.

Core Features
Operational Safety: Defaults to a secure dry-run mode. The --execute flag is required for all destructive operations.

Global & Regional Scope: Automatically discovers and operates across all active AWS regions to ensure comprehensive cleanup.

Resource Exclusion: Protect critical assets from deletion using a simple, tag-based exclusion mechanism (--keep-tag KEY=VALUE).

Intelligent Operation: Intentionally preserves core infrastructure such as EC2 instances, VPCs, Subnets, and IAM roles to prevent service disruption.

Asynchronous Handling: Employs AWS CLI wait commands to manage dependencies and ensure long-running deletions complete successfully.

Business Use Cases
Cost Optimization: Drastically reduce monthly AWS bills by eliminating orphaned and unused resources in development and testing accounts.

Security Hygiene: Reduce the potential attack surface by removing old, unpatched, or unmonitored resources.

Environment Management: Easily reset testing or QA environments to a clean slate, ensuring repeatable and consistent deployments.

System Prerequisites
Bash Environment: Version 4.0 or newer.

AWS CLI: Version 2.x is required.

Configured AWS Credentials: The script uses the AWS credentials configured in your environment. For details, see the AWS CLI Configuration Guide.

Installation and Configuration
Clone the Repository:

git clone <your-repo-url>
cd <your-repo-directory>

Set Execute Permissions:

chmod +x aws-cleanup-except-ec2.sh

Configure AWS Profile (Optional):
The script uses your default AWS CLI profile. To use a specific profile, set the AWS_PROFILE environment variable:

export AWS_PROFILE="your-profile-name"

Operational Guide
Step 1: Audit Resources (Dry Run)
Execute the script in its default mode to generate a non-destructive report of resources that will be deleted.

./aws-cleanup-except-ec2.sh

Sample Output:

=== AWS CLEANUP SCRIPT (excludes EC2) ===
DRY_RUN: true

>>> Processing region: us-east-1
[DRY-RUN] aws ec2 release-address --allocation-id eipalloc-0123456789abcdef --region us-east-1
[DRY-RUN] aws rds delete-db-instance --db-instance-identifier my-test-db --skip-final-snapshot --region us-east-1
...

Step 2: Execute Deletion
After carefully reviewing the dry-run output, proceed with the deletion using the --execute flag.

./aws-cleanup-except-ec2.sh --execute

Step 3: Protect Critical Assets (Recommended)
To exclude specific resources from deletion, apply a consistent tag (e.g., Status=Protected) to them in the AWS Console and use the --keep-tag flag.

# This command will not touch any resource tagged with "Status=Protected"
./aws-cleanup-except-ec2.sh --execute --keep-tag "Status=Protected"

Scope of Operations
The script is architected to be both comprehensive and safe. The following tables outline what is and is not in scope for deletion.

✅ Resources Targeted for Deletion

Details

S3

Buckets and Objects

EC2-related

Unattached Elastic IPs, NAT Gateways, Unused Snapshots

Databases

RDS Instances/Clusters, Redshift, ElastiCache

Containers

EKS Clusters/Nodegroups, ECR Repos, ECS Clusters

Serverless

Lambda Functions, API Gateways (v1 & v2)

DevOps

CloudFormation, CodeCommit, CodeBuild, CodePipeline

Messaging

SQS Queues, SNS Topics

Other

EFS, Step Functions, CloudWatch Logs, EMR Clusters

❌ Resources Intentionally Preserved

Details

Compute

EC2 Instances

Networking

VPCs, Subnets, Security Groups, Route Tables

Storage

Attached EBS Volumes

Identity

All IAM Resources (Users, Roles, Policies)

DNS

Route53 Hosted Zones and Domains

Account

AWS Organizations, Service Control Policies (SCPs)

Contributing
Contributions from the community are welcome. Please open an issue to discuss significant changes before submitting a pull request. We recommend using shellcheck to lint script contributions.

License
This project is licensed under the MIT License. See the LICENSE file for details.