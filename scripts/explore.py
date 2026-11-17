#!/usr/bin/env python3
"""Continuous exploration of the specs and the engine.

Each iteration runs one heavy job at `nice -n 10`, in turn:

  sim      `quint run` of random no-error configurations of every spec, and
           of copies of each main configuration with larger bounds.
  traces   fresh random traces of the row spec (`mbt` and a larger copy),
           replayed on the engine by `row_traces_from_folder`.
  mbt      fresh random traces of the `mbt` module of each other spec with a
           replay test (group commit, index rows), replayed on the engine.
  witness  targeted searches: each witness is the negation of an interesting
           state, so the simulator must reach it. Row witness traces are
           replayed on the engine. Recovery and abort witnesses are checked
           in the model only.
  verify   bounded `quint verify` (Apalache) of each main configuration.

The script reads the specs again at each iteration, so a spec or a
configuration that lands on main joins the next iteration. If `harness/`
changes, the script rebuilds the replay binary with `run-in-turso.sh`.

Every line of `explore-out/explore.log` starts with a time. Lines that need
triage start with VIOLATION, DIVERGENCE or ERROR and name the seed and the
trace file. `explore-out/stats.json` holds the totals. Create
`explore-out/STOP` to stop after the current job.

Usage: scripts/explore.py   (run it with nohup; the environment must give
Java 21 on PATH (Apalache needs 21), and SDKROOT on macOS hosts whose default SDK does not link)
"""

import glob
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECS = os.path.join(REPO, "specs")
GEN = os.path.join(SPECS, "explore-gen")
OUT = os.environ.get("EXPLORE_OUT", os.path.join(REPO, "explore-out"))
TURSO = os.environ.get("TURSO", os.path.join(REPO, "harness", "target", "turso"))
QUINT = os.environ.get("QUINT", "quint")
THREADS = os.environ.get("THREADS", "4")
SERVER = os.environ.get("APALACHE_SERVER", "localhost:8851")
JOB_TIMEOUT = int(os.environ.get("JOB_TIMEOUT", "1500"))
NICE = ["nice", "-n", "10"]

ROW_SAFETY = "TypeOK ReadsCorrect RecoveryCorrect BackfillBelowReaders BackfillFloorBelowReaders"

# Each witness is the negation of a state. Row witnesses use the `mbt`
# constants, so their traces replay on the engine.
ROW_WITNESSES = {
    "WStaleBtree": """not(Readers.exists(r => and {
    rd.get(r).pc == "reading", rd.get(r).mark < wal.length(),
    BtreeAt(rd.get(r).key, rd.get(r).mark) != Oracle(rd.get(r).key, rd.get(r).b) }))""",
    "WStaleTwoFrames": """not(Readers.exists(r => and {
    rd.get(r).pc == "reading", rd.get(r).mark + 2 <= wal.length(),
    BtreeAt(rd.get(r).key, rd.get(r).mark) != Oracle(rd.get(r).key, rd.get(r).b) }))""",
    "WBeginAfterPublish": """not(Readers.exists(r => and {
    rd.get(r).pc == "reading", rd.get(r).mark < wal.length(), rd.get(r).b > durable,
    durable > 0, nBackfill > 0, chain.get(rd.get(r).key).size() <= 1 }))""",
    "WTruncateWithLoggedWriter": """not(and {
    ck.pc == "truncated", inflight.exists(i => i.logged), llog != Set() })""",
    "WTruncateEmptiesLogWithPreparing": """not(and {
    Set("truncated", "idle").contains(ck.pc), llog == Set(), logged != Set(), inflight != Set() })""",
    "WCrashMidCheckpoint": """not(and {
    ck.pc == "published", nBackfill < wal.length(), wal.length() >= 2,
    llog.exists(l => l.ts <= durable), llog.exists(l => l.ts > durable) })""",
    "WCrashMidPublish": """not(and {
    ck.pc == "committed", ck.frame > 0, durable < ck.snap,
    llog.exists(l => l.ts <= ck.snap), llog.exists(l => l.ts > ck.snap) })""",
    "WCheckpointRacesCommit": """not(and {
    Set("collect", "writing", "committed").contains(ck.pc),
    inflight.exists(i => i.logged), inflight.exists(i => not(i.logged)) })""",
    "WBackfillHeldByReader": """not(and {
    ck.pc == "idle", nCk >= 2, nBackfill < wal.length(), Pinned != Set(),
    Readers.exists(r => rd.get(r).pc == "reading") })""",
    "WGcUnderStaleReader": """not(Readers.exists(r => and {
    rd.get(r).pc == "reading", rd.get(r).mark < wal.length(), backfillFloor > 0,
    Keys.exists(k => chain.get(k).exists(v => v.mat > rd.get(r).mark)) }))""",
}

