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
RUN dnf5 -y --allowerasing install \
      kernel-surface kernel-surface-core kernel-surface-modules \
      kernel-surface-modules-core kernel-surface-modules-extra && \
    STOCK="$(rpm -qa 'kernel' 'kernel-core' 'kernel-modules' 'kernel-modules-core' 'kernel-modules-extra')" && \
    if [ -n "$STOCK" ]; then dnf5 -y remove --no-autoremove $STOCK; fi && \
    dnf5 -y install iptsd libwacom-surface && \
    dnf5 clean all

# Fail the build if we did not end up on the surface kernel, and print the
# resolved version to the CI log so you can see exactly which kernel landed.
RUN rpm -q kernel-surface >/dev/null || { echo "ERROR: kernel-surface not installed"; exit 1; } && \
    echo ">>> Surface kernel installed: $(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-surface)"

# Enable the Intel Precise Touch & Stylus daemon for touch and pen support.
RUN systemctl enable iptsd.service

# Regenerate the initramfs for the surface kernel.
RUN KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-surface | tail -n 1)" && \
    dracut --kver "${KERNEL_VERSION}" --force \
      --add-drivers "surface_aggregator surface_aggregator_registry surface_hid" \
      "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
