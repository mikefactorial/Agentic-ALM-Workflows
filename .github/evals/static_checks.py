"""
Static checks for Power Platform ALM plugin skill files.

Checks:
  CAT-1  Frontmatter validity (YAML parses, required fields present)
  CAT-2  'name' field matches directory name
  CAT-3  'description' contains 'Use when'
  CAT-4  'description' length <= 1024 characters
  CAT-5  Frontmatter token budget <= 200 tokens (approx: chars/4)
  CAT-6  Body token budget <= 5000 tokens (approx: chars/4)
  CAT-7  'Skill boundaries' section present in every skill except alm-overview
  CAT-8  Cross-references in Skill boundaries point to real skills
  CAT-9  alm-overview Skill Index lists every skill (including itself)
  CAT-10 Version consistency across all 4 manifest files

Exit 0 = all checks pass. Non-zero = at least one failure.
"""

import os
import re
import sys
import json

SKILLS_DIR = os.path.join(
    os.path.dirname(__file__),
    "..", "plugins", "power-platform-alm", "skills"
)
PLUGIN_ROOT = os.path.join(
    os.path.dirname(__file__),
    "..", "plugins", "power-platform-alm"
)
REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")

# Skills that are exempt from the 'Skill boundaries' requirement
OVERVIEW_SKILLS = {"alm-overview"}

