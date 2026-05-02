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

### Schema format reference

The schema XML must match this structure exactly. Use `pac tool cmt` (Configuration Migration Tool) to generate it, or hand-craft it using the template below.

**Entity element attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `name` | ✅ | Logical name of the Dataverse table (e.g. `exa_country`) |
| `displayname` | ✅ | Human-readable label |
| `etc` | ✅ | Entity type code — find it in the CMT or Dataverse metadata |
| `primaryidfield` | ✅ | Logical name of the primary key field (e.g. `exa_countryid`) |
| `primarynamefield` | ✅ | Logical name of the primary name field (e.g. `exa_name`) |
| `disableplugins` | ✅ | `false` to let plugins run during import; `true` to suppress them |

**Field element types:**

| `type` value | Used for |
|---|---|
| `string` | Text fields |
| `guid` | Primary key field (`primaryKey="true"`) |
| `datetime` | Date/time fields |
| `number` | Integer fields |
| `bigint` | Version number, large integers |
| `bool` | Boolean (Two Option) fields |
| `state` | `statecode` field |
| `status` | `statuscode` field |
| `entityreference` | Lookup fields — requires `lookupType="{target-entity-name}"` |
| `owner` | `ownerid` field (special lookup — no `lookupType` needed) |

**Cross-entity lookups** — when entity B references entity A, list entity A first in the schema so import order is correct.

### Real-world schema example (two related entities)

```xml
<?xml version="1.0" encoding="utf-8"?>
<entities>

  <!-- Entity 1: Country (no dependencies — listed first) -->
  <entity name="exa_country" displayname="Country" etc="10808"
          primaryidfield="exa_countryid" primarynamefield="exa_name" disableplugins="false">
    <fields>
      <!-- Primary key — type="guid" + primaryKey="true" -->
      <field displayname="Country"              name="exa_countryid"          type="guid"          primaryKey="true" />
      <!-- Custom fields — mark customfield="true" -->
      <field displayname="Name"                 name="exa_name"               type="string"        customfield="true" />
      <field displayname="Abbreviation"         name="exa_abbreviation"       type="string"        customfield="true" />
      <field displayname="Postal Code Required" name="exa_postalcoderequired" type="bool"          customfield="true" />
      <field displayname="State Required"       name="exa_staterequired"      type="bool"          customfield="true" />
      <!-- Standard system fields -->
      <field displayname="Status"               name="statecode"              type="state" />
      <field displayname="Status Reason"        name="statuscode"             type="status" />
      <field displayname="Owner"                name="ownerid"                type="owner" />
      <field displayname="Owning Business Unit" name="owningbusinessunit"     type="entityreference" lookupType="businessunit" />
      <field displayname="Owning User"          name="owninguser"             type="entityreference" lookupType="systemuser" />
      <!-- Audit fields — include in schema, will be omitted in hand-crafted data.xml -->
      <field displayname="Created By"           name="createdby"              type="entityreference" lookupType="systemuser" />
      <field displayname="Created On"           name="createdon"              type="datetime" />
      <field displayname="Modified By"          name="modifiedby"             type="entityreference" lookupType="systemuser" />
      <field displayname="Modified On"          name="modifiedon"             type="datetime" />
    </fields>
    <relationships/>
  </entity>

  <!-- Entity 2: State (depends on Country — listed after) -->
  <entity name="exa_state" displayname="State" etc="10822"
          primaryidfield="exa_stateid" primarynamefield="exa_name" disableplugins="false">
    <fields>
      <field displayname="State"                name="exa_stateid"            type="guid"          primaryKey="true" />
      <field displayname="Name"                 name="exa_name"               type="string"        customfield="true" />
      <field displayname="Abbreviation"         name="exa_abbreviation"       type="string"        customfield="true" />
      <!-- Cross-entity lookup: lookupType must match the entity name above -->
      <field displayname="Country"              name="exa_countryid"          type="entityreference" lookupType="exa_country" customfield="true" />
      <field displayname="Status"               name="statecode"              type="state" />
      <field displayname="Status Reason"        name="statuscode"             type="status" />
      <field displayname="Owner"                name="ownerid"                type="owner" />
      <field displayname="Owning Business Unit" name="owningbusinessunit"     type="entityreference" lookupType="businessunit" />
      <field displayname="Owning User"          name="owninguser"             type="entityreference" lookupType="systemuser" />
      <field displayname="Created By"           name="createdby"              type="entityreference" lookupType="systemuser" />
      <field displayname="Created On"           name="createdon"              type="datetime" />
      <field displayname="Modified By"          name="modifiedby"             type="entityreference" lookupType="systemuser" />
      <field displayname="Modified On"          name="modifiedon"             type="datetime" />
    </fields>
    <relationships/>
  </entity>

</entities>
```

