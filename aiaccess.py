#!/usr/bin/env python3
import os
import sys
from pathlib import Path
from pathspec import PathSpec

def load_access(root_dir: Path):
    """
    Parse .aiaccess. Lines starting with '!' are include patterns; others ignore patterns.
    Always ignore all '*.yaml' files anywhere and any '__pycache__/' directories anywhere.
    Directory patterns (ending with '/') match nested contents; bare directory names
    are treated as directories when included.
    Returns:
      ignore_spec: PathSpec for ignore patterns
      include_spec: PathSpec for include patterns
      include_raw: list of raw include patterns (pre-processed)
      has_includes: bool
    """
    file = root_dir / '.aiaccess'
    ignore_lines, include_lines = [], []

    # default global ignores
    ignore_lines.extend(["**/*.yaml", "**/__pycache__/"])

    if file.exists():
        for line in file.read_text(encoding='utf-8').splitlines():
            raw = line.strip()
            if not raw or raw.startswith('#'):
                continue
            if raw.startswith('!'):
                include_lines.append(raw[1:].strip())
            else:
                ignore_lines.append(raw)

    # detect literal conflicts
    conflicts = set(ignore_lines) & set(include_lines)
    if conflicts:
        print(f"Error: conflicting patterns in .aiaccess: {conflicts}")
        sys.exit(1)

    # expand directory ignores
    def expand(lines):
        out = []
        for p in lines:
            if p.endswith('/'):
                out.append(p)
                out.append(p + '**')
            else:
                out.append(p)
        return out

    ignore_patterns = expand(ignore_lines)
    include_patterns = expand(include_lines)

    ignore_spec = PathSpec.from_lines('gitwildmatch', ignore_patterns)
    include_spec = PathSpec.from_lines('gitwildmatch', include_patterns)

    include_raw = include_lines.copy()
    has_includes = bool(include_raw)
    return ignore_spec, include_spec, include_raw, has_includes

def compute_include_dirs(include_raw: list) -> list:
    """
    From raw include patterns, derive a list of directories to preserve.
    For each pattern:
      - If it ends with '/', take that dir.
      - Else if it's a path, take its parent folder.
      - Else ignore (file in root).
    Normalize with trailing '/'.
    """
    include_dirs = set()
    for p in include_raw:
        if p.endswith('/'):
            dirp = p.rstrip('/')
        else:
            parent = Path(p).parent
            if parent == Path('.'):
                continue
            dirp = parent.as_posix()
        if dirp:
            include_dirs.add(dirp.rstrip('/') + '/')
    return sorted(include_dirs)

def is_excluded(path: Path, root_dir: Path,
                ignore_spec: PathSpec, include_spec: PathSpec,
                include_dirs: list, has_includes: bool) -> bool:
    """
    Exclusion logic:
      - root_dir never excluded
      - always drop paths matching ignore_spec
      - when whitelisting:
          * preserve any directory whose path is a prefix of an include_dir
          * drop paths not matching include_spec
    """
    if path == root_dir:
        return False
    try:
        rel = path.relative_to(root_dir)
    except ValueError:
        return False
    rel_posix = rel.as_posix()
    if path.is_dir() and not rel_posix.endswith('/'):
        rel_posix += '/'

    # global ignores
    if ignore_spec.match_file(rel_posix):
        return True

    if has_includes:
        # preserve parent dirs of included patterns
        for idir in include_dirs:
            if rel_posix == idir or idir.startswith(rel_posix):
                return False
        # drop non-whitelisted
        if not include_spec.match_file(rel_posix):
            return True
    return False

def generate_tree_structure(root_dir: Path,
                            ignore_spec: PathSpec, include_spec: PathSpec,
                            include_dirs: list, has_includes: bool) -> str:
    tree = ""
    for root, dirs, files in os.walk(root_dir):
        current = Path(root)
        if is_excluded(current, root_dir,
                       ignore_spec, include_spec,
                       include_dirs, has_includes):
            continue
        dirs[:] = [d for d in dirs
                   if not is_excluded(current / d, root_dir,
                                      ignore_spec, include_spec,
                                      include_dirs, has_includes)]
        files = [f for f in files
                 if not is_excluded(current / f, root_dir,
                                    ignore_spec, include_spec,
                                    include_dirs, has_includes)]
        rel = current.relative_to(root_dir)
        indent = '  ' * len(rel.parts)
        tree += f"{indent}- {current.name}/\n"
        subindent = '  ' * (len(rel.parts) + 1)
        for f in sorted(files):
            tree += f"{subindent}- {f}\n"
    return tree

def write_file_contents_markdown(root_dir: Path,
                                 ignore_spec: PathSpec, include_spec: PathSpec,
                                 include_dirs: list, has_includes: bool) -> str:
    md = ""
    for root, dirs, files in os.walk(root_dir):
        current = Path(root)
        dirs[:] = [d for d in dirs
                   if not is_excluded(current / d, root_dir,
                                      ignore_spec, include_spec,
                                      include_dirs, has_includes)]
        if is_excluded(current, root_dir,
                       ignore_spec, include_spec,
                       include_dirs, has_includes):
            continue
        for filename in sorted(files):
            file_path = current / filename
            if is_excluded(file_path, root_dir,
                           ignore_spec, include_spec,
                           include_dirs, has_includes):
                continue
            rel_path = file_path.relative_to(root_dir).as_posix()
            ext = file_path.suffix.lstrip('.') or 'txt'
            md += f"\n### `{rel_path}`\n```{ext}\n"
            try:
                md += file_path.read_text(encoding='utf-8')
            except Exception as e:
                md += f"# could not read file: {e}\n"
            md += "\n```\n"
    return md

def main():
    script_path = Path(__file__).resolve()
    root_dir = script_path.parent

    ignore_spec, include_spec, include_raw, has_includes = load_access(root_dir)
    include_dirs = compute_include_dirs(include_raw) if has_includes else []

    output = root_dir / f"{root_dir.name}.md"
    with open(output, 'w', encoding='utf-8') as out:
        out.write("# Folder Structure\n\n")
        out.write(generate_tree_structure(root_dir,
                                          ignore_spec, include_spec,
                                          include_dirs, has_includes))
        out.write("\n# File Contents\n")
        out.write(write_file_contents_markdown(root_dir,
                                              ignore_spec, include_spec,
                                              include_dirs, has_includes))

    print(f"Markdown file created: {output.name}")

if __name__ == '__main__':
    main()
