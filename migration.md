Got it ✅ — here’s the same content **ready to drop directly into a file** named `MIGRATION.md` — no code fences wrapping the whole thing, just pure Markdown content as it would appear in GitHub:

---

# 🚀 Migration Guide — JumpCloud → LDAP (Authentik)

This guide details how to migrate all JumpCloud-authenticated users to LDAP (Authentik), remove JumpCloud agents, and safely merge any local users that collide with new LDAP accounts.

---

## 1️⃣ Stop and Remove JumpCloud Agent

Run these commands on each host:

```bash
sudo service jcagent stop
sudo apt-get remove -y jcagent
sudo rm -rf /opt/jc
```

---

## 2️⃣ Install and Configure LDAP Authentication

Run your LDAP install script (replace with your exact path or URL):

```bash
sudo bash ldap_install.sh
```

This script should:

* Install `sssd`, `ldap-utils`, and related PAM modules
* Configure `/etc/sssd/sssd.conf` to use your LDAP URI (`ldap://10.3.5.50`)
* Set your search base to `dc=ldap,dc=playantares,dc=com`
* Restart and enable the `sssd` service

After installation, verify:

```bash
sudo systemctl status sssd
```

and test authentication:

```bash
getent passwd <ldap_user>
```

You should see LDAP users appearing in the system passwd database.

---

## 3️⃣ Detect User Collisions

Use this one-liner to list all **local vs LDAP** users and identify collisions:

```bash
echo -e "USERNAME\tSOURCE"; \
local_users=$(getent passwd | awk -F: '$3 >= 1000 {print $1}' | sort); \
ldap_users=$(ldapsearch -x -LLL -H ldap://10.3.5.50 -b "dc=ldap,dc=playantares,dc=com" "(objectClass=person)" cn | awk '/^cn:/{print $2}' | sort); \
for user in $(echo -e "${local_users}\n${ldap_users}" | sort -u); do \
  if echo "$local_users" | grep -qx "$user" && echo "$ldap_users" | grep -qx "$user"; then \
    echo -e "$user\t⚠️ BOTH (COLLISION)"; \
  elif echo "$local_users" | grep -qx "$user"; then \
    echo -e "$user\tLocal"; \
  else \
    echo -e "$user\tLDAP"; \
  fi; \
done | column -t
```

Look for users marked with `⚠️ BOTH (COLLISION)` — those need migration.

---

## 4️⃣ Test LDAP Authentication Works

Pick a test user that exists in LDAP:

```bash
getent passwd <ldap_user>
id <ldap_user>
```

If these return data with a valid UID/GID (e.g., not 1000), LDAP is working.

---

## 5️⃣ Migrate Colliding Local Users to LDAP

Use this **migration script** to merge local user data into its LDAP account.

Save as `/usr/local/bin/migrate-user.sh`:

```bash
#!/bin/bash
# Migrate a local user to an LDAP user, preserving /home data

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <local_username> <ldap_username>"
  exit 1
fi

LOCAL_USER="$1"
LDAP_USER="$2"

# Get LDAP UID/GID
LDAP_INFO=$(getent passwd "$LDAP_USER" || true)
if [ -z "$LDAP_INFO" ]; then
  echo "❌ LDAP user $LDAP_USER not found in directory."
  exit 1
fi

LDAP_UID=$(echo "$LDAP_INFO" | cut -d: -f3)
LDAP_GID=$(echo "$LDAP_INFO" | cut -d: -f4)
LDAP_HOME=$(echo "$LDAP_INFO" | cut -d: -f6)

echo "Migrating local user '$LOCAL_USER' → LDAP user '$LDAP_USER' ($LDAP_UID:$LDAP_GID)"
echo "LDAP home: $LDAP_HOME"
read -rp "Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# Backup home
if [ -d "/home/$LOCAL_USER" ]; then
  echo "📦 Backing up /home/$LOCAL_USER to /home/${LOCAL_USER}.bak"
  sudo rsync -a "/home/$LOCAL_USER/" "/home/${LOCAL_USER}.bak/"
fi

# Disable local user
echo "🔒 Disabling local user $LOCAL_USER"
sudo usermod -L "$LOCAL_USER" 2>/dev/null || true
sudo usermod -s /usr/sbin/nologin "$LOCAL_USER" 2>/dev/null || true

# Fix ownership of home
if [ -d "$LDAP_HOME" ]; then
  echo "🧹 Fixing file ownerships for LDAP user"
  sudo chown -R "$LDAP_UID:$LDAP_GID" "$LDAP_HOME"
else
  echo "Creating home directory $LDAP_HOME"
  sudo mkdir -p "$LDAP_HOME"
  sudo chown "$LDAP_UID:$LDAP_GID" "$LDAP_HOME"
fi

# Reassign orphaned files
echo "🔍 Reassigning orphaned files (UID=$LOCAL_UID → $LDAP_UID)"
LOCAL_UID=$(id -u "$LOCAL_USER" 2>/dev/null || echo "")
if [ -n "$LOCAL_UID" ]; then
  sudo find / -xdev -user "$LOCAL_UID" -exec chown "$LDAP_UID:$LDAP_GID" {} + 2>/dev/null || true
fi

# Remove local passwd entry
echo "🗑 Removing local passwd entry for $LOCAL_USER"
sudo sed -i "/^$LOCAL_USER:/d" /etc/passwd /etc/shadow

# Restart services
echo "🔁 Restarting SSSD/NSS"
sudo systemctl restart sssd nscd 2>/dev/null || true

echo "✅ Migration complete. Verify with:"
echo "    id $LDAP_USER"
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/migrate-user.sh
```

---

## 6️⃣ Run Migration for Each Collision

For each collision reported earlier:

```bash
sudo migrate-user.sh <local_username> <ldap_username>
```

Example:

```bash
sudo migrate-user.sh ker ker
```

---

## 7️⃣ Validate

Confirm the migrated user now comes from LDAP:

```bash
getent passwd <username>
id <username>
```

You should now see the **LDAP UID/GID**, and the local passwd entry removed.

---

## ✅ Final Verification

Once all users are migrated:

```bash
sudo systemctl restart sssd
sudo getent passwd | grep -v nologin
```

All users should now resolve via LDAP only.

---

**End of Migration**

---

You can copy this entire text and save it directly as `MIGRATION.md` — GitHub will render it perfectly formatted.
