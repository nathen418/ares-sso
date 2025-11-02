# Ubuntu LDAP + SSSD Integration Script

This script automates joining Ubuntu 24.04+ servers to an LDAP directory for centralized authentication.

### Features
- Restricts logins to members of a specific LDAP group.
- Passwordless sudo for admin LDAP group.
- Automatically creates home directories on first login.
- Local break-glass admin account for fallback access.
- Supports LDAP-based SSH public key retrieval.

### Usage
Edit the following variables at the top of the script:
```bash
LDAP_URI="ldap://<ldap-server>"
LDAP_BASE_DN="dc=example,dc=com"
LDAP_BIND_DN="cn=binduser,ou=service_accounts,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="<super-secret-password>"
```
Then run:
```bash
sudo bash setup-ldap-sssd.sh
```
### Tested On:  
Ubuntu 22.04 LTS
Ubuntu 24.04 LTS
