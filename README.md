# audit-vc-service-accounts
Scripts to audit vCenter service accounts, specifically targeting protection and recovery services

These scripts should be run on the vCenter and require SSO administrative credentials to be provided during execution.

* vlr-check-svc.sh -- original script to gather information about VLR-specific service accounts, also lists critical group membership
* vlr-get-accounts.sh -- returns a list of accounts matching known patterns (related to VLR)
* vlr-audit-svc.sh -- returns password-specific properties for the provided accounts
* vlr-update-svc-expire.sh -- adjusts password properties for the provided accounts to never expire and un-expire

Some useful commands

# Obtain a list of all service accounts
`/usr/lib/vmware-vmafd/bin/dir-cli svcaccount list`

# Obtain details about a specific account
`/usr/lib/vmware-vmafd/bin/dir-cli user find-by-name --account <ACCOUNT_NAME> --level 2`

# Set password to never expire
`/usr/lib/vmware-vmafd/bin/dir-cli user modify --account <ACCOUNT_NAME> --password-never-expires`

# Set the global SSO policy to not expire passwords
```
/opt/likewise/bin/ldapmodify -x -D "cn=Administrator,cn=Users,dc=vsphere,dc=local" -W <<EOF 
dn: cn=password and lockout policy,dc=vsphere,dc=local
changetype: modify
replace: vmwPasswordLifetimeDays
vmwPasswordLifetimeDays: 0
EOF
```

NOTE: these scripts use a hardcoded "vsphere.local" SSO domain and woud need to be modified if you have changed your default SSO domain.

October 16, 2026
