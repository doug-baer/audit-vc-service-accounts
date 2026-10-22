#!/bin/bash
# ==============================================================================
# A lightweight script to adjust service account password expiration properties
#  - set account to have a non-expiring password
#  - set account to un-expire the current password
# Optionally log output to a file (specify as second parameter)
# Version 1.1 (October 22, 2026) -Doug Baer
# ==============================================================================

# Ensure an input file was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_accounts_file> [optional_log_file]"
    exit 1
fi

ACCOUNTS_FILE="$1"

if [ ! -f "$ACCOUNTS_FILE" ]; then
    echo "Error: File '$ACCOUNTS_FILE' does not exist."
    exit 1
fi

# Define log file name (custom argument or timestamped default)
LOG_FILE="${2:-update_accounts_$(date +%Y%m%d_%H%M%S).log}"

DETECTED_DOMAIN=$(/usr/lib/vmware-vmafd/bin/vmafd-cli get-domain-name --server-name localhost 2>/dev/null)
DEFAULT_DOMAIN="${DETECTED_DOMAIN:-vsphere.local}"
read -r -p "Enter SSO domain [${DEFAULT_DOMAIN}]: " INPUT_DOMAIN < /dev/tty
SSO_DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"

# Construct the LDAP Base DN dynamically (e.g., vsphere.local -> dc=vsphere,dc=local)
BASE_DN="dc=$(echo "$SSO_DOMAIN" | sed 's/\./,dc=/g')"
SSO_ADMIN="administrator@${SSO_DOMAIN}"
ADMIN_DN="cn=Administrator,cn=Users,${BASE_DN}"

# 2. Prompt for SSO password BEFORE starting logging to keep credentials out of the log
read -s -p "Enter password for ${SSO_ADMIN}: " SSO_PASS < /dev/tty
echo ""

if [ -z "$SSO_PASS" ]; then
    echo "Error: Password cannot be blank."
    exit 1
fi

# Redirect stdout (1) and stderr (2) to both console and the log file
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "============================================================"
echo "Execution started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Target accounts   : ${ACCOUNTS_FILE}"
echo "Log file location : $(pwd)/${LOG_FILE}"
echo "============================================================"

# Process the input file line-by-line
while IFS= read -r ACCOUNT_NAME || [ -n "$ACCOUNT_NAME" ]; do
    # Strip Windows CRLF line-endings and trim surrounding whitespace
    ACCOUNT_NAME=$(echo "$ACCOUNT_NAME" | tr -d '\r' | xargs)

    # Skip blank lines and comment lines
    [[ -z "$ACCOUNT_NAME" || "$ACCOUNT_NAME" =~ ^# ]] && continue

    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing account: ${ACCOUNT_NAME}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ========================================="

    # 1. Query level-2 attributes
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] Querying initial account status..."
    /usr/lib/vmware-vmafd/bin/dir-cli user find-by-name \
        --account "${ACCOUNT_NAME}" \
        --level 2 \
        --login "${SSO_ADMIN}" \
        --password "${SSO_PASS}"

    # 2. Modify password expiry policy in SSO
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] Setting password to never expire..."
    /usr/lib/vmware-vmafd/bin/dir-cli user modify \
        --account "${ACCOUNT_NAME}" \
        --password-never-expires \
        --login "${SSO_ADMIN}" \
        --password "${SSO_PASS}"

    # 3. Modify userAccountControl bitmask via LDAP (66048 = NORMAL_ACCOUNT + DONT_EXPIRE_PASSWORD)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] Updating userAccountControl in LDAP..."
    /opt/likewise/bin/ldapmodify -x -h localhost -p 389 \
        -D "${ADMIN_DN}" \
        -w "${SSO_PASS}" <<EOF
dn: cn=${ACCOUNT_NAME},cn=ServicePrincipals,${BASE_DN}
changetype: modify
replace: userAccountControl
userAccountControl: 66048
EOF

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] Finished processing ${ACCOUNT_NAME}"
done < "$ACCOUNTS_FILE"

# Wipe password from environment memory
unset SSO_PASS

echo ""
echo "============================================================"
echo "Execution finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Full log saved to : $(pwd)/${LOG_FILE}"
echo "============================================================"
