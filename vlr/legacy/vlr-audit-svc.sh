#!/bin/bash
# ==============================================================================
# A lightweight audit script to check service account password expiration properties
# Version 1.1 (October 22, 2026) -Doug Baer
# ==============================================================================

# Ensure an input file was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_accounts_file>"
    exit 1
fi

ACCOUNTS_FILE="$1"

if [ ! -f "$ACCOUNTS_FILE" ]; then
    echo "Error: File '$ACCOUNTS_FILE' does not exist."
    exit 1
fi

# Detect default SSO domain from the appliance
DETECTED_DOMAIN=$(/usr/lib/vmware-vmafd/bin/vmafd-cli get-domain-name --server-name localhost 2>/dev/null)
DEFAULT_DOMAIN="${DETECTED_DOMAIN:-vsphere.local}"

# 1. Prompt for SSO domain (pressing Enter accepts the default)
read -r -p "Enter SSO domain [${DEFAULT_DOMAIN}]: " INPUT_DOMAIN < /dev/tty
SSO_DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"

# Construct the LDAP Base DN dynamically (e.g., vsphere.local -> dc=vsphere,dc=local)
BASE_DN="dc=$(echo "$SSO_DOMAIN" | sed 's/\./,dc=/g')"
SSO_ADMIN="administrator@${SSO_DOMAIN}"
ADMIN_DN="cn=Administrator,cn=Users,${BASE_DN}"

# Prompt once for SSO Administrator password securely
read -s -p "Enter password for ${SSO_ADMIN}: " SSO_PASS < /dev/tty
echo ""

if [ -z "$SSO_PASS" ]; then
    echo "Error: Password cannot be blank."
    exit 1
fi

echo ""
echo "Using Domain  : ${SSO_DOMAIN}"
echo "LDAP Base DN  : ${BASE_DN}"
echo "Admin Identity: ${SSO_ADMIN}"

# Print table header
HEADER_FMT="%-12s | %-18s | %-16s | %-14s | %-45s"
printf "\n${HEADER_FMT}\n" "UAC Bitmask" "Password Expired?" "Never Expires?" "Set to Expire?" "Account Name" 
printf "%s\n" "------------------------------------------------------------------------------------------------------------------------"

# Process each account line by line
while IFS= read -r ACCOUNT_NAME || [ -n "$ACCOUNT_NAME" ]; do
    # Strip carriage returns and leading/trailing whitespace
    ACCOUNT_NAME=$(echo "$ACCOUNT_NAME" | tr -d '\r' | xargs)

    # Skip blank lines and lines starting with '#'
    [[ -z "$ACCOUNT_NAME" || "$ACCOUNT_NAME" =~ ^# ]] && continue

    # 1. Retrieve userAccountControl bitmask via LDAP
    UAC_VAL=$(/opt/likewise/bin/ldapsearch -LLL -h localhost -p 389 -x \
        -D "${ADMIN_DN}" \
        -w "${SSO_PASS}" \
        -b "${BASE_DN}" \
        "(|(cn=${ACCOUNT_NAME})(sAMAccountName=${ACCOUNT_NAME}))" userAccountControl 2>/dev/null \
        | awk '/^userAccountControl:/ {print $2}' | head -n 1)

    [ -z "$UAC_VAL" ] && UAC_VAL="<Not Found>"

    # 2. Retrieve level-2 status from dir-cli
    DIR_OUTPUT=$(/usr/lib/vmware-vmafd/bin/dir-cli user find-by-name \
        --account "${ACCOUNT_NAME}" \
        --level 2 \
        --login "${SSO_ADMIN}" \
        --password "${SSO_PASS}" 2>/dev/null)

    # Parse expiration flags
    PWD_EXPIRED=$(echo "$DIR_OUTPUT" | grep -o 'Password expired:[[:space:]]*[^[:space:]]*' | awk '{print $NF}')
    PWD_NEVER=$(echo "$DIR_OUTPUT" | grep -o 'Password never expires:[[:space:]]*[^[:space:]]*' | awk '{print $NF}')

    [ -z "$PWD_EXPIRED" ] && PWD_EXPIRED="<Error>"
    [ -z "$PWD_NEVER" ] && PWD_NEVER="<Error>"

    # Determine plain-English expiration status
    if [ "$PWD_NEVER" == "TRUE" ]; then
        SET_TO_EXPIRE="NO (Never)"
    elif [ "$PWD_NEVER" == "FALSE" ]; then
        SET_TO_EXPIRE="YES"
    else
        SET_TO_EXPIRE="Unknown"
    fi

    # Print table row
    printf "${HEADER_FMT}\n" "${UAC_VAL}" "${PWD_EXPIRED}" "${PWD_NEVER}" "${SET_TO_EXPIRE}" "${ACCOUNT_NAME}" 

done < "$ACCOUNTS_FILE"

# Clear password variable from memory
unset SSO_PASS
printf "%s\n\n" "------------------------------------------------------------------------------------------------------------------------"
