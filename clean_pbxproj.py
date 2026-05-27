#!/usr/bin/env python3
"""Remove stale PBXFileReference and PBXBuildFile entries for files we deleted.

The project uses PBXFileSystemSynchronizedRootGroup so all live files
auto-discover. The explicit references for the old code path
(Core/, Models/, Services/, Views/, LLMLibrary/, Appstate.swift,
ContentView.swift, Swift_Deep_ResearchApp.swift) are dead weight that
break the build with "missing input file" errors.

Strategy:
1. Find every PBXFileReference whose `path` matches a deleted file's
   subtree. Collect its ID.
2. Find every PBXBuildFile whose `fileRef` is one of those IDs.
   Collect its ID.
3. Remove all matching lines.
4. Remove any references to the collected build-file IDs from
   PBXSourcesBuildPhase `files = (...)` lists.
"""
import re
import sys
import pathlib

PROJ = pathlib.Path(__file__).parent / "Swift Deep Research.xcodeproj" / "project.pbxproj"

DEAD_PATH_PREFIXES = (
    "Swift Deep Research/Core/",
    "Swift Deep Research/Models/",
    "Swift Deep Research/Services/",
    "Swift Deep Research/Views/",
    "Swift Deep Research/LLMLibrary/",
)
DEAD_PATH_EQ = {
    "Swift Deep Research/Appstate.swift",
    "Swift Deep Research/ContentView.swift",
    "Swift Deep Research/Swift_Deep_ResearchApp.swift",
}

text = PROJ.read_text()

# Step 1: find dead PBXFileReference lines.
fileref_pattern = re.compile(
    r'(?m)^\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{isa = PBXFileReference;[^}]*path = "([^"]+)"[^}]*\};$'
)
dead_filerefs = set()
for m in fileref_pattern.finditer(text):
    file_id, path = m.group(1), m.group(2)
    if path in DEAD_PATH_EQ or any(path.startswith(p) for p in DEAD_PATH_PREFIXES):
        dead_filerefs.add(file_id)

print(f"Dead PBXFileReference IDs: {len(dead_filerefs)}")

# Step 2: find PBXBuildFile entries whose fileRef matches.
buildfile_pattern = re.compile(
    r'(?m)^\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})[^}]*\};$'
)
dead_buildfiles = set()
for m in buildfile_pattern.finditer(text):
    bf_id, ref_id = m.group(1), m.group(2)
    if ref_id in dead_filerefs:
        dead_buildfiles.add(bf_id)

print(f"Dead PBXBuildFile IDs:   {len(dead_buildfiles)}")

# Step 3: remove dead PBXFileReference lines.
def line_kills_ref(line: str) -> bool:
    for fid in dead_filerefs:
        if line.startswith(f"\t\t{fid} /*") and "PBXFileReference" in line:
            return True
    return False

def line_kills_buildfile(line: str) -> bool:
    for bf in dead_buildfiles:
        if line.startswith(f"\t\t{bf} /*") and "PBXBuildFile" in line:
            return True
    return False

# Step 4: remove references from Sources files = (...) lists.
def line_is_dead_source_member(line: str) -> bool:
    for bf in dead_buildfiles:
        if f"\t\t\t\t{bf} /*" in line and " in Sources */" in line:
            return True
    return False

new_lines = []
for line in text.splitlines(keepends=True):
    if line_kills_ref(line):       continue
    if line_kills_buildfile(line): continue
    if line_is_dead_source_member(line): continue
    new_lines.append(line)

new_text = "".join(new_lines)
if new_text == text:
    print("No change.")
    sys.exit(0)

PROJ.write_text(new_text)
print(f"Wrote {PROJ}")
print(f"  size: {len(text)} -> {len(new_text)} bytes")
