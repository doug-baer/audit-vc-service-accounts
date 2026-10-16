#!/bin/bash
# ==============================================================================
# A lightweight audit script to check service account password expiration properties
# Version 1.0 (October 15, 2026) -Doug Baer
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

# Prompt once for SSO Administrator password securely
read -s -p "Enter password for administrator@vsphere.local: " SSO_PASS < /dev/tty
echo ""

if [ -z "$SSO_PASS" ]; then
    echo "Error: Password cannot be blank."
    exit 1
fi

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
        -D "cn=Administrator,cn=Users,dc=vsphere,dc=local" \
        -w "${SSO_PASS}" \
        -b "dc=vsphere,dc=local" \
        "(|(cn=${ACCOUNT_NAME})(sAMAccountName=${ACCOUNT_NAME}))" userAccountControl 2>/dev/null \
        | awk '/^userAccountControl:/ {print $2}' | head -n 1)

    [ -z "$UAC_VAL" ] && UAC_VAL="<Not Found>"

    # 2. Retrieve level-2 status from dir-cli
    DIR_OUTPUT=$(/usr/lib/vmware-vmafd/bin/dir-cli user find-by-name \
        --account "${ACCOUNT_NAME}" \
        --level 2 \
        --login "administrator@vsphere.local" \
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
