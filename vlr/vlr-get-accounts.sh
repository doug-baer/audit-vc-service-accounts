#!/usr/bin/env bash
# ==============================================================================
# Broadcom VCF 9.x Protection & Recovery Service Account Discovery
# Outputs a clean, alphabetically sorted list (one account per line)
# Version 1.1 (October 22, 2026) -Doug Baer
# ==============================================================================

DIR_CLI="/usr/lib/vmware-vmafd/bin/dir-cli"
VMAFD_CLI="/usr/lib/vmware-vmafd/bin/vmafd-cli"

if [[ ! -x "${DIR_CLI}" ]]; then
    echo "ERROR: ${DIR_CLI} not found. Please run this script on a vCenter Server Appliance." >&2
    exit 1
fi

OUTPUT_FILE="$1"

# Print banner to stderr so stdout remains clean for piping/redirection
{
    echo "=============================================================================="
    echo "        vCenter Protection & Recovery Service Account Discovery               "
    echo "=============================================================================="
} >&2

# 1. Detect and prompt for SSO Domain
DETECTED_DOMAIN=$("${VMAFD_CLI}" get-domain-name --server-name localhost 2>/dev/null)
DEFAULT_DOMAIN="${DETECTED_DOMAIN:-vsphere.local}"

read -r -p "Enter SSO domain [${DEFAULT_DOMAIN}]: " INPUT_DOMAIN < /dev/tty
SSO_DOMAIN="${INPUT_DOMAIN:-$DEFAULT_DOMAIN}"
SSO_ADMIN="administrator@${SSO_DOMAIN}"

# 2. Prompt for SSO password directly from terminal
read -rsp "Enter password for ${SSO_ADMIN}: " SSO_PASS < /dev/tty
echo "" >&2

if [[ -z "${SSO_PASS}" ]]; then
    echo "ERROR: Password cannot be blank." >&2
    exit 1
fi

echo "[*] Querying vCenter Directory Service (${SSO_DOMAIN})..." >&2

# 3. Collect from svcaccount, service, and user sources
SVC_ACCTS=$("${DIR_CLI}" svcaccount list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
SOL_USERS=$("${DIR_CLI}" service list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')
STD_USERS=$("${DIR_CLI}" user list --login "${SSO_ADMIN}" --password "${SSO_PASS}" 2>/dev/null | awk '{print $NF}')

# 4. Combine, strip dynamic @domain suffixes, filter patterns, and sort uniquely
# Patterns include: aps-, srm-, snapservice, hms-, vr-sa, vsan, ims-, h5-dr-, dr-sa-
CLEAN_ACCOUNTS=$(echo -e "${SVC_ACCTS}\n${SOL_USERS}\n${STD_USERS}" \
    | sed "s/@${SSO_DOMAIN}//g; s/@vsphere.local//g" \
    | tr -d '\r' \
    | awk '{$1=$1};1' \
    | grep -E -i "^(aps-|srm-|snapservice|hms-|vr-sa|vsan|ims-|h5-dr-|dr-sa-)" \
    | sort -u)

# Check if any accounts were found
if [[ -z "${CLEAN_ACCOUNTS}" ]]; then
    echo "[-] No matching Protection & Recovery service accounts discovered." >&2
    unset SSO_PASS
    exit 0
fi

COUNT=$(echo "${CLEAN_ACCOUNTS}" | wc -l)
echo "[+] Discovered ${COUNT} matching account(s)." >&2

# 5. Output results
if [[ -n "${OUTPUT_FILE}" ]]; then
    echo "${CLEAN_ACCOUNTS}" > "${OUTPUT_FILE}"
    echo "[+] Saved alphabetically sorted list to: $(pwd)/${OUTPUT_FILE}" >&2
else
    # Output raw list to stdout for redirection/piping
    echo "${CLEAN_ACCOUNTS}"
fi

unset SSO_PASS