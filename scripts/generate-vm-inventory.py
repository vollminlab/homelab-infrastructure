#!/usr/bin/env python3
"""Generate the VM Inventory tables in docs/infrastructure.md from the collected
vSphere export (hosts/vsphere/vms.json).

The two tables between the GENERATED markers in infrastructure.md are produced
entirely from vms.json — never hand-edit them. Workflow: refresh the export with
scripts/Export-VSphereConfigs.ps1, then run this script to regenerate the doc.

Only intrinsic specs that don't move on their own are rendered (vCPU / RAM / disk /
network / IP). Placement (ESXi host and datastore) is deliberately omitted: DRS moves
hosts dynamically and datastores move on manual storage migration, so pinning either in
a doc guarantees drift.

Usage:
  scripts/generate-vm-inventory.py           # rewrite the tables in place
  scripts/generate-vm-inventory.py --check   # exit non-zero if the doc is stale (CI)
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VMS_JSON = REPO / "hosts" / "vsphere" / "vms.json"
DOC = REPO / "docs" / "infrastructure.md"

BEGIN = "<!-- BEGIN GENERATED: vm-inventory (scripts/generate-vm-inventory.py) -->"
END = "<!-- END GENERATED: vm-inventory -->"

# Folder -> sub-table, in render order. vCenter-folder VMs (VCHA appliances) are
# intentionally excluded; they are managed out-of-band.
SECTIONS = [
    ("Kubernetes", lambda folder: folder == "k8s Cluster VMs"),
    ("Infrastructure VMs", lambda folder: folder.startswith("Linux")),
]


def first(obj):
    """vms.json stores single-NIC/single-disk VMs as an object and multi- as a list."""
    if isinstance(obj, list):
        return obj[0] if obj else {}
    return obj or {}


def net_label(name):
    # "152-DPG-GuestNet" -> "GuestNet", "160-DPG-DMZ" -> "DMZ"
    return re.sub(r"^\d+-DPG-", "", name or "") or "?"


def primary_ip(ips):
    ips = ips or []
    for ip in ips:  # prefer the 192.168.x management/LAN address
        if ip.startswith("192.168."):
            return ip
    for ip in ips:  # otherwise any IPv4
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            return ip
    return "?"


def row(vm):
    disk = first(vm.get("Disks"))
    net = first(vm.get("Networks"))
    return [
        vm["Name"],
        str(vm.get("NumCpu", "?")),
        f'{vm.get("MemoryGB", "?")} GB',
        f'{disk.get("CapacityGB", "?")} GB',
        net_label(net.get("NetworkName")),
        primary_ip(vm.get("IPs")),
    ]


def table(vms):
    header = ["VM", "vCPU", "RAM", "Disk", "Network", "IP"]
    rows = [row(v) for v in sorted(vms, key=lambda v: v["Name"])]
    widths = [max(len(header[i]), *(len(r[i]) for r in rows)) for i in range(len(header))]

    def line(cells):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells)) + " |"

    sep = "|" + "|".join("-" * (w + 2) for w in widths) + "|"
    return "\n".join([line(header), sep, *(line(r) for r in rows)])


def render():
    vms = json.loads(VMS_JSON.read_text())
    blocks = []
    for title, matches in SECTIONS:
        members = [v for v in vms if matches(v.get("Folder", ""))]
        blocks.append(f"#### {title}\n\n{table(members)}")
    body = "\n\n".join(blocks)
    return (
        f"{BEGIN}\n"
        "<!-- Generated from hosts/vsphere/vms.json — do not hand-edit. "
        "Regenerate with scripts/generate-vm-inventory.py. -->\n\n"
        f"{body}\n\n{END}"
    )


def main():
    doc = DOC.read_text()
    pattern = re.compile(re.escape(BEGIN) + ".*?" + re.escape(END), re.DOTALL)
    if not pattern.search(doc):
        sys.exit(f"error: markers not found in {DOC}\n  expected: {BEGIN} ... {END}")
    updated = pattern.sub(lambda _: render(), doc)

    if "--check" in sys.argv[1:]:
        if updated != doc:
            sys.exit(
                "error: VM inventory in docs/infrastructure.md is stale — "
                "run scripts/generate-vm-inventory.py"
            )
        print("VM inventory is up to date.")
        return

    DOC.write_text(updated)
    print(f"Regenerated VM inventory in {DOC.relative_to(REPO)}")


if __name__ == "__main__":
    main()
