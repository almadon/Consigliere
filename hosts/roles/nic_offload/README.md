# nic_offload

Switches off NIC offload features (`ethtool -K <if> tso off gso off gro off`) on the interfaces you name, at every boot. Why it exists: Intel e1000e ports can wedge
under TSO/GSO/GRO ("e1000e ... eno1: Detected Hardware Unit Hang" in the kernel log) and stay dead until a power cycle; Radon did exactly that on 2026-10-23.

- Set `nic_offload_interfaces` for the host (for example `[{name: eno1, disable: [tso, gso, gro]}]`). Empty (the default) does nothing.
- A small systemd unit applies the settings as soon as the interface exists; the interface's own network configuration (`/etc/network/interfaces`, netplan) is not touched.
- Applying it to a running interface can reset the link for a second or two.
- Cost: a little more CPU per packet on that port; irrelevant at gigabit rates on a server.
