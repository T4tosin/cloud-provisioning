#!/bin/bash
set -euo pipefail

CONFIG_FILE="${1:-configs/provision.env}"
source "$CONFIG_FILE"

log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1"; }

check_prerequisites() {
  command -v aws >/dev/null || exit 1
  aws sts get-caller-identity >/dev/null 2>&1 || exit 1
  aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 || exit 1
}

create_security_group() {
  SG_ID=$(aws ec2 describe-security-groups \
    --group-names "$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "Web server security group" \
      --query 'GroupId' --output text)
  fi
}

launch_instance() {
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --query 'Instances[0].InstanceId' --output text)

  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
}

configure_instance() {
  # retry SSH until ready
  ssh -i "${KEY_NAME}.pem" ec2-user@"$PUBLIC_IP" << 'EOF'
    set -e
    sudo yum update -y
    sudo amazon-linux-extras install nginx1 -y
    sudo systemctl start nginx
    sudo systemctl enable nginx
EOF
}

verify_deployment() {
  curl -s "http://$PUBLIC_IP" >/dev/null
}