# Row witnesses on the `aborts` configuration: model only, the driver has no
# engine rollback of a Preparing writer.
ABORT_WITNESSES = {
    "WRestartAfterRollback": """not(and {
    aborted != Set(), ck.completed, nCk >= 2, llog != Set() })""",
    "WReadAfterRollback": """not(and {
    aborted != Set(), Readers.exists(r => rd.get(r).pc == "reading" and rd.get(r).mark < wal.length()) })""",
}

# Recovery witnesses: model only. They reach an event, and the main
# invariants (RecoveryCorrect covers every open the user can pick, read-only
# included) must hold on the way.
RECOVERY_WITNESSES = {
    "WCommitInPublishWindow": 'not(seen.contains("CommitInPublishWindow"))',
    "WCrashInRecovery": 'not(seen.contains("CrashInRecovery"))',
    "WFailAfterPublishFlagOn": 'not(seen.contains("FailAfterPublishFlagOn"))',
    "WFailAfterPublishBlocking": 'not(seen.contains("FailAfterPublishBlocking"))',
    "WReplayMany": 'not(seen.contains("ReplayMany"))',
    "WLogRetained": 'not(seen.contains("LogRetained"))',
    "WTruncFlagDone": 'not(seen.contains("TruncFlagDone"))',
    "WDownWithWalAfterCrash": 'not(mode == "down" and fs.wal.length() > 0 and cnt.crash >= 1)',
    "WSecondCrash": 'not(cnt.crash >= 2 and mode == "run")',
}


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(msg):
    with open(os.path.join(OUT, "explore.log"), "a") as f:
        f.write(f"{now()} {msg}\n")


