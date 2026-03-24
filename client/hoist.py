import re

with open("client/public/src/admin.js", "r") as f:
    code = f.read()

pattern = re.compile(r"^\s*(?:const|let)\s+([a-zA-Z0-9_]+)\s*=\s*document\.getElementById\(([\"\'\\][a-zA-Z0-9_\-]+[\"\'\\])\);\s*$", re.MULTILINE)

declarations = []
seen = set()

def replacer(match):
    var_name = match.group(1)
    id_str = match.group(2)
    if var_name not in seen:
        seen.add(var_name)
        declarations.append(f"const {var_name} = document.getElementById({id_str});")
    return ""

new_code = pattern.sub(replacer, code)

lines = new_code.split("\n")
insert_idx = 10
for i, line in enumerate(lines):
    if "networkClient.isAdmin = true" in line:
        insert_idx = i + 2
        break

lines.insert(insert_idx, "\n// --- DOM Elements ---")
for decl in reversed(declarations):
    lines.insert(insert_idx + 1, decl)

with open("client/public/src/admin.js", "w") as f:
    f.write("\n".join(lines))

print(f"Hoisted {len(declarations)} DOM elements successfully.")