Save as `deployments/data/{mainSolution}/ConfigData.xml`.

> **Finding `etc` (entity type code)**: Open the CMT or check `Settings > Customizations > Developer Resources` in your Dataverse environment. Alternatively, run `pac data export` with the CMT-generated schema — `etc` is in the output schema.

### Using the Configuration Migration Tool (recommended for large or complex schemas)

For schemas with many entities, option sets, or N:N relationships, use the CMT to auto-generate the schema rather than hand-crafting:

```powershell
# Launch the Configuration Migration Tool
pac tool cmt
```

Copy the generated `ConfigData.xml` to `deployments/data/{mainSolution}/`.

---

## Step 3 — Export Data from Dev (or Hand-Craft data.xml)

### Option A — Export from an existing environment (recommended)

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

### Option B — Hand-craft data.xml for seed/test data

When there are no records to export yet (e.g. seeding a fresh environment with reference data), create `data.xml` by hand. The format must exactly match the structure `pac data import` expects:

```xml
<?xml version="1.0" encoding="utf-8"?>
<entities xmlns:xsd="http://www.w3.org/2001/XMLSchema"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          timestamp="2026-01-01T00:00:00.0000000Z">
  <entity name="{prefix}_{entityname}" displayname="{Display Name}">
    <records>
      <record id="{fixed-guid-for-this-record}">
        <field name="{prefix}_{entityname}id" value="{same-fixed-guid}" />
        <field name="{prefix}_name"           value="Record Name" />
        <field name="statecode"               value="0" />
        <field name="statuscode"              value="1" />
      </record>
    </records>
  </entity>
</entities>
```

**Rules for hand-crafted data.xml:**

- **Always include the primary key field** (e.g. `{prefix}_{entityname}id`) with a fixed, deterministic GUID. Use a consistent UUID per record — it is used for upsert matching on re-import.
- **Always include `statecode` and `statuscode`** — `0`/`1` for active records.
- **Lookup fields** require `lookupentity` and optionally `lookupentityname` attributes:
  ```xml
  <field name="ownerid" value="{user-guid}" lookupentity="systemuser" lookupentityname="Display Name" />
  ```
- **Do not include** audit fields (`createdby`, `createdon`, `modifiedby`, `modifiedon`) in hand-crafted files — Dataverse sets these automatically on import and will ignore or error on them.
- **Date fields** use ISO 8601 UTC format: `2026-01-01T00:00:00.0000000Z`.
- **Boolean fields** use string values `"True"` / `"False"` (capital T/F).
- **OptionSet / choice fields** use the integer value of the option as a string: `value="100000000"`.

**Real-world example** (custom `exa_country` entity with lookup and boolean fields):

```xml
<?xml version="1.0" encoding="utf-8"?>
<entities xmlns:xsd="http://www.w3.org/2001/XMLSchema"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          timestamp="2026-01-01T00:00:00.0000000Z">
  <entity name="exa_country" displayname="Country">
    <records>
      <record id="11111111-1111-1111-1111-000000000001">
        <field name="exa_countryid"          value="11111111-1111-1111-1111-000000000001" />
        <field name="exa_name"               value="Afghanistan" />
        <field name="exa_abbreviation"       value="AFG" />
        <field name="exa_postalcoderequired" value="False" />
        <field name="exa_staterequired"      value="False" />
        <field name="statecode"              value="0" />
        <field name="statuscode"             value="1" />
      </record>
    </records>
  </entity>
</entities>
```

> **Do not copy `createdby`, `createdon`, `modifiedby`, `modifiedon`, `ownerid`, `owningbusinessunit`, `owninguser` from exported files into hand-crafted ones** — these system/audit fields are environment-specific and will cause import failures or unexpected ownership assignment.

After hand-crafting `data.xml`, also create a matching `data_schema.xml` (same structure as `ConfigData.xml` but named `data_schema.xml`) — `pac data import` reads the schema from this file. The simplest approach is to copy your `ConfigData.xml` to `data_schema.xml` in the same folder.

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
- If the data needs to reach dev-test before stage, trigger `build-deploy-solution.yml` with `data_solution_name` set to `{mainSolution}`
