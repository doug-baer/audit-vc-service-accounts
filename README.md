# audit-vc-service-accounts
Scripts to audit vCenter service accounts, specifically targeting protection and recovery services

These scripts should be run on the vCenter and require SSO administrative credentials to be provided during execution.

* vlr-check-svc.sh -- original script to gather information about VLR-specific service accounts 
* vlr-get-accounts.sh -- returns a list of accounts matching known patterns (related to VLR)
* vlr-audit-svc.sh -- returns password-specific properties for the provided accounts
* vlr-update-svc-expire.sh -- adjusts password properties for the provided accounts to never expire and un-expire

Some useful commands

# Obtain a list of all service accounts
/usr/lib/vmware-vmafd/bin/dir-cli svcaccount list

# Set password to never expire
/usr/lib/vmware-vmafd/bin/dir-cli user modify --account <ACCOUNT_NAME> --password-never-expires

# Obtain details about a specific account
/usr/lib/vmware-vmafd/bin/dir-cli user find-by-name --account <ACCOUNT_NAME> --level 2


October 16, 2026
