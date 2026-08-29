FROM ghcr.io/ublue-os/aurora:latest

# Import Linux Surface repository and signing keys
RUN curl -s https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | gpg --dearmor -o /etc/pki/rpm-gpg/RPM-GPG-KEY-surface && \
    curl -s https://pkg.surfacelinux.com/fedora/linux-surface.repo \
    -o /etc/yum.repos.d/linux-surface.repo

# Swap the Fedora kernel with kernel-surface and install Surface packages
RUN dnf5 -y swap kernel kernel-surface \
    --allowerasing && \
    dnf5 -y swap kernel-core kernel-surface-core \
    --allowerasing && \
    dnf5 -y swap kernel-modules kernel-surface-modules \
    --allowerasing && \
    dnf5 -y swap kernel-modules-extra kernel-surface-modules-extra \
    --allowerasing && \
    dnf5 -y install \
    iptsd \
    libwacom-surface \
    dnf5 clean all

# Enable the Intel Precise Touch & Stylus daemon for touch and pen support
RUN systemctl enable iptsd.service

# Regenerate initramfs for the newly installed Surface kernel
RUN export KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-surface | head -n 1)" && \
    dracut --kver "${KERNEL_VERSION}" --force --add-drivers "surface_aggregator surface_aggregator_registry surface_hid" /usr/lib/modules/${KERNEL_VERSION}/initramfs.img
