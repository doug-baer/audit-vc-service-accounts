#!/usr/bin/env bash
# ==============================================================================
# VMware / Broadcom Protection & Recovery Service Account Management Suite
# Features: Discovery, Health Audit, Remediation, and Re-Verification
# Version 1.0 (October 22, 2026) -Doug Baer
# ==============================================================================

DIR_CLI="/usr/lib/vmware-vmafd/bin/dir-cli"
VMAFD_CLI="/usr/lib/vmware-vmafd/bin/vmafd-cli"
LDAP_SEARCH="/opt/likewise/bin/ldapsearch"
LDAP_MODIFY="/opt/likewise/bin/ldapmodify"

# Validate required toolsets on VCSA
for tool in "${DIR_CLI}" "${VMAFD_CLI}" "${LDAP_SEARCH}" "${LDAP_MODIFY}"; do
    if [[ ! -x "$tool" ]]; then
        echo "ERROR: Required utility '$tool' not found. Run this script directly on the VCSA as root."
        exit 1
    fi
done

LOG_FILE="protection_accounts_$(date +%Y%m%d_%H%M%S).log"

# 1. Interactive Credentials & Environment Setup
DETECTED_DOMAIN=$("${VMAFD_CLI}" get-domain-name --server-name localhost 2>/dev/null)
DEFAULT_DOMAIN="${DETECTED_DOMAIN:-vsphere.local}"

read -r -p "Enter SSO domain [${DEFAULT_DOMAIN}]: " INPUT_DOMAIN < /dev/tty
SSO_DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"

BASE_DN="dc=$(echo "$SSO_DOMAIN" | sed 's/\./,dc=/g')"
SSO_ADMIN="administrator@${SSO_DOMAIN}"
ADMIN_DN="cn=Administrator,cn=Users,${BASE_DN}"

read -s -p "Enter password for ${SSO_ADMIN}: " SSO_PASS < /dev/tty
echo ""

if [[ -z "${SSO_PASS}" ]]; then
    echo "ERROR: Password cannot be blank."
    exit 1
fi

# Ensure password is automatically erased upon script termination
trap 'unset SSO_PASS' EXIT

# Enable dual logging (Console + File)
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=============================================================================="
echo "Execution Started : $(date '+%Y-%m-%d %H:%M:%S')"
echo "SSO Domain        : ${SSO_DOMAIN}"
echo "LDAP Base DN      : ${BASE_DN}"
echo "Admin Identity    : ${SSO_ADMIN}"
echo "Log File Path     : $(pwd)/${LOG_FILE}"
echo "=============================================================================="

# 2. Account Ingestion / Discovery
TARGET_ACCOUNTS=()

if [[ -n "$1" && -f "$1" ]]; then
    echo "[*] Ingesting accounts from provided file: $1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        acct=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$acct" || "$acct" =~ ^# ]] && continue
        TARGET_ACCOUNTS+=("$acct")
    done < "$1"
