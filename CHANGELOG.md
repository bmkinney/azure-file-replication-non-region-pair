# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- The Bicep existing-resource profile can reuse existing Log Analytics workspaces, with `primaryLogWorkspaceId` and `secondaryLogWorkspaceId`, for environments where Azure Policy blocks new workspaces. The inventory check verifies that each workspace exists and that the deploying identity can read its shared keys.
- Terraform deployment option in `deploy/terraform` for the greenfield topology, with `deploy.ps1` for the two-stage deployment and image build, offline Terraform tests, and example remote state configuration.
- Azure portal deployment guide in `deploy/portal`, with expandable Azure CLI and Azure PowerShell commands for every step.
- `-TerraformDirectory` mode for `scripts/switch-direction.ps1` and `scripts/grant-access.ps1`.
- Continuous integration for GitHub Actions and Azure Pipelines, and manually started example deployment pipelines for Bicep and Terraform on both platforms.
- Contributing, security, support, and code of conduct documents; issue and pull request templates; code owners; and Dependabot configuration.
- Tests for documentation links and for the pipeline definitions.

### Changed

- Relicensed the project under the Apache License 2.0, with a `NOTICE` file.
- Moved the Bicep templates from `infra/` to `deploy/bicep/`. Move local parameter files to the new folder, for example `deploy/bicep/main.local.bicepparam`; Git ignores the same file names there.
- Split the README: the main README covers the architecture and the guidance that every method shares, and `deploy/bicep/README.md` covers the Bicep profiles and scripts.
- Each freshness alert counts only its own job's success markers, by environment and job name, so both regions and other workloads can share a workspace. This applies to the Bicep and Terraform deployments and to the portal guide.
- Troubleshooting covers `RequestDisallowedByPolicy` deployment failures.
