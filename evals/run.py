"""Run the KB eval set against a git ref of this repo and print the pass rate.

python evals/run.py [--ref HEAD] [--only id1,id2] [--jobs 4] [--model ...]

Each case is answered by `claude -p` inside a `git archive` of the ref, with only Read/Grep/Glob
and no MCP servers, so it measures what the KB itself makes Claude say. The harness, not the
model, runs SQL in BigQuery. Full results go to C:\\dev\\cz_outputs\\reports\\evals (never the repo).
"""
import argparse, concurrent.futures as cf, csv, datetime as dt, io, json, os, re, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cases import CASES, EVAL_VERSION

REPO = Path(__file__).resolve().parents[1]
OUT = Path(r"C:\dev\cz_outputs\reports\evals")
FLAGS = re.I | re.S
PROMPT = """You are answering a Cafe Zupas data question using only the knowledge base in the current \
directory (README.md, decisions/DECISIONS.md, claude_skills/, data_dictionaries/). It is already a \
fresh copy of main: do not clone or fetch anything. Start from README.md and follow its routing.
You have no database access and must not ask clarifying questions: state your assumptions and any \
scope choices explicitly, then answer.
If the question asks for data, write the BigQuery SQL that answers it, with tables qualified by \
project marketing-data-442316, and end with exactly one ```sql block that returns exactly the \
columns asked for, in that order.

Question: """


def sh(args, **kw):
    kw.setdefault("input", "")  # bq waits on an open stdin
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8", **kw)


def bq(sql, max_bytes):
    # SQL goes on stdin: bq.cmd runs through cmd.exe, which mangles quotes and > in arguments
    r = sh([shutil.which("bq"), "query", "--quiet", "--use_legacy_sql=false", "--format=csv", "--max_rows=100000",
            f"--maximum_bytes_billed={max_bytes}", f"--label=kb_eval:v{EVAL_VERSION}"], input=sql)
    if r.returncode:
        raise RuntimeError((r.stdout + r.stderr).strip()[-500:])
    return list(csv.reader(io.StringIO(r.stdout)))[1:]


def as_map(rows):
    """First column = key, last column = value; a single cell has key ''."""
    out = {}
    for vals in rows:
        key = "" if len(vals) == 1 else vals[0].strip().lower()
        out[key] = float(vals[-1]) if vals[-1] not in ("", "NULL") else None
    return out


def close(a, b, tol):
    if a is None or b is None:
        return a is b
    return abs(a - b) <= max(tol * abs(b), 0.5)


def grade(case, text, max_bytes):
    fails = []
    for p in case.get("must", []):
        if not re.search(p, text, FLAGS):
            fails.append(f"missing /{p}/")
    for p in case.get("must_not", []):
        if re.search(p, text, FLAGS):
            fails.append(f"forbidden /{p}/")
    if case["type"] != "sql":
        return fails, None
    blocks = re.findall(r"```sql\s*(.*?)```", text, FLAGS)
    if not blocks:
        return fails + ["no ```sql block"], None
    sql = blocks[-1].strip().rstrip(";")
    for p in case.get("sql_must", []):
        if not re.search(p, sql, FLAGS):
            fails.append(f"sql missing /{p}/")
    for p in case.get("sql_must_not", []):
        if re.search(p, sql, FLAGS):
            fails.append(f"sql forbidden /{p}/")
    try:
        got = as_map(bq(sql, max_bytes))
    except Exception as e:
        return fails + [f"sql error: {e}"], {"sql": sql}
    want = as_map(bq(case["reference_sql"], max_bytes))
    tol = case.get("tolerance", 0.005)
    if set(got) != set(want):
        fails.append(f"keys differ: extra {sorted(set(got) - set(want))[:5]} missing {sorted(set(want) - set(got))[:5]}")
    bad = [k for k in want if k in got and not close(got[k], want[k], tol)]
    if bad:
        fails.append(f"values off for {bad[:5]}")
    return fails, {"sql": sql, "got": got, "want": want}


def run_case(case, kb, args):
    cmd = [shutil.which("claude"), "-p", "--output-format", "json", "--allowedTools", "Read,Grep,Glob",
           "--strict-mcp-config", "--setting-sources", "user"]
    if args.model:
        cmd += ["--model", args.model]
    # drop CLAUDE*/ANTHROPIC* vars so a run launched from inside a Claude session uses the CLI's own login
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("CLAUDE", "ANTHROPIC"))}
    r = sh(cmd, input=PROMPT + case["question"], cwd=kb, timeout=900, env=env)
    try:
        out = json.loads(r.stdout)
        assert not out.get("is_error")
        text = out["result"]
    except Exception:
        return {"id": case["id"], "pass": False, "error": (r.stdout + r.stderr)[-300:], "fails": ["harness error"]}
    fails, detail = grade(case, text, args.max_bytes)
    return {"id": case["id"], "skill": case["skill"], "source": case["source"], "pass": not fails,
            "fails": fails, "answer": text, **(detail or {})}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--model", default="")
    ap.add_argument("--max-bytes", type=int, default=20 * 1024**3)
    ap.add_argument("--selftest", action="store_true", help="grade each sql case's reference as its answer, and a skewed copy that must fail")
    args = ap.parse_args()

    if args.selftest:
        for c in (c for c in CASES if c["type"] == "sql"):
            ok, _ = grade(c, f"```sql\n{c['reference_sql']}\n```", args.max_bytes)
            skew = re.sub(r"^select (.*?)(,\s*)?(sum|count|countif)\(", r"select \1\2 1.1 * \3(", c["reference_sql"], count=1)
            bad, _ = grade(c, f"```sql\n{skew}\n```", args.max_bytes)
            print(f"{c['id']}: reference {'ok' if not ok else ok}; skewed {'caught' if bad else 'NOT CAUGHT'}")
        return

    sha = sh(["git", "-C", str(REPO), "rev-parse", "--short", args.ref]).stdout.strip()
    if not sha:
        sys.exit(f"unknown ref {args.ref}")
    only = {s for s in args.only.split(",") if s}
    cases = [c for c in CASES if not only or c["id"] in only]

    with tempfile.TemporaryDirectory(prefix="kb_eval_") as kb:
        tar = subprocess.run(["git", "-C", str(REPO), "archive", "--format=tar", sha], capture_output=True, check=True).stdout
        tarfile.open(fileobj=io.BytesIO(tar)).extractall(kb, filter="data")
        with cf.ThreadPoolExecutor(args.jobs) as ex:
            results = list(ex.map(lambda c: run_case(c, kb, args), cases))

    errors = [r for r in results if "error" in r]
    if errors:
        sys.exit(f"{len(errors)} harness errors, nothing recorded. First: {errors[0]['error']}")
    passed = sum(r["pass"] for r in results)
    line = f"eval v{EVAL_VERSION} @ {sha}: {passed}/{len(results)} pass ({passed / len(results):.1%})"
    print(line)
    for r in results:
        if not r["pass"]:
            print(f"  FAIL {r['id']}: {'; '.join(r['fails'])}")

    OUT.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M")
    (OUT / f"{stamp}_v{EVAL_VERSION}_{sha}.json").write_text(json.dumps(results, indent=1), encoding="utf-8")
    if not only:
        failed = ", ".join(r["id"] for r in results if not r["pass"]) or "none"
        with open(REPO / "evals" / "RESULTS.md", "a", encoding="utf-8") as f:
            f.write(f"| {dt.date.today()} | v{EVAL_VERSION} | {sha} | {args.model or 'default'} | {passed}/{len(results)} ({passed / len(results):.1%}) | {failed} |\n")


if __name__ == "__main__":
    main()
