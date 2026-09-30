# Contributing

Thank you for helping improve this project. It solves one problem, private Azure Files replication between two Azure regions that aren't a paired set, with three deployment methods that build the same topology: Bicep, Terraform, and an Azure portal guide.

## Ground rules

- **Keep content generic and portable.** Don't add customer names, organization-specific context, internal links, or references to private programs or tenants to code, documentation, or examples. Use placeholders such as `<subscription-id>` and example domains such as `example.com`.
- **Never commit environment values or secrets.** Subscription and tenant IDs, alert addresses, access tokens, inventory and audit reports, Terraform state, and real parameter or variable files stay out of source control. Put them in the git-ignored files that the deployment guides name.
- **Keep the methods in step.** A change to the topology, a setting, a name, or an output in one method should be made in the others, or noted as a difference in the method's README. The Bicep greenfield deployment is the reference for the Terraform configuration and the portal guide.
- **Nothing deploys automatically.** Don't add triggers that deploy to Azure on push, pull request, or schedule.

## Development setup

You need PowerShell 7, Azure CLI with Bicep (`az bicep upgrade`), Terraform 1.9 or later, and Git. The tests make no Azure calls, so you don't need an Azure subscription to run them. See [Prerequisites](README.md#prerequisites) for the tools that deployments need.

## Run the tests

Run the tests from the repository root before you open a pull request:

```powershell
Get-ChildItem ./tests/test-*.ps1, ./src/azcopy-job/test-run-sync.ps1 | ForEach-Object {
    pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($_.Name) failed." }
}
```

[Tests](README.md#tests) describes what each test checks. When you change a script's Azure CLI or Terraform calls, add a rule for each new call to the test that fakes them. When you add or rename a heading, `tests/test-docs.ps1` finds the links that you need to update.

## Pull requests

- Keep each pull request focused on one change, and describe what it changes and why.
- Update the documentation that describes the behavior you changed, and add an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
- Say which deployment methods the change affects, and how you tested it. If you deployed it to Azure, say which method and profile you used, without sharing IDs.
- Follow the existing style: PowerShell scripts call Azure CLI through their `Invoke-Az` wrapper, which keeps warnings out of JSON output, and comments explain only what the code can't.

## Report bugs and security issues

Open an issue for bugs and feature requests. Report security vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Everyone who takes part in the project follows the [code of conduct](CODE_OF_CONDUCT.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE). As described in section 5 of the license, any contribution that you intentionally submit for inclusion in the project is licensed under the same terms, without additional terms or conditions.