def load_stats():
    try:
        with open(os.path.join(OUT, "stats.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"iterations": 0, "started": now(), "specs": {}}


def bump(stats, spec, key, n):
    s = stats["specs"].setdefault(spec, {})
    s[key] = s.get(key, 0) + n


def save_stats(stats):
    with open(os.path.join(OUT, "stats.json"), "w") as f:
        json.dump(stats, f, indent=1, sort_keys=True)


def run(cmd, cwd=SPECS, env=None, timeout=JOB_TIMEOUT):
    """Runs a command at low priority. Returns (exit code or None on timeout, output)."""
    proc = subprocess.Popen(NICE + cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            start_new_session=True, text=True, errors="replace")
    try:
        out, _ = proc.communicate(timeout=timeout)
        return proc.returncode, out
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
        return None, out


def configs(path):
    """(module, expect, invariants) of each module, from the comments above it."""
    expect, invs, res = "", "", []
    for line in open(path):
        m = re.match(r"// Expect (\w+) to fail", line)
        if line.startswith("// Expect "):
            expect = m.group(1) if m else ""
        if line.startswith("// Invariants: "):
            invs = line[len("// Invariants: "):].strip()
        m = re.match(r"module (\w+) \{", line)
        if m:
            res.append((m.group(1), expect, invs))
    return res


def module_text(path, name):
    s = open(path).read()
    i = s.index(f"module {name} {{")
    return s[i:s.index("\n}\n", i) + 3]


def spec_files():
    return sorted(glob.glob(os.path.join(SPECS, "Mvcc*Configs.qnt")))


def spec_name(path):
    return os.path.basename(path)[: -len("Configs.qnt")]


def bigger(text, name, rng):
    """A copy of a module with larger bounds: one more element in each set of
    names or pages, and larger Max* constants."""
    text = text.replace(text.split("{", 1)[0], f"module {name} ", 1)

    def grow_set(m):
        items = re.findall(r'"([^"]*)"|(\d+)', m.group(2))
        strs = [a for a, b in items if a]
        nums = [int(b) for a, b in items if b]
        if strs:
            last = strs[-1]
            d = re.match(r"(.*?)(\d+)$", last)
            new = f'"{d.group(1)}{int(d.group(2)) + 1}"' if d else f'"{chr(ord(last[-1]) + 1)}"'
        elif nums:
            new = str(max(nums) + 1)
        else:
            return m.group(0)
        return f"{m.group(1)}Set({m.group(2)}, {new})"

    text = re.sub(r"(\n\s+(?:Keys|Readers|Txs|Objs|Pages) = )Set\(([^)]+)\)", grow_set, text)

    def grow_max(m):
        key, val = m.group(2), int(m.group(3))
        add = 1 if key in ("MaxCrashes", "MaxFails", "MaxMarkFailures", "MaxVal") else rng.choice([2, 3, 4])
        return f"{m.group(1)}{key} = {val + add}"

    return re.sub(r"(\n\s+)(Max\w+) = (\d+)", grow_max, text)


def write_gen(name, body):
    os.makedirs(GEN, exist_ok=True)
    body = re.sub(r'from "\./', 'from "../', body)
    path = os.path.join(GEN, name + ".qnt")
    with open(path, "w") as f:
        f.write(body)
    return path


def typechecks(path):
    code, out = run([QUINT, "typecheck", path], timeout=300)
    if code != 0:
        log(f"ERROR typecheck {os.path.relpath(path, REPO)}: {out.strip()[-400:]}")
    return code == 0


def quint_run(path, module, invs, seed, samples, steps, itf=None, n_traces=None, mbt=False):
    cmd = [QUINT, "run", path, "--main", module, "--init", "Init", "--step", "Next",
           "--max-samples", str(samples), "--max-steps", str(steps), "--seed", str(seed),
           "--n-threads", THREADS, "--verbosity", "1"]
    if invs:
        cmd += ["--invariants"] + invs.split()
    if mbt:
        cmd.append("--mbt")
    if itf:
        cmd += ["--out-itf", itf]
    if n_traces:
        cmd += ["--n-traces", str(n_traces)]
    code, out = run(cmd)
    if code is None:
        return "timeout", out
    if "[violation]" in out or "Invariant violated" in out:
        return "violation", out
    if "[ok]" in out:
        return "ok", out
    return "error", out


def itf_states(path):
    try:
        return len(json.load(open(path))["states"])
    except (OSError, ValueError, KeyError):
        return 0


# ----------------------------------------------------------------- the harness

def harness_hash():
    h = hashlib.sha256()
    files = sorted(glob.glob(os.path.join(REPO, "harness", "mbt_tests", "**", "*"), recursive=True))
    files += [os.path.join(REPO, "harness", p) for p in ("turso-hooks.patch", "Cargo.toml", "run-in-turso.sh")]
    for p in files:
        if os.path.isfile(p):
            h.update(p.encode())
            h.update(open(p, "rb").read())
    return h.hexdigest()


def replay_binary(stats):
    want = harness_hash()
    if stats.get("harness_hash") != want or not stats.get("binary") or not os.path.exists(stats["binary"]):
        log("build: harness changed, building the replay binary")
        code, out = run([os.path.join(REPO, "harness", "run-in-turso.sh"), TURSO, "--", "--no-run"],
                        cwd=REPO, timeout=3600)
        m = re.findall(r"\((target/debug/deps/turso_core-[0-9a-f]+)\)", out)
        if code != 0 or not m:
            log(f"ERROR build failed: {out.strip()[-800:]}")
            return None
        stats["binary"] = os.path.join(TURSO, m[-1])
        stats["harness_hash"] = want
        save_stats(stats)
        log(f"build: {stats['binary']}")
    return stats["binary"]


REPLAY_TESTS = {
    "MvccPassiveCheckpoint": "mbt_tests::rows::row_traces_from_folder",
    "MvccGroupCommit": "mbt_tests::group::group_traces_from_folder",
    "MvccPassiveIndex": "mbt_tests::index::index_traces_from_folder",
}

# Divergence messages of known harness holes, with the gap that records each.
KNOWN_HOLES = {
    "did not stop in": "MODEL-GAPS 23 (group replay waits for a park, the engine yields)",
}


def replay(stats, folder, label, spec="MvccPassiveCheckpoint"):
    binary = replay_binary(stats)
    if not binary:
        return
    env = dict(os.environ, MBT_TRACES=folder)
    code, out = run([binary, REPLAY_TESTS[spec], "--ignored",
                     "--nocapture", "--test-threads", "1"], cwd=os.path.join(TURSO, "core"),
                    env=env, timeout=JOB_TIMEOUT * 2)
    with open(os.path.join(folder, "replay.log"), "w") as f:
        f.write(out)
    total = len(glob.glob(os.path.join(folder, "*.itf.json")))
    rows = re.findall(r"(\d+) traces: (\d+) replayed, (\d+) refused, (\d+) failed", out)
    group = re.findall(r"(\d+) traces replayed, (\d+) refused", out)
    if rows:
        total, done, refused, failed = map(int, rows[-1])
    elif group:
        done, refused = map(int, group[-1])
        failed = total - done - refused
    elif "panicked at" in out:
        done, refused, failed = 0, 0, 1
    else:
        log(f"ERROR replay {label}: no summary (exit {code}): {out.strip()[-600:]}")
        return
    bump(stats, spec, "replayed_traces", done)
    bump(stats, spec, "refused_traces", refused)
    bump(stats, spec, "diverged_traces", failed)
    states = sum(itf_states(p) for p in glob.glob(os.path.join(folder, "*.itf.json")))
    bump(stats, spec, "replayed_states", states)
    log(f"replay {label}: {total} traces, {states} states: {done} replayed, {refused} refused, {failed} failed")
    for m in re.finditer(r"panicked at [^\n]*\n([^\n]*)", out):
        msg = m.group(1)
        name = msg.split(":", 1)[0].strip()
        src = os.path.join(folder, name)
        keep = os.path.join(OUT, "divergences", f"{label}-{name}")
        if os.path.exists(src):
            os.makedirs(os.path.dirname(keep), exist_ok=True)
            shutil.copy(src, keep)
        hole = next((gap for text, gap in KNOWN_HOLES.items() if text in msg), None)
        if hole:
            log(f"known hole {label}: {msg} [{hole}] output={folder}/replay.log")
        else:
            log(f"DIVERGENCE {label} trace={keep if os.path.exists(keep) else src}: {msg} "
                f"output={folder}/replay.log")
    for m in re.finditer(r"([^\s:]+): refused at step (\d+): ([^\n]*)", out):
        log(f"refused {label} {m.group(1)} step {m.group(2)}: {m.group(3)}")


# ----------------------------------------------------------------------- jobs

def job_sim(stats, rng, it):
    steps = rng.choice([20, 40, 80, 150])
    for path in spec_files():
        spec = spec_name(path)
        mods = [(m, i) for m, e, i in configs(path) if not e and i and m != "mbt"]
        if not mods:
            continue
        picks = [next(x for x in mods if x[0] == "main")] if any(m == "main" for m, _ in mods) else []
        picks += rng.sample(mods, min(2, len(mods)))
        main_invs = dict(mods).get("main")
        if main_invs:
            big = write_gen(f"Big{spec}", bigger(module_text(path, "main"), "big", rng))
            if typechecks(big):
                picks.append(("big", main_invs, big))
        for pick in picks:
            module, invs = pick[0], pick[1]
            file = pick[2] if len(pick) > 2 else path
            seed = rng.randrange(1, 2**31)
            samples = rng.choice([20000, 50000]) if steps <= 40 else rng.choice([5000, 10000])
            itf = os.path.join(OUT, "run", f"sim-{spec}-{module}-{seed}.itf.json")
            t0 = time.time()
            res, out = quint_run(file, module, invs, seed, samples, steps, itf=itf)
            bump(stats, spec, "sim_runs", samples)
            bump(stats, spec, "sim_steps_max", samples * steps)
            line = f"sim {spec}/{module} seed={seed} samples={samples} steps={steps}: {res} {int(time.time() - t0)}s"
            if res == "violation":
                keep = os.path.join(OUT, "violations", os.path.basename(itf))
                os.makedirs(os.path.dirname(keep), exist_ok=True)
                if os.path.exists(itf):
                    shutil.move(itf, keep)
                log(f"VIOLATION {line} trace={keep}")
            elif res in ("error", "timeout"):
                log(f"ERROR {line}: {out.strip()[-400:]}")
            else:
                log(line)
            if os.path.exists(itf):
                os.remove(itf)
            if stop_requested():
                return


def row_traces(stats, rng, label, path, module, count, steps, safety=ROW_SAFETY,
               spec="MvccPassiveCheckpoint", prefix="t"):
    folder = os.path.join(OUT, "run", label)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    made = 0
    while made < count:
        seed = rng.randrange(1, 2**31)
        n = min(300, count - made)
        res, out = quint_run(path, module, safety, seed, n, steps,
                             itf=os.path.join(folder, f"{prefix}{made}-s{seed}_{{seq}}.itf.json"),
                             n_traces=n, mbt=True)
        if res != "ok":
            log(f"{'VIOLATION' if res == 'violation' else 'ERROR'} traces {label} {module} seed={seed}: {res}: {out.strip()[-400:]}")
            if res == "violation":
                keep = os.path.join(OUT, "violations", f"{label}-s{seed}")
                shutil.copytree(folder, keep, dirs_exist_ok=True)
            return None
        made += n
    bump(stats, spec, "generated_traces", made)
    return folder


def job_specs_mbt(stats, rng, it):
    """Fresh traces of the mbt module of every spec other than rows that has
    a replay test, replayed on the engine."""
    for spec, test in REPLAY_TESTS.items():
        path = os.path.join(SPECS, f"{spec}Configs.qnt")
        src = os.path.join(REPO, "harness", "mbt_tests", test.split("::")[1] + ".rs")
        if spec == "MvccPassiveCheckpoint" or not os.path.exists(path) or not os.path.exists(src):
            continue
        invs = dict((m, i) for m, _, i in configs(path)).get("mbt")
        if not invs:
            continue
        steps = rng.choice([30, 60, 100])
        label = f"{spec}-it{it}-steps{steps}"
        folder = row_traces(stats, rng, label, path, "mbt", rng.choice([600, 900]), steps,
                            safety=invs, spec=spec, prefix=f"{spec}-")
        if folder:
            replay(stats, folder, label, spec=spec)
        if stop_requested():
            return


def job_traces(stats, rng, it):
    path = os.path.join(SPECS, "MvccPassiveCheckpointConfigs.qnt")
    steps = rng.choice([40, 80, 150])
    folder = row_traces(stats, rng, f"mbt-it{it}", path, "mbt", rng.choice([900, 1500]), steps)
    if folder:
        replay(stats, folder, f"mbt-it{it}-steps{steps}")
    if stop_requested():
        return
    big = write_gen("BigRowsMbt", bigger(module_text(path, "mbt"), "mbtBig", rng))
    if typechecks(big):
        steps = rng.choice([80, 150, 250])
        folder = row_traces(stats, rng, f"mbtBig-it{it}", big, "mbtBig", 600, steps)
        if folder:
            replay(stats, folder, f"mbtBig-it{it}-steps{steps}")


def witness_file(name, base_path, base_module, witnesses):
    body = module_text(base_path, base_module).replace(f"module {base_module} {{", f"module {name} {{", 1)
    body = body[: body.rindex("}")]
    for w, expr in witnesses.items():
        body += f"  val {w}: bool = {expr}\n"
    return write_gen(name, body + "}\n")


def job_witness(stats, rng, it):
    rows = os.path.join(SPECS, "MvccPassiveCheckpointConfigs.qnt")
    folder = os.path.join(OUT, "run", f"witness-it{it}")
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    groups = [("WitRows", rows, "mbt", ROW_WITNESSES, ROW_SAFETY, folder)]
    if any(m == "aborts" for m, _, _ in configs(rows)):
        invs = dict((m, i) for m, _, i in configs(rows))["aborts"]
        groups.append(("WitAborts", rows, "aborts", ABORT_WITNESSES, invs, None))
    rec = os.path.join(SPECS, "MvccRecoveryConfigs.qnt")
    if os.path.exists(rec):
        invs = dict((m, i) for m, _, i in configs(rec))["main"]
        groups.append(("WitRecovery", rec, "main", RECOVERY_WITNESSES, invs, None))
    steps = rng.choice([40, 60, 100])
    for name, base, module, witnesses, safety, keep_dir in groups:
        path = witness_file(name, base, module, witnesses)
        if not typechecks(path):
            continue
        spec = spec_name(base)
        for w in witnesses:
            for _ in range(rng.choice([3, 5])):
                seed = rng.randrange(1, 2**31)
                itf = os.path.join(keep_dir or os.path.join(OUT, "run"), f"{w}-s{seed}.itf.json")
                res, out = quint_run(path, name, f"{w} {safety}", seed, 20000, steps, itf=itf, mbt=True)
                bump(stats, spec, "witness_runs", 1)
                unsafe = res == "violation" and safety_violated(path, name, safety, seed, steps)
                if unsafe:
                    log(f"VIOLATION witness {name}/{w} seed={seed}: a safety invariant fails, trace={unsafe}")
                elif res == "ok":
                    log(f"witness {name}/{w} seed={seed}: not reached in 20000 runs of {steps} steps")
                elif res != "violation":
                    log(f"ERROR witness {name}/{w} seed={seed}: {res}: {out.strip()[-300:]}")
                if not keep_dir and os.path.exists(itf):
                    os.remove(itf)
            if stop_requested():
                return
        log(f"witness {name}: {len(witnesses)} witnesses done, steps={steps}")
    n = len(glob.glob(os.path.join(folder, "*.itf.json")))
    bump(stats, "MvccPassiveCheckpoint", "witness_traces", n)
    if n:
        replay(stats, folder, f"witness-it{it}")


def safety_violated(path, module, safety, seed, steps):
    """Quint does not name the invariant that a run breaks. So the same seed
    runs again with the safety invariants alone, for the first 2000 samples,
    which cover the run that reached the witness. Returns the trace of a
    safety violation, or None."""
    itf = os.path.join(OUT, "violations", f"{module}-safety-s{seed}.itf.json")
    os.makedirs(os.path.dirname(itf), exist_ok=True)
    res, _ = quint_run(path, module, safety, seed, 2000, steps, itf=itf, mbt=True)
    if res == "violation":
        return itf
    if os.path.exists(itf):
        os.remove(itf)
    return None


def job_verify(stats, rng, it):
    env = dict(os.environ)
    tmp = os.path.join(OUT, "tmp")
    os.makedirs(tmp, exist_ok=True)
    env["JAVA_TOOL_OPTIONS"] = f"-Djava.io.tmpdir={tmp}"
    env["TMPDIR"] = tmp
    for path in spec_files():
        spec = spec_name(path)
        invs = dict((m, i) for m, e, i in configs(path) if not e).get("main")
        if not invs:
            continue
        k = rng.choice([3, 4, 5, 6, 8])
        t0 = time.time()
        code, out = run([QUINT, "verify", path, "--main", "main", "--init", "Init", "--step", "Next",
                         "--invariants"] + invs.split() + ["--max-steps", str(k),
                         "--server-endpoint", SERVER, "--verbosity", "1"], env=env)
        secs = int(time.time() - t0)
        bump(stats, spec, "verify_runs", 1)
        shutil.rmtree(os.path.join(SPECS, "_apalache-out"), ignore_errors=True)
        if code is None:
            log(f"verify {spec}/main max-steps={k}: timeout after {secs}s")
        elif "[ok]" in out:
            bump(stats, spec, "verify_ok_steps", k)
            log(f"verify {spec}/main max-steps={k}: ok {secs}s")
        elif "[violation]" in out or "Invariant violated" in out:
            log(f"VIOLATION verify {spec}/main max-steps={k} {secs}s: {out.strip()[-600:]}")
        else:
            log(f"ERROR verify {spec}/main max-steps={k}: {out.strip()[-400:]}")
        if stop_requested():
            return


def stop_requested():
    return os.path.exists(os.path.join(OUT, "STOP"))


def main():
    os.makedirs(os.path.join(OUT, "run"), exist_ok=True)
    stats = load_stats()
    rng = random.Random(int.from_bytes(os.urandom(8), "little"))
    jobs = [("traces", job_traces), ("sim", job_sim), ("mbt", job_specs_mbt), ("witness", job_witness),
            ("verify", job_verify)]
    log(f"start pid={os.getpid()} repo={REPO} turso={TURSO}")
    while not stop_requested():
        it = stats["iterations"] + 1
        name, job = jobs[(it - 1) % len(jobs)]
        t0 = time.time()
        log(f"iteration {it} {name}: begin")
        try:
            job(stats, rng, it)
        except Exception as e:  # keep the loop alive; the log has the error
            log(f"ERROR iteration {it} {name}: {type(e).__name__}: {e}")
            time.sleep(30)
        stats["iterations"] = it
        save_stats(stats)
        log(f"iteration {it} {name}: end {int(time.time() - t0)}s")
    log("stop: STOP file found")


if __name__ == "__main__":
    sys.exit(main())
