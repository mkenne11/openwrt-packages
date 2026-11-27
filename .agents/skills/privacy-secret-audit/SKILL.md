---
name: privacy-secret-audit
description: >-
  Audit git-tracked files and recent commit metadata for secrets (private keys,
  API keys, tokens, passwords), personal network details (IP addresses, VLANs,
  hostnames, MACs), and personal information (usernames, social account IDs,
  emails, local paths). Use this skill before committing or pushing changes, or
  whenever the user asks to review the repository for secrets or PII.
---

# Privacy & Secret Audit (Git-Tracked Files)

Scan all files tracked by Git (plus recent commit author metadata) for accidental exposure of secrets, personal network topology, or personal information.

## Procedure

1. **Run the audit script** from the repository root:
   ```bash
   ./.agents/skills/privacy-secret-audit/scripts/audit-tracked.sh
   ```
   Pass `--include-placeholders` to also inspect standard documentation examples (e.g., `192.168.1.1`, `76.76.2.11`).

2. **Handle secret matches safely**:
   - **Never echo raw secret values** (private keys, tokens, passwords, resolver IDs) in your response.
   - Report only the **file path, line number, and finding category** (the script already redacts secret line contents).

3. **Review and classify findings**:
   - Separate **true positives** from known safe entries in this repository:
     - Approved GitHub noreply email: `12181805+mkenne11@users.noreply.github.com`
     - Public signing key: `keys/public-key.pem` (public key, safe to commit)
     - Documentation examples: `192.168.1.1`, `0.0.0.0/0`, Control D public bootstrap IP `76.76.2.11`, `YOUR_RESOLVER_ID`
   - Manually inspect any flagged lines in context (especially under `net/*/files/` or `docs/`) to confirm whether an IP, VLAN, hostname, username, or email is personal.

4. **Report clearly**:
   - Group results under **Secrets**, **Sensitive Network Details**, **Personal Details**, and **Git Commit Metadata**.
   - Provide clickable file/line links and concrete remediation steps (e.g., move secrets to GitHub Actions Secrets or gitignored files, replace personal emails with the GitHub noreply address, scrub or amend unpushed commits).
