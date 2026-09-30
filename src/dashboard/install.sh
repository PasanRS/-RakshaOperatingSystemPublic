#!/bin/bash
# Install Raksha OS Dashboard
set -e

echo "Installing Raksha OS Dashboard..."

# Install Python dependencies
pip install -r requirements.txt

# Install systemd service
sudo cp raksha-dashboard.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now raksha-dashboard

echo "Dashboard installed! Access at http://localhost:8080"
echo "Tailscale: http://<tailscale-ip>:8080"