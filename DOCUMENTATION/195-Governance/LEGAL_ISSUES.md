## Important Notice on ZFS Build Scripts and Licensing

This project includes scripts that automate the process of building ZFS kernel modules from source on the user’s machine. It is important to understand the legal implications surrounding this practice.

### Legal Position Summary

- ZFS is licensed under the **Common Development and Distribution License (CDDL)**, while the Linux kernel uses the **GNU General Public License v2 (GPLv2)**. These licenses are incompatible, creating legal complexities related to distribution of ZFS modules for Linux.

- **Distributing build scripts alone**—without providing pre-compiled ZFS binaries—is generally considered **low legal risk**. This is because the build and combination of CDDL-licensed ZFS code with the GPL-licensed Linux kernel are performed locally by the user, for their personal or internal use.

- Many Linux distributions and projects provide scripts or package build files for users to compile ZFS modules themselves, thereby avoiding direct distribution of potentially legally problematic binaries.

- The **legal risk increases** if pre-compiled ZFS kernel modules are distributed, as this may be considered distribution of a combined work violating license terms.

### User Responsibility

Users are responsible for building the software themselves on their own systems, and for ensuring compliance with all applicable licenses and legal requirements regarding ZFS usage.

