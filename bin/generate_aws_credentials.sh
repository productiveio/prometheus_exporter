#!/bin/bash

# Assume the Semaphore build role via OIDC web identity (same flow as
# productiveio/docker-images) so the job can push to ECR.
if [ -z "${AWS_ROLE}" ]; then
  return 0;
fi

export SESSION_NAME="semaphore-job-${SEMAPHORE_JOB_ID}"
export CREDENTIALS=$(aws sts assume-role-with-web-identity --role-arn arn:aws:iam::013323007402:role/$AWS_ROLE --role-session-name $SESSION_NAME --web-identity-token $SEMAPHORE_OIDC_TOKEN)
export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | jq -r '.Credentials.AccessKeyId')
export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | jq -r '.Credentials.SessionToken')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | jq -r '.Credentials.SecretAccessKey')
