# HPS regulatory and release policy

This document declares the project's regime and the policy posture that follows
from it, per the eight-dimension framework's policy-compliance dimension
(`/srv/projects/toolchain-development/TOOLCHAIN.md`, `POLICY.md`).

## Regime

HPS is developed under the **open-source release** regime. It is published as
free software for others to run, inspect and modify; it is not a commercial
product placed on the market by the team, and the team is not, for HPS, a
manufacturer taking on the full CRA manufacturer obligations.

Under the EU Cyber Resilience Act this corresponds to the **open-source
software steward** posture (CRA Article 24): the project maintains a security
policy, coordinated vulnerability disclosure, and an SBOM, but does not carry
the manufacturer's Declaration of Conformity, CE marking, or conformity-
assessment obligations that attach to a product sold or supplied in the course
of a commercial activity.

If HPS is later offered as a hosted or commercial product, the regime is
re-declared and the heavier obligations (DoC, support-period commitment,
conformity assessment) are taken on at that point.

## Licence

HPS is licensed under the **GNU Affero General Public License, version 3 or
later (AGPL-3.0-or-later)**. The choice and its reasoning — transparency about
AI-assisted development and caution over training-data provenance — are set out
in `DOCUMENTATION/195-Governance/ai-use-statement.md`. The `LICENSE` file at the
repository root is authoritative.

Third-party licensing interactions are documented where they carry risk; in
particular the ZFS (CDDL) versus Linux kernel (GPLv2) position is covered in
`DOCUMENTATION/195-Governance/LEGAL_ISSUES.md`. HPS ships ZFS **build scripts**,
not pre-compiled modules, keeping the combination local to the user.

## Artefacts this regime requires

The following are maintained; each is produced under another dimension and
referenced here rather than duplicated:

- **Security policy and coordinated vulnerability disclosure** — `docs/SECURITY.md`.
- **Software Bill of Materials** — `sbom.json` (CycloneDX), covering the shipped
  language and the runtime component set. Versions track the Debian trixie
  suite and resolve at build time.
- **AI-use transparency statement** — `DOCUMENTATION/195-Governance/ai-use-statement.md`.
- **Changelog** — `CHANGELOG.md`, keyed by commit reference.
- **Architectural Decision Records** — `docs/adr/`.

## Support and compatibility posture

- **Support.** Best-effort community support via the project's issue tracker.
  No commercial support period is committed under the open-source regime.
- **Backward compatibility.** HPS carries no version tags yet and makes no
  backward-compatibility guarantee across commits; the registry configuration
  format is the main compatibility surface and changes to it are called out in
  the changelog. A compatibility policy is set when the project first tags a
  release.

## Not applicable under this regime

Declaration of Conformity, CE marking, conformity assessment, and a committed
commercial support period do not apply while HPS is an open-source project
rather than a product placed on the market. They are re-evaluated on any regime
change.
