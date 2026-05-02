---
name: manage-config-data
description: 'Create, export, or import configuration data (reference/seed records) for a Dataverse solution. Use when: creating a config data schema for the first time, exporting records from a dev environment to commit to source control, importing config data into an environment after solution deploy, seeding test data via pac data import. Always uses pac data — never DataverseApiClient, Dataverse Web API, or Power Automate flows to create seed data.'
---

# Manage Configuration Data

Create, export, and import configuration data stored under `deployments/data/{mainSolution}/` and deployed by the Package Deployer on every environment promotion.

## When to Use

- Creating a config data schema for the first time for a solution
- Exporting records from dev to commit to source control
- Importing config data into an environment manually (dev, dev-test, integration)
- Seeding test/reference records as part of a feature

## Critical Rule

> **Always use `pac data` commands.** Do NOT use the Dataverse Web API, DataverseApiClient, or Power Automate flows to create or import configuration data. `pac data export` and `pac data import` are the only supported mechanisms for config data in this ALM process.

## Data Location

Config data belongs to the **primary solution** (from `solutionAreas[x].mainSolution` in `environment-config.json`), never to a feature solution:

```
deployments/data/
  {prefix}_{SolutionName}/        # e.g. acm_AcmePlatform
    ConfigData.xml                # Schema file — defines which entities/fields to export
    data.xml                      # Exported records
    data_schema.xml               # Auto-generated schema output from pac data export
    [media/]                      # Optional: file attachments (notes, annotations)
```

## Skill Boundaries

| Need | Use instead |
|------|-------------|
| Deploy solution + import config data in one step | `deploy-solution` (use `data_solution_name` input) |
| Outer-loop package deploy | `deploy-package` |

---

## Step 1 — Confirm Prerequisites

```powershell
pac auth list   # Confirm an active profile for the target environment
```

Determine the primary solution name (`mainSolution`) from `environment-config.json`:
- `solutionAreas[x].mainSolution` — e.g. `acm_AcmePlatform`

---

## Step 2 — Create or Verify the Schema (First Time Only)

If `deployments/data/{mainSolution}/ConfigData.xml` does not yet exist, create it now.

A ConfigData.xml schema defines which entities and fields to export. Create it by hand for simple cases, or generate it from the Configuration Migration Tool for complex entity graphs.

### Simple hand-crafted schema example

For a contacts schema:

```xml
<?xml version="1.0" encoding="utf-8"?>
<entities>
  <entity name="contact" displayname="Contact" etc="2">
    <fields>
      <field displayname="First Name"    name="firstname"    type="String" primaryKey="false" />
      <field displayname="Last Name"     name="lastname"     type="String" primaryKey="false" />
      <field displayname="Email Address" name="emailaddress1" type="String" primaryKey="false" />
    </fields>
    <filter/>
  </entity>
</entities>
```

Save as `deployments/data/{mainSolution}/ConfigData.xml`.

> **Tip**: For lookup fields, add `lookupType="{target-entity-name}"` to the field element. For required system fields (like `contactid`), mark as `primaryKey="true"`.

### Using the Configuration Migration Tool (for complex schemas)

If your data involves many entities or complex relationships, use the CMT to generate the schema:

```powershell
# Launch the Configuration Migration Tool
pac tool cmt
```

Export the schema and copy the resulting `ConfigData.xml` to `deployments/data/{mainSolution}/`.

---

## Step 3 — Export Data from Dev

Run `pac data export` against the dev environment to produce `data.xml`:

```powershell
pac data export `
    --schema-file "deployments/data/{mainSolution}/ConfigData.xml" `
    --data-file   "deployments/data/{mainSolution}/data.xml" `
    --environment "<dev-environment-url>"
```

Or use the platform helper script (wraps the same command with logging):

```powershell
.platform/.github/workflows/scripts/Export-Configuration-Data.ps1 `
    -SolutionName "{mainSolution}" `
    -EnvironmentUrl "<dev-environment-url>"
```

Both produce:
- `data.xml` — the exported records
- `data_schema.xml` — the schema as read at export time (used by `pac data import`)

Commit both files to the feature branch.

---

## Step 4 — Import Data into an Environment

```powershell
pac data import `
    --data "deployments/data/{mainSolution}" `
    --environment "<target-environment-url>"
```

> The `--data` parameter points to the **folder** containing `data.xml` and `data_schema.xml`.

### Handling duplicate records

`pac data import` upserts by primary key. If records already exist they are updated; if not they are created. No manual de-duplication is needed for standard config data.

### Import errors

If the import fails with a schema mismatch, re-export from dev (Step 3) to refresh `data_schema.xml`, then retry.

---

## Step 5 — Verify

After import:

```powershell
# Quick check — query the entity to confirm records were created
pac data list --entity-name contact --environment "<target-environment-url>"
```

Or open the target environment in make.powerapps.com and check the relevant table/view.

---

## After Exporting New Data

- Commit `data.xml` and `data_schema.xml` to the feature branch
- The Package Deployer will pick up the data automatically on the next outer-loop deployment (if the solution is in `packageGroups[].dataSolution`)
- If the data needs to reach dev-test before transport, trigger `build-deploy-solution.yml` with `data_solution_name` set to `{mainSolution}`
