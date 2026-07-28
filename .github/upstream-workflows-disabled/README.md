# Disabled upstream workflows

Monad preserves these inherited E2B workflows as merge/rebase reference, but
GitHub must not discover or execute them in the public fork.

They include upstream release, publish, deploy, scheduled, self-hosted-runner,
and umbrella pull-request automation. Some request write or OIDC permissions;
some execute repository code with Docker or elevated host access; and some can
mutate a repository using only `GITHUB_TOKEN`.

Only `.github/workflows/monad-terraform-validation.yml` is intended to be
enabled for this fork initially. It is GitHub-hosted, read-only, SHA-pinned,
and performs backend-free Terraform validation.

An upstream sync must keep these files in this directory until Engram owns a
separately named workflow with an explicit permission, runner, credential,
environment, and rollback design.
