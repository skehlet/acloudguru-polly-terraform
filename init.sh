#!/bin/bash
#
# Run this init file first to set up your Terraform state. You should only need to run it once
# in a given work directory. But there's no harm in repeating it.
#

set -e

REGION=${1:-us-east-1} # default to us-east-1
if [[ -z $REGION ]]; then
    echo "Usage: $0 <region>" >&2
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')

terraform init \
    -backend-config="region=${REGION}" \
    -backend-config="bucket=${AWS_ACCOUNT_ID}-terraform-state-${REGION}" \
    -backend-config="key=polly-terraform.tfstate"
