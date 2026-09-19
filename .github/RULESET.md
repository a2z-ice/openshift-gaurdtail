# GitHub ruleset for the guardrails repository

Apply to branch `main` (Settings → Rules → Rulesets → New branch ruleset). Enforcement: **Active**. Bypass list: **empty** (not even org admins). Repository admins who need an emergency merge use the break-glass procedure in `docs/09-runbooks.md`, which is itself audited.

| Rule | Setting |
|---|---|
| Restrict deletions | on |
| Restrict force pushes | on |
| Require linear history | on |
| Require signed commits | on (GPG/SSH/Sigstore) |
| Require a pull request before merging | on |
| Required approvals | **2** |
| Dismiss stale pull request approvals when new commits are pushed | on |
| Require review from Code Owners | on |
| Require approval of the most recent reviewable push | on |
| Require conversation resolution before merging | on |
| Require status checks to pass | `policy-ci / validate` (strict: branch must be up to date) |
| Require deployments to succeed | optional: `preprod-dry-run` environment |
| Block creations (of other refs matching) | off |

Additional repository settings:

- Settings → General → *Allow merge commits* off, *Allow squash merging* on, *Allow rebase merging* off (keeps one reviewed commit per change).
- Settings → Actions → *Require approval for all outside collaborators*; workflow permissions read-only.
- Settings → Code security → Secret scanning + push protection on (blocks committing SMTP passwords / Teams webhook URLs).
- Organisation: the `@example-org/security` and `@example-org/platform-engineering` teams must each have at least 3 members with write access so 2 reviewers are always available.

Create via API (idempotent, run from a repo admin session):

```bash
gh api -X POST repos/example-org/openshift-administration/rulesets \
  --input .github/ruleset-main.json
```
