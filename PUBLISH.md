# Publish to GitHub

The archive is a ready-to-publish repository folder, not a GitHub repository already created in your account. No GitHub credentials are included.

With `git` and GitHub CLI `gh` installed, after authenticating with your own account (`gh auth login`), run **inside the unpacked `tiktok-blocklists` directory**:

```sh
git init -b main
git add .
git commit -m "Initial TikTok blocklist synchronizer"
gh repo create tiktok-blocklists --public --source . --remote origin --push
```

`gh repo create` creates a **public remote repository**. That is the explicitly requested visibility setting. The Git push uploads the entire project, including the workflow and the addresses in `sources/`.

If you prefer creating the repository through GitHub's UI, choose an empty public repository first and use its displayed *push an existing repository* instructions to push this folder.

Then visit GitHub `Actions > Sync TikTok blocklists > Run workflow`. The workflow fetches all current M4jx sources and populates `dist/`/`upstream/` in a commit. GitHub Actions must have permission to write repository contents. The scheduled jobs start once Actions is enabled.

No router scripts or router settings are changed during publication.
