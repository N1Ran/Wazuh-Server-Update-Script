#!/bin/bash

# Wazuh 4.x Upgrade Script
# Prerequisites: Debian/Ubuntu 20.04+ (tested), root/sudo access
# Logs to /var/log/wazuh_upgrade.log

LOG_FILE="/var/log/wazuh_upgrade.log"
BACKUP_DIR="/tmp/wazuh_backup_$(date +%Y%m%d_%H%M%S)"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
NEW_VERSION=$(
  curl -sI https://github.com/wazuh/wazuh/releases/latest \
    | tr -d '\r' \
    | grep -i '^location:' \
    | sed -E 's#.*/(releases/)?tag/(v[^/]+).*#\2#'
)

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Wazuh Upgrade Script Started: $TIMESTAMP ==="

# --- Step 1: GPG Key Import & Repository Setup ---
echo "[$TIMESTAMP] Importing Wazuh GPG key..."
if ! curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import; then
    echo "ERROR: GPG key import failed. Verify network connectivity."
    exit 1
fi
chmod 644 /usr/share/keyrings/wazuh.gpg || { echo "ERROR: Failed to set permissions on GPG key."; exit 1; }

echo "[$TIMESTAMP] Adding Wazuh repository..."
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee -a /etc/apt/sources.list.d/wazuh.list >/dev/null
apt-get update || { echo "ERROR: APT update failed."; exit 1; }

# --- Step 2: Backup Critical Configurations ---
echo "[$TIMESTAMP] Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR" || { echo "ERROR: Failed to create backup directory."; exit 1; }

# Backup Filebeat config
cp /etc/filebeat/filebeat.yml "$BACKUP_DIR/filebeat.yml.bak" || echo "WARNING: Filebeat config backup skipped (file may not exist)."

# Backup Dashboard config
cp /etc/wazuh-dashboard/opensearch_dashboards.yml "$BACKUP_DIR/dashboard.yml.bak" || echo "WARNING: Dashboard config backup skipped (file may not exist)."

# --- Step 3: Stop Services & Backup Indexer Security ---
echo "[$TIMESTAMP] Stopping Wazuh services..."
for service in filebeat wazuh-dashboard wazuh-manager wazuh-indexer; do
    systemctl stop "$service" 2>/dev/null || echo "WARNING: $service not running or failed to stop."
done

# Backup Indexer security config
echo "[$TIMESTAMP] Backing up Indexer security config..."
/usr/share/wazuh-indexer/bin/indexer-security-init.sh --options "-backup /etc/wazuh-indexer/opensearch-security -icl -nhnv" || echo "WARNING: Indexer security backup failed."

# --- Step 4: Upgrade Indexer ---
echo "[$TIMESTAMP] Upgrading Wazuh Indexer..."
apt-get install -y wazuh-indexer || { echo "ERROR: Indexer installation failed."; exit 1; }
systemctl daemon-reload || { echo "ERROR: Failed to reload systemd."; exit 1; }
systemctl enable wazuh-indexer || { echo "ERROR: Failed to enable Indexer."; exit 1; }
systemctl start wazuh-indexer || { echo "ERROR: Failed to start Indexer."; exit 1; }

# Reinitialize Indexer security
/usr/share/wazuh-indexer/bin/indexer-security-init.sh || { echo "ERROR: Indexer security reinitialization failed."; exit 1; }

# --- Step 5: Upgrade Manager ---
echo "[$TIMESTAMP] Upgrading Wazuh Manager..."
apt-get install -y wazuh-manager || { echo "ERROR: Manager installation failed."; exit 1; }
systemctl daemon-reload || { echo "ERROR: Failed to reload systemd."; exit 1; }
systemctl enable wazuh-manager || { echo "ERROR: Failed to enable Manager."; exit 1; }
systemctl start wazuh-manager || { echo "ERROR: Failed to start Manager."; exit 1; }

# --- Step 6: Upgrade Filebeat ---
echo "[$TIMESTAMP] Upgrading Filebeat..."

# Extract Filebeat template
curl -s https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.5.tar.gz | tar -xvz -C /usr/share/filebeat/module || { echo "ERROR: Failed to extract Filebeat template."; exit 1; }

# Download and apply template
echo "[$TIMESTAMP] Downloading Filebeat template for version $NEW_VERSION..."
curl -so /etc/filebeat/wazuh-template.json https://raw.githubusercontent.com/wazuh/wazuh/$NEW_VERSION/extensions/elasticsearch/7.x/wazuh-template.json || { echo "ERROR: Failed to download Filebeat template."; exit 1; }
chmod go+r /etc/filebeat/wazuh-template.json || { echo "ERROR: Failed to set permissions on template."; exit 1; }

# Restore original config (if backup exists)
if [ -f "$BACKUP_DIR/filebeat.yml.bak" ]; then
    cp "$BACKUP_DIR/filebeat.yml.bak" /etc/filebeat/filebeat.yml || { echo "ERROR: Failed to restore Filebeat config."; exit 1; }
fi

apt-get install -y filebeat || { echo "ERROR: Filebeat installation failed."; exit 1; }
systemctl daemon-reload || { echo "ERROR: Failed to reload systemd."; exit 1; }
systemctl enable filebeat || { echo "ERROR: Failed to enable Filebeat."; exit 1; }
systemctl start filebeat || { echo "ERROR: Failed to start Filebeat."; exit 1; }

# Apply Filebeat pipelines and index management
filebeat setup --pipelines || { echo "WARNING: Filebeat pipeline setup failed."; }
filebeat setup --index-management -E output.logstash.enabled=false || { echo "WARNING: Filebeat index management failed."; }

# --- Step 7: Upgrade Dashboard ---
echo "[$TIMESTAMP] Upgrading Wazuh Dashboard..."

# Restore original config (if backup exists)
if [ -f "$BACKUP_DIR/dashboard.yml.bak" ]; then
    cp "$BACKUP_DIR/dashboard.yml.bak" /etc/wazuh-dashboard/opensearch_dashboards.yml || { echo "WARNING: Failed to restore Dashboard config."; }
fi

apt-get install -y wazuh-dashboard || { echo "ERROR: Dashboard installation failed."; exit 1; }
systemctl daemon-reload || { echo "ERROR: Failed to reload systemd."; exit 1; }
systemctl enable wazuh-dashboard || { echo "ERROR: Failed to enable Dashboard."; exit 1; }
systemctl start wazuh-dashboard || { echo "ERROR: Failed to start Dashboard."; exit 1; }

# --- Verification ---
echo "[$TIMESTAMP] Verifying service status..."
for service in filebeat wazuh-dashboard wazuh-manager wazuh-indexer; do
    if systemctl is-active --quiet "$service"; then
        echo "[$TIMESTAMP] $service: ✅ Running"
    else
        echo "[$TIMESTAMP] $service: ❌ NOT RUNNING"
    fi
done

echo "=== Wazuh Upgrade Script Completed: $TIMESTAMP ==="
echo "Backup directory: $BACKUP_DIR"
echo "Log file: $LOG_FILE"