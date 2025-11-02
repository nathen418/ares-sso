#!/bin/bash
# -----------------------------------------------------------------------------
# LDAP + SSSD + PAM Integration Script (Ubuntu 24.04+)
#
# Features:
#   - Integrates Ubuntu into an LDAP/Authentik directory
#   - Restricts logins to a specific LDAP group (LOGIN_GROUP)
#   - Grants passwordless sudo to another LDAP group (SUDO_GROUP)
#   - Adds a local break-glass account for emergency access
#   - Automatically creates home directories for LDAP users
#   - Enables SSH key retrieval via LDAP
#
# Safe for public release — all credentials and domains are placeholders.
# -----------------------------------------------------------------------------
set -e

# === CONFIGURATION ===========================================================

# LDAP connection details
LDAP_URI="ldap://<ldap-server-ip-or-hostname>"
LDAP_BASE_DN="dc=example,dc=com"
LDAP_BIND_DN="cn=binduser,ou=service_accounts,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="<super-secret-password>"

# LDAP groups
LOGIN_GROUP="cn=i-server-login,ou=groups,${LDAP_BASE_DN}"
SUDO_GROUP="cn=i-a-server_admins,ou=groups,${LDAP_BASE_DN}"

# Local break-glass user
BREAK_GLASS_USER="localadmin"

# ============================================================================

echo "[*] Installing required packages..."
sudo apt update
sudo apt install -y sssd sssd-tools libnss-sss libpam-sss ldap-utils libpam-modules

# -----------------------------------------------------------------------------
# Break-glass local account
# -----------------------------------------------------------------------------
echo "[*] Ensuring break-glass account '$BREAK_GLASS_USER' exists..."
if ! id "$BREAK_GLASS_USER" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$BREAK_GLASS_USER"
    echo ">>> Set password for $BREAK_GLASS_USER:"
    sudo passwd "$BREAK_GLASS_USER"
else
    echo "[+] User $BREAK_GLASS_USER already exists."
fi

# -----------------------------------------------------------------------------
# SSSD Configuration
# -----------------------------------------------------------------------------
echo "[*] Writing /etc/sssd/sssd.conf..."
sudo bash -c "cat >/etc/sssd/sssd.conf" <<EOF
[sssd]
services = nss, pam, ssh, sudo
config_file_version = 2
domains = ldapdomain

[domain/ldapdomain]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
access_provider = ldap

ldap_uri = ${LDAP_URI}
ldap_search_base = ${LDAP_BASE_DN}
ldap_default_bind_dn = ${LDAP_BIND_DN}
ldap_default_authtok = ${LDAP_BIND_PASSWORD}

ldap_schema = rfc2307bis
ldap_id_use_start_tls = False
enumerate = True
cache_credentials = True
ldap_id_mapping = False

ldap_user_name = cn
ldap_user_object_class = person
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell
fallback_homedir = /home/%u
default_shell = /bin/bash

ldap_group_object_class = group
ldap_group_name = cn
ldap_group_member = member

# Restrict logins to users in LOGIN_GROUP
ldap_access_filter = (memberOf=${LOGIN_GROUP})

# Enable fetching SSH keys from LDAP
ldap_user_ssh_public_key = sshPublicKey
EOF

sudo chmod 600 /etc/sssd/sssd.conf
sudo systemctl enable sssd
sudo systemctl restart sssd

# -----------------------------------------------------------------------------
# NSS & PAM Integration
# -----------------------------------------------------------------------------
echo "[*] Configuring NSS and PAM..."

sudo sed -i 's/^passwd:.*/passwd:         files sss/' /etc/nsswitch.conf
sudo sed -i 's/^group:.*/group:          files sss/' /etc/nsswitch.conf
sudo sed -i 's/^shadow:.*/shadow:        files sss/' /etc/nsswitch.conf
sudo sed -i 's/^sudoers:.*/sudoers:        files sss/' /etc/nsswitch.conf || echo "sudoers: files sss" | sudo tee -a /etc/nsswitch.conf

# -----------------------------------------------------------------------------
# PAM Access Control + Home Directory Auto-Creation
# -----------------------------------------------------------------------------
echo "[*] Enforcing PAM access control..."
for f in /etc/pam.d/sshd /etc/pam.d/login; do
  if ! grep -q "pam_access.so" "$f"; then
    echo "account required pam_access.so" | sudo tee -a "$f"
  fi
done

echo "[*] Enabling automatic home directory creation..."
for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q "pam_mkhomedir.so" "$f"; then
    echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" | sudo tee -a "$f"
  fi
done

# -----------------------------------------------------------------------------
# Access Rules
# -----------------------------------------------------------------------------
echo "[*] Writing /etc/security/access.conf rules..."
sudo bash -c "cat >/etc/security/access.conf" <<EOF
# Allow root and local accounts
+ : root : ALL
+ : ${BREAK_GLASS_USER} : ALL
+ : LOCAL : ALL

# Allow LDAP users in login group
+ : (${LOGIN_GROUP##cn=}) : ALL

# Deny everyone else
- : ALL : ALL
EOF

# -----------------------------------------------------------------------------
# Sudoers Rules
# -----------------------------------------------------------------------------
echo "[*] Adding sudoers rules..."
sudo bash -c "cat >/etc/sudoers.d/ldap_sudoers" <<EOF
%${SUDO_GROUP##cn=} ALL=(ALL) NOPASSWD: ALL
${BREAK_GLASS_USER} ALL=(ALL) NOPASSWD: ALL
EOF

sudo chmod 440 /etc/sudoers.d/ldap_sudoers
sudo visudo -c

# -----------------------------------------------------------------------------
# SSH Configuration
# -----------------------------------------------------------------------------
echo "[*] Configuring SSHD for LDAP public keys..."
sudo sed -i '/^AuthorizedKeysCommand/d' /etc/ssh/sshd_config
sudo sed -i '/^AuthorizedKeysCommandUser/d' /etc/ssh/sshd_config
echo "AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys" | sudo tee -a /etc/ssh/sshd_config
echo "AuthorizedKeysCommandUser root" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh

# -----------------------------------------------------------------------------
# Final Cleanup
# -----------------------------------------------------------------------------
echo "[*] Clearing SSSD cache..."
sudo sss_cache -E || true
sudo systemctl restart sssd

echo "[+] Setup complete!"
echo "    - Only members of '${LOGIN_GROUP}' may log in via LDAP."
echo "    - '${SUDO_GROUP}' users get passwordless sudo."
echo "    - '${BREAK_GLASS_USER}' remains usable if LDAP fails."
echo "    - Home directories are auto-created on first login."
