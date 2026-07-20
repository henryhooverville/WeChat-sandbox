# Bootstrapping Engine (cidata.md)

* **Why:** Bypasses interactive installation prompts and injects static WAN routing in a zero-trust network where local DHCP is blocked.


* **How:** It groups `user-data` and `meta-data` config files into a virtual CD-ROM compiled with the lowercase volume label `cidata`.


* **Trigger:** The host script mounts this virtual disk alongside the base Ubuntu Server ISO during VM generation.


* **Action:** On boot, the kernel reads the disk to establish connectivity, clone the repository, and execute the Ansible hardening playbook to configure the VM.