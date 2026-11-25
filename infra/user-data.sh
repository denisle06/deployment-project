#!/bin/bash
# EC2 launch-template user data for every SmartTunes machine (Ubuntu 24.04).
# The instance's "Role" tag decides what gets installed:
#   Role=jenkins -> Docker, Java 21, Jenkins LTS   (also runs Prometheus + Grafana later)
#   Role=test    -> Docker, Java 21 (for the Jenkins SSH agent)
#   Role=prod    -> Docker, Nginx, /opt/smarttunes
# Requires "Allow tags in metadata" = Enable in the launch template.
# Progress: /var/log/smarttunes-bootstrap.log ; finished when /var/log/smarttunes-bootstrap.done exists.
set -euxo pipefail
exec > /var/log/smarttunes-bootstrap.log 2>&1

# Read the Role tag through IMDSv2.
TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
ROLE=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/tags/instance/Role || echo none)
echo "Bootstrapping role: $ROLE"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git unzip

# Docker Engine + Compose plugin (all roles).
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

case "$ROLE" in
  jenkins)
    apt-get install -y fontconfig openjdk-21-jre
    # Jenkins LTS repository (signing key rotated in Dec 2025: jenkins.io-2026.key).
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
        -o /etc/apt/keyrings/jenkins-keyring.asc
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
        > /etc/apt/sources.list.d/jenkins.list
    apt-get update
    apt-get install -y jenkins
    usermod -aG docker jenkins          # pipeline builds images on this machine
    systemctl restart jenkins
    ;;
  test)
    apt-get install -y openjdk-21-jre-headless
    install -d -o ubuntu -g ubuntu /home/ubuntu/jenkins-agent
    ;;
  prod)
    apt-get install -y nginx
    rm -f /etc/nginx/sites-enabled/default   # our site is installed by deploy.sh
    systemctl reload nginx
    install -d -o ubuntu -g ubuntu /opt/smarttunes
    ;;
  *)
    echo "No Role tag found: only Docker installed"
    ;;
esac

touch /var/log/smarttunes-bootstrap.done
echo "Bootstrap finished for role: $ROLE"
