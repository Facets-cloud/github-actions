# Facets Preview & Security Scan GitHub Action

> ⚠️ **Deprecated.** This action is based on the legacy `ftf` CLI and is kept only for
> existing workflows. It receives no new features. Use
> [**module-ci-action**](../module-ci-action/README.md) instead — the `raptor`-based
> action the Facets control plane wires into bootstrapped modules repositories.

This GitHub Action performs:

✅ Terraform formatting checks  
✅ Terraform validation  
✅ Checkov security scanning  
✅ Facets module preview

## 🛠 Usage

To use this action, add it to your workflow:

```yaml
jobs:
  preview:
    runs-on: ubuntu-latest  # Ensure Ubuntu is used
    steps:
      - name: Run Facets Preview & Security Scan
        uses: Facets-cloud/github-actions/module-preview-action@master
        with:
          control_plane_url: ${{ secrets.CONTROL_PLANE_URL }}
          username: ${{ secrets.FACETS_USERNAME }}
          token: ${{ secrets.FACETS_API_TOKEN }}
          ftf_cli_version: 0.2.1 # Optional: Specify only if you want to use a specific version of the CLI
```

---

## ⚠️ **Running Inside a Container**

This action requires an **Ubuntu-based environment**.  
If your workflow runs on **Windows or macOS**, you can **run the step inside a container**:

```yaml
jobs:
  preview:
    runs-on: ubuntu-latest

    container: # Run the job in an Ubuntu container
      image: ubuntu:20.04
      options: --user root

    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7

      - name: Run Facets Preview & Security Scan
        uses: Facets-cloud/github-actions/module-preview-action@master
        with:
          control_plane_url: ${{ secrets.CONTROL_PLANE_URL }}
          username: ${{ secrets.FACETS_USERNAME }}
          token: ${{ secrets.FACETS_API_TOKEN }}
          ftf_cli_version: 0.2.1 # Optional: Specify only if you want to use a specific version of the CLI
```

## 🌱 Enabling Dry Run Mode

**Dry Run Mode (`dry_run: true`)** allows the action to perform **only validation checks** without executing a Facets module preview.

### When Dry Run Mode is Enabled (`dry_run: true`), the action will:

✅ **Run Terraform formatting** (`terraform fmt`)  
✅ **Run Terraform validation** (`terraform validate`)  
✅ **Run Checkov security scanning**  
❌ **Skip Facets module preview**  
