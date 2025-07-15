#!/bin/bash -x

OCI_HOSTNAME=/etc/hostname-oci
echo "Current hostname: $(hostname)"
until [[ -s $OCI_HOSTNAME ]]; do
    /usr/bin/curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/hostname -o $OCI_HOSTNAME
done

echo "Setting hostname to $(cat $OCI_HOSTNAME)"

cat $OCI_HOSTNAME > /proc/sys/kernel/hostname
