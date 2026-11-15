"""Stable, counted fingerprints: line moves cannot hide new diagnostics."""
import hashlib
import json
from collections import Counter
from pathlib import Path


def findings(document, root):
    counts = Counter()
    locations = {}
    for result in document["results"]:
        path = Path(result["filePath"]).resolve()
        relative = path.relative_to(root.resolve()).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for message in result["messages"]:
            if message.get("fatal") or message["severity"] == 2:
                raise ValueError(f"{relative}: fatal/error diagnostic: {message['message']}")
            line = message["line"]
            end = message["endLine"]
            if not 1 <= line <= end <= len(lines):
                raise ValueError(f"{relative}: invalid diagnostic range")
            content = "\n".join(text.strip() for text in lines[line - 1:end])
            fingerprint = hashlib.sha256((message["message"] + "\n" + content).encode()).hexdigest()
            key = (relative, message["ruleId"], fingerprint)
            counts[key] += 1
            locations[key] = f"{relative}:{line}:{message['column']}: {message['ruleId']}: {message['message']}"
    return counts, locations


def compare(current, previous):
    return current - previous, previous - current


def save(path, counts):
    entries = [dict(path=p, rule=r, fingerprint=f, count=count)
               for (p, r, f), count in sorted(counts.items())]
    # One entry per line makes reviewed removals and increases visible.
    body = ',\n'.join('    ' + json.dumps(entry, sort_keys=True) for entry in entries)
    path.write_text('{"version": 1, "findings": [\n' + body + '\n]}\n', encoding="utf-8")


def load(path):
    document = json.loads(path.read_text(encoding="utf-8"))
    if document["version"] != 1:
        raise ValueError("unsupported baseline version")
    counts = Counter()
    for entry in document["findings"]:
        key = entry["path"], entry["rule"], entry["fingerprint"]
        if key in counts or type(entry["count"]) is not int or entry["count"] <= 0:
            raise ValueError("invalid or duplicate baseline entry")
        counts[key] = entry["count"]
    return counts