else
    echo "[*] No input file supplied. Running auto-discovery against vCenter Directory Service..."
    SVC_ACCTS=$("${DIR_CLI}" svcaccount list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
    SOL_USERS=$("${DIR_CLI}" service list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
    STD_USERS=$("${DIR_CLI}" user list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')

    while IFS= read -r acct; do
        [[ -n "$acct" ]] && TARGET_ACCOUNTS+=("$acct")
    done < <(echo -e "${SVC_ACCTS}\n${SOL_USERS}\n${STD_USERS}" \
        | sed "s/@${SSO_DOMAIN}//g; s/@vsphere.local//g" \
        | tr -d '\r' \
        | awk '{$1=$1};1' \
        | grep -E -i "^(aps-|srm-|snapservice|hms-|vr-sa|vsan|ims-|h5-dr-|dr-sa-)" \
        | sort -u)
fi

if [[ ${#TARGET_ACCOUNTS[@]} -eq 0 ]]; then
    echo "[-] No Protection & Recovery accounts discovered or supplied."
    exit 0
fi

echo "[+] Discovered ${#TARGET_ACCOUNTS[@]} account(s) to evaluate."

# Helper function to audit and display status table
audit_accounts_table() {
    local table_title="$1"
    local fmt="%-45s | %-12s | %-18s | %-16s | %-14s"
    echo ""
    echo ">>> ${table_title} <<<"
    printf "${fmt}\n" "Account Name" "UAC Bitmask" "Password Expired?" "Never Expires?" "Set to Expire?"
    printf "%s\n" "------------------------------------------------------------------------------------------------------------------------"

    for acct in "${TARGET_ACCOUNTS[@]}"; do
        # Retrieve userAccountControl
        uac=$("${LDAP_SEARCH}" -LLL -h localhost -p 389 -x \
            -D "${ADMIN_DN}" \
            -w "${SSO_PASS}" \
            -b "${BASE_DN}" \
            "(|(cn=${acct})(sAMAccountName=${acct}))" userAccountControl 2>/dev/null \
            | awk '/^userAccountControl:/ {print $2}' | head -n 1)
        [[ -z "$uac" ]] && uac="<Not Found>"

        # Retrieve dir-cli status
        dir_out=$("${DIR_CLI}" user find-by-name \
            --account "${acct}" \
            --level 2 \
            --login "${SSO_ADMIN}" \
            --password "${SSO_PASS}" 2>/dev/null)

        pwd_exp=$(echo "$dir_out" | grep -o 'Password expired:[[:space:]]*[^[:space:]]*' | awk '{print $NF}')
        pwd_never=$(echo "$dir_out" | grep -o 'Password never expires:[[:space:]]*[^[:space:]]*' | awk '{print $NF}')

        [[ -z "$pwd_exp" ]] && pwd_exp="<Error>"
        [[ -z "$pwd_never" ]] && pwd_never="<Error>"

        if [[ "$pwd_never" == "TRUE" ]]; then
            ste="NO (Never)"
        elif [[ "$pwd_never" == "FALSE" ]]; then
            ste="YES"
        else
            ste="Unknown"
        fi

        printf "${fmt}\n" "${acct}" "${uac}" "${pwd_exp}" "${pwd_never}" "${ste}"
    done
    printf "%s\n\n" "------------------------------------------------------------------------------------------------------------------------"
}

# 3. Initial Audit
audit_accounts_table "INITIAL AUDIT STATUS"

# 4. Interactive Remediation Confirmation
read -r -p "Do you want to remediate these accounts (set never-expires + clear expired UAC bit)? [y/N]: " CONFIRM_REMEDIATE < /dev/tty

if [[ ! "$CONFIRM_REMEDIATE" =~ ^[Yy]$ ]]; then
    echo "[-] Remediation cancelled by user. Exiting without making modifications."
    exit 0
fi

# 5. Remediation Execution
echo ""
echo "=============================================================================="
echo "Starting Remediation"
echo "=============================================================================="

for acct in "${TARGET_ACCOUNTS[@]}"; do
    echo "[*] Remediating account: ${acct}"

    # Set password to never expire in dir-cli
    echo "    [-] Updating dir-cli user policy (--password-never-expires)..."
    "${DIR_CLI}" user modify \
        --account "${acct}" \
        --password-never-expires \
        --login "${SSO_ADMIN}" \
        --password "${SSO_PASS}" >/dev/null 2>&1

    # Locate exact DN in LDAP (supports cn=ServicePrincipals, cn=Users, etc.)
    target_dn=$("${LDAP_SEARCH}" -LLL -h localhost -p 389 -x \
        -D "${ADMIN_DN}" \
        -w "${SSO_PASS}" \
        -b "${BASE_DN}" \
        "(|(cn=${acct})(sAMAccountName=${acct}))" dn 2>/dev/null \
        | awk '/^dn:/ {sub(/^dn:[[:space:]]*/, ""); print; exit}')

    if [[ -n "$target_dn" ]]; then
        echo "    [-] Updating userAccountControl to 66048 at DN: ${target_dn}..."
        "${LDAP_MODIFY}" -x -h localhost -p 389 \
            -D "${ADMIN_DN}" \
            -w "${SSO_PASS}" >/dev/null 2>&1 <<EOF
dn: ${target_dn}
changetype: modify
replace: userAccountControl
userAccountControl: 66048
EOF
        echo "    [+] Remediation applied successfully."
    else
        echo "    [!] WARNING: Account ${acct} could not be resolved in LDAP under ${BASE_DN}."
    fi
done

# 6. Post-Remediation Verification Audit
audit_accounts_table "POST-REMEDIATION VERIFICATION AUDIT"

echo "=============================================================================="
echo "Execution Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Log file saved to : $(pwd)/${LOG_FILE}"
echo "=============================================================================="