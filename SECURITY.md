# Security policy

## Supported versions

Security fixes are made on the `main` branch and included in the next release. Use the latest release tag, or `main`, for deployments.

## Report a vulnerability

Don't report security vulnerabilities through public issues, discussions, or pull requests.

Report them privately through [GitHub private vulnerability reporting](https://github.com/bmkinney/azure-file-replication-non-region-pair/security/advisories/new) for this repository. Include:

- the affected files, deployment method (Bicep, Terraform, or portal guide), and version or commit;
- the steps to reproduce the issue, and its impact; and
- any suggested fix.

You should get an acknowledgment within five business days. This is a community project without a service-level agreement, so timelines for a fix depend on severity and maintainer availability.

## Don't share sensitive data

Don't include subscription IDs, tenant IDs, resource IDs, email addresses, access tokens, storage keys, SAS tokens, or inventory and audit reports in any report, issue, or pull request. Replace them with placeholders.

## Security design

The templates are designed to run without shared keys or public storage access: the replication jobs authenticate to Azure Files with managed identities, the storage accounts disable shared key access and public network access, and the registry is reachable only through private endpoints after the image build. See [docs/infrastructure-plan.md](docs/infrastructure-plan.md) for the permission boundaries. Report any deviation from this design as a vulnerability.
