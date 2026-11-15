# GitHub sign-in

For HTTPS remotes on `github.com`, the credential dialog offers **Continue
with GitHub CLI** alongside the username/access-token form. GitHub CLI (`gh`)
is optional; install it from [cli.github.com](https://cli.github.com/) or with
`brew install gh`.

If SmallGit cannot find `gh`, click **Open In-App Terminal** below the error.
The dialog closes and the embedded terminal is filled with `brew install gh`.
Press Enter to run it, then retry the original Git operation and sign in.
Opening the terminal does not run the command automatically.

1. Click **Continue with GitHub CLI** when a Git operation requests credentials.
2. If the active `gh` account is already authenticated, SmallGit uses it.
   Otherwise, copy the one-time code shown in the dialog, click **Open GitHub**,
   and approve the sign-in in your browser.
3. SmallGit runs `gh auth setup-git --hostname github.com`, configuring Git's
   credential helper for GitHub (including `gist.github.com`) in your global
   Git configuration. Other Git providers retain their existing configuration.
4. The failed operation is retried. If the selected repository changed while
   signing in, select the original repository and retry there instead.

**Cancel** stops SmallGit's pending authentication process and prevents retry.
It does not log out an account already authenticated by `gh`. Signing in times
out after ten minutes; retry to request another device code.

SmallGit does not fetch a token with `gh auth token` or copy it into its own
config/logs. GitHub CLI owns credential storage; see its
[login documentation](https://cli.github.com/manual/gh_auth_login) and
[Git credential helper documentation](https://cli.github.com/manual/gh_auth_setup-git).
The active account can be changed with `gh auth switch --hostname github.com`.
An invalid `GH_TOKEN` environment variable must be corrected or removed before
browser login can work.

This option currently applies to `https://github.com` only. SSH remotes use
SSH keys/agents, and other hosts keep the existing username/access-token form.

## Permission to push workflow files

An existing `gh` login can work for repositories while lacking the `workflow`
scope needed to create or update `.github/workflows/` files. GitHub then rejects
the push with `without \`workflow\` scope`; installing `gh` again does not fix it.

SmallGit recognizes this rejection for GitHub HTTPS remotes and offers
**Authorize Workflow Access**. Clicking it runs
`gh auth refresh --hostname github.com --scopes workflow` for the active account.
Copy the device code, open GitHub, and approve the additional permission.
If there is no active login, the sign-in requests this scope instead.
Once authorization and credential-helper setup succeed, SmallGit retries the
pending push in the original repository. Cancel or failure prevents that retry.
Normal sign-in does not request this additional scope.

The same recovery can be run manually in a terminal:

```sh
gh auth refresh --hostname github.com --scopes workflow
```

Approve on GitHub, then Push again. Refresh adds the requested scope while
preserving existing ones; see [GitHub CLI's refresh documentation](https://cli.github.com/manual/gh_auth_refresh).
If `GH_TOKEN` supplies the credential, update that token's permissions or remove
the override before refreshing the stored `gh` login.

Automated tests use fake authentication and temporary Git repositories.
Browser approval and the installed `gh`/Keychain combination need a manual
acceptance check on the user's machine.
