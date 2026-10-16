#!/usr/bin/env bash
# ==============================================================================
# VCF 9.x Protection & Recovery Service Account Audit & Verification
# Version 1.3 (October 14, 2026) -Doug Baer
# Original script -- suggest using vlr-get-accounts.sh + vlr-audit-svc.sh instead
#
# ==============================================================================

DIR_CLI="/usr/lib/vmware-vmafd/bin/dir-cli"

if [[ ! -x "${DIR_CLI}" ]]; then
    echo "ERROR: ${DIR_CLI} not found. Please run this script on a vCenter Server Appliance."
    exit 1
fi

echo "=============================================================================="
echo "      vCenter Protection & Recovery Service Account Health Check             "
echo "=============================================================================="

read -rsp "Enter password for SSO Administrator (e.g. administrator@vsphere.local): " SSO_PASS
echo ""

# Determine SSO domain
SSO_DOMAIN=$(/usr/lib/vmware-vmafd/bin/vmafd-cli get-domain-name --server-name localhost 2>/dev/null || echo "vsphere.local")
SSO_ADMIN="administrator@${SSO_DOMAIN}"

echo -e "\n[*] Querying vCenter Directory Service (vmdir)..."

# 1. Collect from all three dir-cli sources: svcaccount, service, and user
SVC_ACCTS=$(${DIR_CLI} svcaccount list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
SOL_USERS=$(${DIR_CLI} service list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
STD_USERS=$(${DIR_CLI} user list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')

# Combine and filter for Protection & Recovery related accounts
ALL_DISCOVERED=$(echo -e "${SVC_ACCTS}\n${SOL_USERS}\n${STD_USERS}" | sort -u | grep -E -i "aps-|srm-|snapservice|hms-|vr-sa|vsan|ims-|dr-backup" || true)

if [[ -z "${ALL_DISCOVERED}" ]]; then
    echo "[-] No accounts matched known filter patterns. Dumping all registered service accounts:"
    echo "--- [Service Accounts (svcaccount list)] ---"
    ${DIR_CLI} svcaccount list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null || true
    echo "--------------------------------------------"
    exit 0
fi

echo "[+] Discovered Matching Accounts:"
echo "${ALL_DISCOVERED}"
echo "=============================================================================="

# Relevant SSO Groups to inspect
CHECK_GROUPS=(
    "Administrators"
    "ActAsUsers"
    "SolutionUsers"
    "APS Administrators"
    "SnapService Service Users"
    "VRMS Remote Sites"
)

# Cache group memberships
declare -A GROUP_CACHE
for G in "${CHECK_GROUPS[@]}"; do
    GROUP_CACHE["${G}"]=$(${DIR_CLI} group list --name "${G}" --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null || true)
done

printf "\n %-8s | %-8s | %-8s | %-14s | %-20s | %-42s\n" "Disabled" "Locked" "Expired" "Never Expires" "Password Expiry" "Account Name" 
printf "%s\n" "------------------------------------------------------------------------------------------------------------------"

for ACCT in ${ALL_DISCOVERED}; do
    USER_INFO=$(${DIR_CLI} user find-by-name --account "${ACCT}" --level 2 --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null || true)
    
    if [[ -z "${USER_INFO}" ]]; then
        printf "%-42s | (Account present in vmdir; details query returned empty)\n" "${ACCT}"
    else
        DIS=$(echo "${USER_INFO}" | grep -i "Account disabled:" | head -n1 | awk '{print $3}')
        LCK=$(echo "${USER_INFO}" | grep -i "Account locked:" | head -n1 | awk '{print $3}')
        EXPD=$(echo "${USER_INFO}" | grep -i "Password expired:" | head -n1 | awk '{print $3}')
        NEV=$(echo "${USER_INFO}" | grep -i "Password never expires:" | head -n1 | awk '{print $4}')
        EXP=$(echo "${USER_INFO}" | grep -i "Password expiry:" | head -n1 | cut -d':' -f2- | sed 's/^[ \t]*//')
        
        [[ -z "${DIS}" ]] && DIS="UNKNOWN"
        [[ -z "${LCK}" ]] && LCK="UNKNOWN"
        [[ -z "${NEV}" ]] && NEV="UNKNOWN"
        [[ -z "${EXP}" ]] && EXP="N/A"
        [[ -z "${EXPD}" ]] && EXPD="UNKNOWN"
        
        printf "%-8s | %-8s | %-8s | %-14s | %-20s | %-42s\n" "${DIS}" "${LCK}" "${EXPD}" "${NEV}" "${EXP}" "${ACCT}" 
    fi

    # Report memberships
    echo "   [Group Memberships]:"
    FOUND=0
    for G in "${CHECK_GROUPS[@]}"; do
        if echo "${GROUP_CACHE[${G}]}" | grep -qi "${ACCT}"; then
            echo "     * ${G}: YES"
            FOUND=1
        fi
    done
    if [[ ${FOUND} -eq 0 ]]; then
        echo "     * [NOTE] Not a member of standard checked groups (or inherits via ActAs/Token delegation)."
    fi
    echo ""
done

echo "=============================================================================="
echo "Health check complete."
