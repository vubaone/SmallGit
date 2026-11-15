# Security policy

Report suspected vulnerabilities privately to **dev@vuba.one**. Do not put
credentials, private repository contents, or exploitable details in a public
issue or pull request.

Include the SmallGit version or commit, macOS and Git versions, the affected
operation, expected and actual behavior, and steps using a temporary repository
with fictional data. Describe the impact and any workaround you have found.
Remove tokens, personal paths, private remote URLs, and unrelated log output.

SmallGit is in pre-release development. Security fixes target the current
`main` branch and the latest published release; older versions do not have
separate maintenance branches.

The maintainer will coordinate a fix and disclosure with the reporter.
If a credential has already been exposed, revoke or rotate it with its provider;
deleting a file or public issue alone does not invalidate the credential.
