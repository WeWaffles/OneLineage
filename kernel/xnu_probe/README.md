# XNU handoff ABI probe

This directory contains milestone zero of the experimental SM-S948U XNU
handoff work: an inert module that does nothing except load and unload. It is
not kexec and cannot boot XNU or any other payload.

Build it only against a prepared Android common 6.12 tree configured from the
phone's `/proc/config.gz`. Before a device install, run `tools/verify_module_abi.py`
against the resulting `.ko`. The verifier requires the exact release string
and `module_layout` CRC recorded in `kernel/device-abi/sm-s948u-azf1.json` and
rejects unexpected imported symbols.

Do not synthesize `Module.symvers` or replace the generated `module_layout` CRC
with a value copied from a shipped module. A metadata match does not establish
that Samsung's private `struct module` layout matches Android common source.
The first reconstructed SM-S948U probe demonstrated this boundary: it loaded,
but `/proc/modules` marked it permanent and the kernel rejected unload. Device
loading is therefore blocked until exact vendor build inputs are available.

Do not add a device node, ioctl, restart handler, payload buffer, or execution
operation to this probe. Those belong to later, separately reviewed milestones.
