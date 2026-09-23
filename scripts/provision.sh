#!/bin/bash
set -euo pipefail

CONFIG_FILE="${1:-configs/provision.env}"
source "$CONFIG_FILE"

export AWS_DEFAULT_REGION="$REGION"

log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1"; }

check_prerequisites() {
  command -v aws >/dev/null || { log_error "aws CLI not found"; exit 1; }
  aws sts get-caller-identity >/dev/null 2>&1 || { log_error "AWS credentials not configured"; exit 1; }
  aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 || { log_error "Key pair $KEY_NAME not found"; exit 1; }
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

    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$ALLOWED_SSH_CIDR" >/dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$SG_ID" --protocol tcp --port "$APP_PORT" --cidr 0.0.0.0/0 >/dev/null
  else
    log_info "Security group $SECURITY_GROUP_NAME already exists ($SG_ID), skipping rule creation"
  fi
}

launch_instance() {
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' --output text)

  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
}

configure_instance() {
  log_info "Waiting for SSH to become available on $PUBLIC_IP..."
  for i in {1..15}; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${KEY_NAME}.pem" ec2-user@"$PUBLIC_IP" true 2>/dev/null; then
      break
    fi
    if [ "$i" -eq 15 ]; then
      log_error "SSH never became available on $PUBLIC_IP"
      exit 1
    fi
    sleep 10
  done

  ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ec2-user@"$PUBLIC_IP" << 'EOF'
    set -e
    sudo yum update -y
    sudo amazon-linux-extras install nginx1 -y
    sudo systemctl start nginx
    sudo systemctl enable nginx
EOF
}

verify_deployment() {
  if curl -s -o /dev/null -w "%{http_code}" "http://$PUBLIC_IP" | grep -q "200"; then
    log_info "Deployment verified: http://$PUBLIC_IP is responding"
  else
    log_error "Deployment verification failed: http://$PUBLIC_IP is not responding"
    exit 1
  fi
}

main() {
  log_info "Checking prerequisites..."
  check_prerequisites

  log_info "Setting up security group..."
  create_security_group

  log_info "Launching instance..."
  launch_instance

  log_info "Configuring instance..."
  configure_instance

  log_info "Verifying deployment..."
  verify_deployment

  log_info "Done. Instance $INSTANCE_ID ($INSTANCE_NAME) is live at http://$PUBLIC_IP"
}

main "$@"
