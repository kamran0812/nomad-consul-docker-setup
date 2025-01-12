#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "Starting Nomad and Consul setup..."

# Update and install necessary packages
sudo apt-get update
sudo apt-get install -y curl unzip

# Install Nomad
echo "Installing Nomad..."
NOMAD_VERSION="1.5.6"
curl -sSL https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip -o nomad.zip
unzip nomad.zip
sudo mv nomad /usr/local/bin/
rm nomad.zip

# Install Consul
echo "Installing Consul..."
CONSUL_VERSION="1.15.2"
curl -sSL https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip -o consul.zip
unzip consul.zip
sudo mv consul /usr/local/bin/
rm consul.zip

# Create directories for Nomad and Consul
sudo mkdir -p /etc/nomad.d /opt/nomad/data
sudo mkdir -p /etc/consul.d /opt/consul/data

# Function to get the primary private IP address
get_primary_ip() {
    PRIMARY_IP=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
    echo $PRIMARY_IP
}

# Get the primary IP address
PRIMARY_IP=$(get_primary_ip)

# Configure Nomad
echo "Configuring Nomad..."
cat << EOF | sudo tee /etc/nomad.d/nomad.hcl
# Increase the log level for more information
log_level = "DEBUG"

# Setup data dir
data_dir = "/opt/nomad/data"

# Enable the server
server {
  enabled = true
  bootstrap_expect = 1
}

# Enable the client
client {
  enabled = true
  options = {
    "docker.auth.config" = "/etc/nomad/ecr.json"
    "docker.volumes.enabled" = "true"
  }
}

# Bind to all interfaces
bind_addr = "0.0.0.0"

# Advertise the primary IP address
advertise {
  http = "${PRIMARY_IP}"
  rpc  = "${PRIMARY_IP}"
  serf = "${PRIMARY_IP}"
}
EOF

# Configure Consul
echo "Configuring Consul..."
cat << EOF | sudo tee /etc/consul.d/consul.hcl
# Increase the log level for more information
log_level = "DEBUG"

# Setup data dir
data_dir = "/opt/consul/data"

# Enable the server
server = true

# Bootstrap expect (set to 1 for a single node)
bootstrap_expect = 1

# Bind to the primary IP address
bind_addr = "${PRIMARY_IP}"

# Advertise the primary IP address
advertise_addr = "${PRIMARY_IP}"

# Enable the UI
ui = true

# Set the client address to 0.0.0.0 to allow remote access to the UI
client_addr = "0.0.0.0"

# Disable update checks
disable_update_check = true

# Enable script checks
enable_script_checks = true

# Set the datacenter name
datacenter = "dc1"
EOF

# Create systemd service for Nomad
echo "Creating Nomad systemd service..."
cat << EOF | sudo tee /etc/systemd/system/nomad.service
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for Consul
echo "Creating Consul systemd service..."
cat << EOF | sudo tee /etc/systemd/system/consul.service
[Unit]
Description=Consul
Documentation=https://www.consul.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

# Set correct permissions
sudo chown -R nomad:nomad /etc/nomad.d /opt/nomad
sudo chmod 640 /etc/nomad.d/nomad.hcl
sudo chown -R consul:consul /etc/consul.d /opt/consul
sudo chmod 640 /etc/consul.d/consul.hcl


# Update and install necessary packages
print_message "Updating system and installing ecr-login necessary packages..."
sudo apt-get update
sudo apt-get install -y amazon-ecr-credential-helper


# Update Docker config to use ECR Credential Helper
print_message "Updating Docker configuration to use ECR Credential Helper..."
CONFIG_FILE="/home/ubuntu/.docker/config.json"

if [ -f "$CONFIG_FILE" ]; then
    # Backup existing config
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # Read existing config
    config=$(cat "$CONFIG_FILE")
    
    # Add credHelpers if it doesn't exist
    if ! echo "$config" | jq -e '.credHelpers' > /dev/null; then
        config=$(echo "$config" | jq '. += {"credHelpers": {}}')
    fi
    
    # Add ECR helper
    config=$(echo "$config" | jq '.credHelpers["633954949648.dkr.ecr.us-west-2.amazonaws.com"] = "ecr-login"')
    
    # Write updated config
    echo "$config" | jq '.' > "$CONFIG_FILE"
else
    # Create new config if it doesn't exist
    mkdir -p /home/ubuntu/.docker
    cat << EOF > "$CONFIG_FILE"
{
  "auths": {},
  "credHelpers": {
    "<ADD_ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com": "ecr-login"
  }
}
EOF
fi

# Verify ECR Credential Helper installation
if which docker-credential-ecr-login > /dev/null; then
    print_message "ECR Credential Helper is installed successfully."
else
    print_message "Error: ECR Credential Helper is not installed or not in PATH."
    exit 1
fi


# Reload systemd, enable and start Nomad and Consul services
sudo systemctl daemon-reload
sudo systemctl enable nomad consul
sudo systemctl start nomad consul

# Wait for services to start
sleep 10

# Check service status
echo "Checking Nomad status..."
sudo systemctl status nomad
echo "Checking Consul status..."
sudo systemctl status consul

echo "Nomad and Consul have been installed and configured."
echo "Nomad UI should be available at http://${PRIMARY_IP}:4646"
echo "Consul UI should be available at http://${PRIMARY_IP}:8500"
echo ""
echo "If services are not running, check logs with:"
echo "sudo journalctl -u nomad.service -n 50 --no-pager"
echo "sudo journalctl -u consul.service -n 50 --no-pager"