# The 4 version fields live in 3 files:
#   1. plugin/.claude-plugin/plugin.json            → "version"
#   2. plugin/.github/plugin/plugin.json            → "version"
#   3. .github/plugin/marketplace.json              → "metadata.version"
#   4. .github/plugin/marketplace.json              → "plugins[0].version"
# The root .claude-plugin/marketplace.json is a pointer with no version field.
VERSION_SOURCES = [
    (os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json"), "version"),
    (os.path.join(PLUGIN_ROOT, ".github", "plugin", "plugin.json"), "version"),
    (os.path.join(REPO_ROOT, ".github", "plugin", "marketplace.json"), "metadata.version"),
    (os.path.join(REPO_ROOT, ".github", "plugin", "marketplace.json"), "plugins[0].version"),
]

TOKENS_PER_CHAR = 0.25  # approximation: 1 token ≈ 4 chars


def approx_tokens(text):
    return len(text) * TOKENS_PER_CHAR


def find_skills():
    """Return a dict of {skill_name: skill_md_path} for every skill directory."""
    skills = {}
    if not os.path.isdir(SKILLS_DIR):
        return skills
    for entry in sorted(os.listdir(SKILLS_DIR)):
        skill_path = os.path.join(SKILLS_DIR, entry)
        if os.path.isdir(skill_path):
            skill_md = os.path.join(skill_path, "SKILL.md")
            if os.path.isfile(skill_md):
                skills[entry] = skill_md
    return skills


def parse_frontmatter(content):
    """
    Extract YAML frontmatter from a SKILL.md file.
    Returns (frontmatter_text, body_text) or raises ValueError.
    """
    if not content.startswith("---"):
        raise ValueError("File does not start with '---'")
    end = content.find("\n---", 3)
    if end == -1:
        raise ValueError("Closing '---' not found")
    fm_text = content[3:end].strip()
    body_text = content[end + 4:].strip()
    return fm_text, body_text


def parse_yaml_simple(text):
    """
    Minimal YAML key: value parser (single-level only).
    Supports quoted and unquoted string values.
    """
    result = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        # Strip surrounding quotes
        if (val.startswith("'") and val.endswith("'")) or \
           (val.startswith('"') and val.endswith('"')):
            val = val[1:-1]
        result[key] = val
    return result


def read_version_from_manifest(path, field_path):
    """
    Extract a version value from a JSON file using a dotted field path.
    Supported paths: "version", "metadata.version", "plugins[0].version"
    """
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        return None, str(e)

    try:
        if field_path == "version":
            return data["version"], None
        if field_path == "metadata.version":
            return data["metadata"]["version"], None
        if field_path == "plugins[0].version":
            return data["plugins"][0]["version"], None
    except (KeyError, IndexError, TypeError):
        pass

    return None, f"field '{field_path}' not found"


def check_skill(skill_name, skill_md_path, all_skill_names, errors):
    """Run all per-skill checks. Append error strings to errors list."""
    with open(skill_md_path, encoding="utf-8") as f:
        content = f.read()

    # --- Parse frontmatter ---
    try:
        fm_text, body_text = parse_frontmatter(content)
    except ValueError as e:
        errors.append(f"[CAT-1] {skill_name}: {e}")
        return

    try:
        fm = parse_yaml_simple(fm_text)
    except Exception as e:
        errors.append(f"[CAT-1] {skill_name}: YAML parse error: {e}")
        return

    # CAT-1: required fields
    for field in ("name", "description"):
        if field not in fm:
            errors.append(f"[CAT-1] {skill_name}: missing frontmatter field '{field}'")

    if "name" not in fm or "description" not in fm:
        return  # can't run further checks without both fields

    # CAT-2: name matches directory
    if fm["name"] != skill_name:
        errors.append(
            f"[CAT-2] {skill_name}: frontmatter 'name' is '{fm['name']}', "
            f"expected '{skill_name}'"
        )

    # CAT-3: description contains 'Use when'
    if "use when" not in fm["description"].lower():
        errors.append(
            f"[CAT-3] {skill_name}: description missing 'Use when' routing clause"
        )

    # CAT-4: description <= 1024 chars
    if len(fm["description"]) > 1024:
        errors.append(
            f"[CAT-4] {skill_name}: description is {len(fm['description'])} chars "
            f"(limit 1024)"
        )

    # CAT-5: frontmatter token budget
    fm_tokens = approx_tokens(fm_text)
    if fm_tokens > 200:
        errors.append(
            f"[CAT-5] {skill_name}: frontmatter ~{fm_tokens:.0f} tokens "
            f"(limit 200)"
        )

    # CAT-6: body token budget
    body_tokens = approx_tokens(body_text)
    if body_tokens > 5000:
        errors.append(
            f"[CAT-6] {skill_name}: body ~{body_tokens:.0f} tokens (limit 5000)"
        )

    # CAT-7: Skill boundaries section (exempt: alm-overview)
    if skill_name not in OVERVIEW_SKILLS:
        if "## skill boundaries" not in body_text.lower():
            errors.append(
                f"[CAT-7] {skill_name}: missing '## Skill boundaries' section"
            )
        else:
            # CAT-8: cross-references point to real skills
            # Find all backtick-quoted names in the Skill boundaries section
            boundaries_match = re.search(
                r"## skill boundaries.*?(?=^## |\Z)",
                body_text,
                re.IGNORECASE | re.DOTALL | re.MULTILINE,
            )
            if boundaries_match:
                referenced = re.findall(r"`([a-z][a-z0-9-]+)`", boundaries_match.group())
                for ref in referenced:
                    if ref not in all_skill_names:
                        errors.append(
                            f"[CAT-8] {skill_name}: Skill boundaries references "
                            f"unknown skill '{ref}'"
                        )


def check_overview(skill_md_path, all_skill_names, errors):
    """CAT-9: alm-overview Skill Index must list every skill."""
    with open(skill_md_path, encoding="utf-8") as f:
        content = f.read()

    for skill_name in all_skill_names:
        if f"`{skill_name}`" not in content:
            errors.append(
                f"[CAT-9] alm-overview: Skill Index missing entry for '{skill_name}'"
            )


def check_versions(errors):
    """CAT-10: all 4 version fields across 3 manifest files must match."""
    versions = {}
    for path, field_path in VERSION_SOURCES:
        label = f"{os.path.relpath(path, REPO_ROOT)}[{field_path}]"
        if not os.path.isfile(path):
            errors.append(f"[CAT-10] manifest file missing: {os.path.relpath(path, REPO_ROOT)}")
            continue
        version, err = read_version_from_manifest(path, field_path)
        if err:
            errors.append(f"[CAT-10] {label}: could not read version — {err}")
        else:
            versions[label] = version

    unique = set(versions.values())
    if len(unique) > 1:
        detail = ", ".join(f"{k}={v}" for k, v in sorted(versions.items()))
        errors.append(
            f"[CAT-10] version mismatch across manifests: {detail}"
        )


def main():
    skills = find_skills()
    if not skills:
        print(f"ERROR: no skills found under {SKILLS_DIR}", file=sys.stderr)
        sys.exit(1)

    all_skill_names = set(skills.keys())
    errors = []

    for skill_name, skill_md_path in skills.items():
        check_skill(skill_name, skill_md_path, all_skill_names, errors)

    # CAT-9: overview completeness
    if "alm-overview" in skills:
        check_overview(skills["alm-overview"], all_skill_names, errors)
    else:
        errors.append("[CAT-9] alm-overview/SKILL.md not found")

    # CAT-10: version consistency
    check_versions(errors)

    if errors:
        print(f"FAIL — {len(errors)} error(s):\n")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    else:
        skill_count = len(skills)
        print(f"PASS — {skill_count} skill(s) checked, all checks passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
