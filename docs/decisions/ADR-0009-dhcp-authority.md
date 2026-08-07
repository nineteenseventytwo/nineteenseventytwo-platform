# ADR-0009: Kea reservations are authoritative for addressing

**Status:** Accepted
**Date:** 2026-08-07

## Context

A node's address can be set in two places: statically in cloud-init's
`network-config`, or as a DHCP reservation in Kea on OPNsense. Setting it in
both is belt-and-braces, but only if one of them is clearly authoritative —
otherwise it is two sources of truth that will eventually disagree.

## Decision

**Kea reservations on OPNsense are authoritative.** cloud-init renders a DHCP
stanza. A static stanza is available behind `cloudinit_use_static: true` for
bringing a node up before OPNsense knows about it.

## Consequences

- Addressing lives in one place. Changing a node's address is an OPNsense
  change, not an OPNsense change plus a reflash.
- **A reimaged Pi comes up correctly with no local edits.** That is the property
  that matters most — reimaging is meant to be cheap.
- The inventory's `ansible_host` values must match the reservations. They do not
  *assign* anything; they record what Kea will hand out. A mismatch means
  Ansible cannot reach a node that is otherwise perfectly healthy, which is a
  confusing ten minutes.
- MAC addresses are therefore load-bearing and live in the inventory. Replacing
  a Pi means updating both the reservation and `hosts.yml`.
- Three ranges must not overlap: DHCP pool `.100–.199`, node reservations
  `.201–.204`, MetalLB `.240–.250`. An overlap presents as a service that works
  until the pool hands out an address MetalLB is already announcing — an
  intermittent failure that looks like anything except DHCP.
- **Cost:** the lab now depends on OPNsense being up for a node to boot with an
  address. In practice OPNsense is also the gateway and DNS, so it was already a
  hard dependency.

## Alternatives considered

**Static in cloud-init, authoritative.** Rejected: it puts addressing in the
boot partition of each SSD, where changing it means physical access or a reflash.

**Both, with no stated authority.** Rejected explicitly. This is the failure
mode the ADR exists to prevent.
