#!/usr/bin/env python3
import json, os, sys

body = os.environ.get("CHANGELOG", "")
tag = os.environ.get("TAG", "")
sha = os.environ.get("COMMIT_SHA", "")
version = os.environ.get("VERSION", "")

if not body:
    body = "Automated release for version " + version + "."

json.dump({
    "tag_name": tag,
    "target_commitish": sha,
    "name": "mere " + version,
    "body": body,
    "draft": False,
    "prerelease": False,
}, sys.stdout)
