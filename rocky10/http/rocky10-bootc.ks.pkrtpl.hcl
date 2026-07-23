text --non-interactive
rootpw --lock
zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart
part / --fstype=xfs --grow --asprimary

network --bootproto=dhcp --device=link --activate --onboot=on
ignoredisk --only-use=vda
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
timezone UTC --utc
reboot --eject

# OSTree/bootc container setup
# Set BOOTC_IMAGE_REF and BOOTC_REGISTRY_AUTH via template variables
bootc --source-imgref=${BOOTC_IMAGE_REF}

%pre
# Configure container registry authentication if provided
${BOOTC_PRE_AUTH}
%end

%post
# Post-installation container registry configuration
${BOOTC_POST_AUTH}

# Additional post-install customization for MAAS compatibility
# Ensure cloud-init is enabled (should be in bootc image)
systemctl enable cloud-init cloud-init-local cloud-final cloud-config || true

# Clear any installation-specific network config
rm -f /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null || true

# Ensure NetworkManager is configured for MAAS
cat > /etc/NetworkManager/conf.d/99-maas.conf << 'EOF'
[main]
plugins=keyfile
dns=default

[keyfile]
unmanaged-devices=none
EOF

%end
