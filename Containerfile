FROM ghcr.io/ublue-os/aurora:latest

# --- Why this file looks the way it does ------------------------------------
# linux-surface ships packages in per-Fedora-release directories:
#   https://pkg.surfacelinux.com/fedora/f<NN>/
# As of 2026-08 the newest that exists is f43 (kernel 6.19.8). Aurora :latest
# is Fedora 44, and linux-surface has NO f44 yet. The upstream .repo file uses
# baseurl=.../f$releasever/ (= f44 here) plus skip_if_unavailable=1, so dnf
# silently ignored a 404 repo and the kernel swap failed with "no match for
# kernel-surface". We therefore pin the surface release explicitly and turn the
# silent-skip OFF, so a missing repo fails the build LOUDLY.
#
# Flip SURFACE_RELEASE to 44 the moment https://pkg.surfacelinux.com/fedora/f44/
# appears. Until then this installs the f43 surface kernel on the f44 base.
ARG SURFACE_RELEASE=43

# Import the linux-surface signing key and write the repo file inline.
RUN curl -fsSL https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
      | gpg --dearmor -o /etc/pki/rpm-gpg/RPM-GPG-KEY-surface && \
    printf '%s\n' \
      '[linux-surface]' \
      'name=linux-surface' \
      "baseurl=https://pkg.surfacelinux.com/fedora/f${SURFACE_RELEASE}/" \
      'enabled=1' \
      'gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-surface' \
      'repo_gpgcheck=0' \
      'skip_if_unavailable=0' \
      > /etc/yum.repos.d/linux-surface.repo

# Replace the stock Fedora kernel with kernel-surface. Install the surface
# kernel family first (one transaction), then remove whatever stock kernel
# packages remain. This is version-robust: it does not assume which kernel
# subpackages the base image happens to ship (kernel-modules-core is separate
# on modern Fedora and must not be left behind mismatched).
RUN dnf5 -y install --allowerasing \
      kernel-surface kernel-surface-core kernel-surface-modules \
      kernel-surface-modules-core kernel-surface-modules-extra && \
    STOCK="$(rpm -qa 'kernel' 'kernel-core' 'kernel-modules' 'kernel-modules-core' 'kernel-modules-extra')" && \
    if [ -n "$STOCK" ]; then dnf5 -y remove --no-autoremove $STOCK; fi && \
    dnf5 -y install iptsd && \
    dnf5 clean all
# NOTE: libwacom-surface is deliberately NOT installed. On the Fedora 44 base it
# conflicts with the newer stock libwacom, and forcing it with --allowerasing
# cascades into removing KDE Plasma. The pen and touch work through iptsd
# without it. Revisit only when linux-surface publishes f44.

# Fail the build if we did not end up on the surface kernel, and print the
# resolved version to the CI log so you can see exactly which kernel landed.
RUN rpm -q kernel-surface >/dev/null || { echo "ERROR: kernel-surface not installed"; exit 1; } && \
    echo ">>> Surface kernel installed: $(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-surface)"

# iptsd (Intel Precise Touch & Stylus) needs no manual enable. It ships a
# templated unit iptsd@.service plus a udev rule that starts it automatically
# when the touchscreen appears. There is no plain iptsd.service to enable.

# Regenerate the initramfs for the surface kernel. Use --no-hostonly so the
# image is portable (the build host is not the target hardware).
# dracut logs non-fatal errors on this ostree base (missing /dev/log, and /root
# is a dangling symlink), so exit 0 alone does not prove the initramfs is good.
# The build therefore checks the output directly: it must exist, be non-empty,
# and contain the Surface System Aggregator driver needed at early boot.
RUN KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-surface | tail -n 1)" && \
    IMG="/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" && \
    dracut --kver "${KERNEL_VERSION}" --force --no-hostonly \
      --add-drivers "surface_aggregator surface_aggregator_registry surface_hid" \
      "$IMG" && \
    test -s "$IMG" && \
    echo ">>> initramfs built: $(du -h "$IMG" | cut -f1) at $IMG" && \
    lsinitrd "$IMG" | grep -q surface_aggregator && \
    echo ">>> initramfs contains surface_aggregator: OK"
