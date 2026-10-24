#!/usr/bin/env python3
"""Prints a model catalog revision entry for Hugging Face repositories at pinned commits.

It reads only metadata (the commits and tree APIs): for every file an artifact's include patterns
select, its path, size, and digest (SHA-256 for LFS files, the git blob ID for small ones). No
weights are downloaded. Paste the output into a variant's "revisions" (docs/models.md, "How to add
a model").

  # One artifact: an MLX language model at the current head of main.
  python3 -I scripts/model-revision.py \
      --artifact model mlx-community/gemma-4-12B-it-4bit main '*.safetensors' '*.json' '*.jinja'

  # Two artifacts, as WhisperKit needs: the Core ML folder (its root) and a tokenizer.
  python3 -I scripts/model-revision.py \
      --artifact model argmaxinc/whisperkit-coreml 0f63a7800b00dd0226abd051b906c246e1907482 'openai_whisper-base/*' \
      --root model openai_whisper-base \
      --artifact tokenizer openai/whisper-base main tokenizer.json tokenizer_config.json config.json \
          special_tokens_map.json added_tokens.json

Patterns use fnmatch, where "*" also matches "/", like Hugging Face's own matching.
"""
import argparse
import fnmatch
import json
import re
import sys
import urllib.parse
import urllib.request

API = "https://huggingface.co/api/models"


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "daybook-model-revision/1", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response), response.headers.get("Link")


def commit(repository, reference):
    commits, _ = get(f"{API}/{repository}/commits/{urllib.parse.quote(reference, safe='')}")
    return commits[0]


def tree(repository, revision):
    url = f"{API}/{repository}/tree/{revision}?recursive=true"
    entries = []
    while url:
        page, link = get(url)
        entries += page
        match = re.search(r'<([^>]+)>;\s*rel="next"', link or "")
        url = match.group(1) if match else None
    return [entry for entry in entries if entry.get("type") == "file"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--artifact", nargs="+", action="append", required=True,
                        metavar=("NAME REPOSITORY REFERENCE", "PATTERN"),
                        help="artifact name, repository, branch or commit, then include patterns")
    parser.add_argument("--root", nargs=2, action="append", default=[], metavar=("NAME", "FOLDER"),
                        help="the folder inside the repository an engine loads the artifact from")
    parser.add_argument("--id", help="revision ID (default: the first artifact's commit)")
    arguments = parser.parse_args()
    roots = dict(arguments.root)

    artifacts, commits = [], []
    for spec in arguments.artifact:
        if len(spec) < 4:
            parser.error("--artifact needs a name, a repository, a reference, and at least one pattern")
        name, repository, reference, patterns = spec[0], spec[1], spec[2], spec[3:]
        head = commit(repository, reference)
        commits.append(head)
        files = []
        for entry in sorted(tree(repository, head["id"]), key=lambda item: item["path"]):
            if not any(fnmatch.fnmatchcase(entry["path"], pattern) for pattern in patterns):
                continue
            item = {"path": entry["path"], "size": entry["size"]}
            if "lfs" in entry:
                item["sha256"] = entry["lfs"]["oid"]
            else:
                item["gitOID"] = entry["oid"]
            files.append(item)
        if not files:
            sys.exit(f"No files in {repository} at {head['id']} match {patterns}.")
        artifact = {"name": name, "repository": repository, "revision": head["id"], "include": patterns}
        if name in roots:
            artifact["root"] = roots[name]
        artifact["files"] = files
        artifacts.append(artifact)

    newest = max(commits, key=lambda item: item["date"])
    revision = {"id": arguments.id or artifacts[0]["revision"], "releaseDate": newest["date"][:10],
                "summary": newest["title"], "artifacts": artifacts}
    json.dump(revision, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
