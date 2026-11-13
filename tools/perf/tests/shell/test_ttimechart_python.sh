#!/bin/bash
# perf timechart --tui (ttimechart.py) test
# SPDX-License-Identifier: GPL-2.0

set -e

shelldir=$(dirname "$0")
# shellcheck source=lib/setup_python.sh
. "${shelldir}"/lib/setup_python.sh

if ! perf check feature -q libtraceevent; then
	echo "Skipping test, libtraceevent is disabled"
	exit 2
fi

if ! "$PYTHON" -c 'import perf' > /dev/null 2>&1; then
	echo "Skipping test, perf python module not found"
	exit 2
fi

if ! "$PYTHON" -c 'import textual' > /dev/null 2>&1; then
	echo "Skipping test, python textual library not found"
	exit 2
fi

err=0
system_wide=0
perfdata=
output=
clockdata=

cleanup() {
	[ -n "${perfdata}" ] && rm -f "${perfdata}"*
	[ -n "${clockdata}" ] && rm -f "${clockdata}"*
	rm -f "${output}"
	trap - EXIT TERM INT
}

trap_cleanup() {
	echo "Unexpected signal in ${FUNCNAME[1]}"
	cleanup
	exit 1
}
trap trap_cleanup EXIT TERM INT

perfdata=$(mktemp /tmp/__perf_ttimechart_test.perf.data.XXXXX)
output=$(mktemp /tmp/__perf_ttimechart_test.output.XXXXX)
clockdata=$(mktemp /tmp/__perf_ttimechart_test.clock.data.XXXXX)

workload() {
	for _ in 1 2 3 4 5; do
		sleep 0.01
	done
}

record() {
	# perf timechart record is system wide and so may need privileges,
	# fall back to recording just the workload's scheduler events.
	if perf timechart record -o "${perfdata}" -- \
		bash -c "$(declare -f workload); workload" > /dev/null 2>&1; then
		system_wide=1
		return 0
	fi
	if perf record -R -c 1 -e sched:sched_switch -e sched:sched_wakeup \
		-o "${perfdata}" -- bash -c "$(declare -f workload); workload" \
		> /dev/null 2>&1; then
		return 0
	fi
	return 1
}

test_plumbing() {
	echo "perf timechart --tui plumbing test"
	# A missing input file should be reported by the script launched
	# through perf script, this doesn't need a terminal.
	if perf timechart --tui -i "${perfdata}.missing" > "${output}" 2>&1; then
		echo "perf timechart --tui plumbing test [Failed: missing file not an error]"
		err=1
		return
	fi
	if ! grep -q "not found" "${output}"; then
		echo "perf timechart --tui plumbing test [Failed: script not launched]"
		cat "${output}"
		err=1
		return
	fi
	if perf timechart --live -i "${perfdata}" > "${output}" 2>&1 ||
	   ! grep -q -- "--live can't be used with -i" "${output}"; then
		echo "perf timechart --tui plumbing test [Failed: --live with -i not rejected]"
		cat "${output}"
		err=1
		return
	fi
	if perf timechart --live --window 0 < /dev/null > "${output}" 2>&1 ||
	   ! grep -q -- "--window must be a positive" "${output}"; then
		echo "perf timechart --tui plumbing test [Failed: --window 0 not rejected]"
		cat "${output}"
		err=1
		return
	fi
	if perf timechart --tui --window 5 < /dev/null > "${output}" 2>&1 ||
	   ! grep -q -- "require --live" "${output}"; then
		echo "perf timechart --tui plumbing test [Failed: --window without --live]"
		cat "${output}"
		err=1
		return
	fi
	if perf timechart --live -I -P < /dev/null > "${output}" 2>&1 ||
	   ! grep -q -- "-I cannot be used with -P or -T" "${output}"; then
		echo "perf timechart --tui plumbing test [Failed: -I with -P not rejected]"
		cat "${output}"
		err=1
		return
	fi
	echo "perf timechart --tui plumbing test [Success]"
}

test_no_events() {
	echo "ttimechart no events test"
	if ! perf record -e task-clock -o "${clockdata}" -- true > /dev/null 2>&1; then
		echo "ttimechart no events test [Skipped: perf record failed]"
		return
	fi
	if perf script ttimechart -i "${clockdata}" --dump > "${output}" 2>&1; then
		echo "ttimechart no events test [Failed: expected an error]"
		err=1
		return
	fi
	if ! grep -q "no scheduler, power or I/O events" "${output}"; then
		echo "ttimechart no events test [Failed: unexpected error message]"
		cat "${output}"
		err=1
		return
	fi
	# The same should be reported when reading the data from a pipe.
	if perf record -e task-clock -o - -- true 2> /dev/null | \
		perf script ttimechart -i - --dump > "${output}" 2>&1; then
		echo "ttimechart no events test [Failed: expected an error from a pipe]"
		err=1
		return
	fi
	if ! grep -q "no scheduler, power or I/O events" "${output}"; then
		echo "ttimechart no events test [Failed: unexpected error message from a pipe]"
		cat "${output}"
		err=1
		return
	fi
	# Exercise LiveRecorder's perf record subprocess, control pipe and
	# -o output file using task-clock when system-wide recording is allowed.
	if perf record -a -e task-clock -o "${clockdata}" -- true > /dev/null 2>&1; then
		rm -f "${clockdata}"
		if ! "$PYTHON" - "${PERF_BIN:-perf}" "${clockdata}" \
			"$(declare -f workload); workload" > "${output}" 2>&1 <<'EOF'
import asyncio
import os
import sys
import ttimechart as tc

async def run() -> None:
    rec = tc.LiveRecorder(sys.argv[1], False, False, ["bash", "-c", sys.argv[3]], sys.argv[2])
    rec.events = lambda: ["task-clock"]
    rec.start()
    app = tc.TimechartApp("live", False, False, [], live=rec, window=5.0)
    try:
        async with app.run_test(size=(120, 40)) as pilot:
            await pilot.press("space")
            await pilot.pause(0.1)
            await pilot.press("space")
            for _ in range(300):
                if app.return_code is not None:
                    break
                await pilot.pause(0.05)
    finally:
        rec.stop()
    if app.return_code != 1 or not app.data.nr_samples or not os.path.getsize(sys.argv[2]):
        raise RuntimeError(f"Unexpected result: rc={app.return_code} samples={app.data.nr_samples}")

asyncio.run(run())
EOF
		then
			echo "ttimechart no events test [Failed: LiveRecorder task-clock test]"
			cat "${output}"
			err=1
			return
		fi
	fi
	echo "ttimechart no events test [Success]"
}

test_dump() {
	echo "ttimechart dump test"
	if ! perf script ttimechart -i "${perfdata}" --dump > "${output}" 2>&1; then
		echo "ttimechart dump test [Failed: script failed]"
		cat "${output}"
		err=1
		return
	fi
	if ! grep -q "^Duration: .*sched events: [1-9]" "${output}" ||
	   ! grep -q "^CPU [0-9]*: busy" "${output}" ||
	   ! grep -q "^Task .*Running .*Waiting .*Blocked" "${output}" ||
	   ! grep -q "sleep" "${output}"; then
		echo "ttimechart dump test [Failed: unexpected output]"
		cat "${output}"
		err=1
		return
	fi

	# Tasks only shouldn't show CPUs, power only shouldn't show tasks.
	perf script ttimechart -i "${perfdata}" --dump -T > "${output}" 2>&1 || true
	if grep -q "^CPU [0-9]*: " "${output}" ||
	   ! grep -q "^Task .*Running .*Waiting .*Blocked" "${output}"; then
		echo "ttimechart dump test [Failed: -T output]"
		cat "${output}"
		err=1
		return
	fi
	perf script ttimechart -i "${perfdata}" --dump -P > "${output}" 2>&1 || true
	if grep -q "^Task .*Running .*Waiting .*Blocked" "${output}" ||
	   ! grep -q "^CPU [0-9]*: " "${output}"; then
		echo "ttimechart dump test [Failed: -P output]"
		cat "${output}"
		err=1
		return
	fi

	# Filtering on the workload shouldn't show other tasks.
	perf script ttimechart -i "${perfdata}" --dump -p sleep > "${output}" 2>&1 || true
	if ! grep -q "^sleep " "${output}" || grep -q "^bash " "${output}"; then
		echo "ttimechart dump test [Failed: -p output]"
		cat "${output}"
		err=1
		return
	fi
	echo "ttimechart dump test [Success]"
}

test_headless_ui() {
	echo "ttimechart headless UI test"
	# Drive the textual app without a terminal, exercising the views and
	# key bindings.
	if ! "$PYTHON" - "${perfdata}" > "${output}" 2>&1 <<'EOF'
import asyncio
import sys
import ttimechart as tc

async def run() -> None:
    # The app starts before the data is loaded in a background thread.
    app = tc.TimechartApp(sys.argv[1], False, False, [])
    async with app.run_test(size=(120, 40)) as pilot:
        for _ in range(600):
            if app.loaded:
                break
            await pilot.pause(0.1)
        if not app.loaded:
            raise RuntimeError("Timed out loading data")
        await pilot.pause()
        tabs = app.query_one(tc.TabbedContent)
        for tab in ["cpus", "tasks", "summary"]:
            tabs.active = tab
            await pilot.pause()
            await pilot.press("down", "plus", "plus", "right", "n", "p", "minus",
                              "shift+right", "shift+left", "s", "w", "0")
            await pilot.pause()
        tabs.active = "summary"
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        details = str(app.query_one("#details", tc.Static).render())
        if "Cursor" not in details:
            raise RuntimeError(f"Unexpected details: {details}")
        print("headless UI ok")

asyncio.run(run())
EOF
	then
		echo "ttimechart headless UI test [Failed: exception]"
		cat "${output}"
		err=1
		return
	fi
	if ! grep -q "headless UI ok" "${output}"; then
		echo "ttimechart headless UI test [Failed: unexpected output]"
		cat "${output}"
		err=1
		return
	fi
	echo "ttimechart headless UI test [Success]"
}

test_live_synthetic() {
	echo "ttimechart live UI test (synthetic)"
	# Exercise live mode's rolling window, pruning, pause/resume and
	# following with a fake recorder, which doesn't need tracepoint
	# permissions.
	if ! "$PYTHON" - > "${output}" 2>&1 <<'EOF'
import asyncio
import threading
import time
from time import monotonic_ns
import ttimechart as tc

SEC = 1_000_000_000

class Ev:
    def __init__(self, name):
        self.name = name
    def __str__(self):
        return f"evsel({self.name})"

class Sample:
    def __init__(self, name, t, cpu, tid, **kw):
        self.evsel = Ev(name)
        self.sample_time = t
        self.sample_cpu = cpu
        self.sample_tid = tid
        self.sample_pid = tid
        self.sample_id = hash(name)
        for k, v in kw.items():
            setattr(self, k, v)

class FakeRecorder:
    def __init__(self):
        self.origin = monotonic_ns()
        self.data_fd = -1
        self.flush_interval = 0.05
        self.paused = False
        self.pause_calls = []
        self.stopped = threading.Event()
        self.finish = False

    def backlog(self):
        return 0.0

    def set_paused(self, paused):
        self.paused = paused
        self.pause_calls.append(paused)

    def stop(self):
        self.stopped.set()

    def error_text(self):
        return ""

async def run() -> None:
    rec = FakeRecorder()

    def fake_read(data, _fd):
        t0 = rec.origin
        # Task 300 only runs at the start so pruning should drop it once the
        # 1s window advances past t0 + 3000.
        data.process_event(Sample("sched:sched_wakeup", t0 + 1000, 0, 1,
                                  pid=300, comm="early", common_pid=1, common_flags=0))
        data.process_event(Sample("sched:sched_switch", t0 + 2000, 0, 0,
                                  prev_pid=0, prev_comm="swapper", prev_state=1,
                                  next_pid=300, next_comm="early"))
        data.process_event(Sample("sched:sched_switch", t0 + 3000, 0, 300,
                                  prev_pid=300, prev_comm="early", prev_state=1,
                                  next_pid=0, next_comm="swapper"))
        cur = 0
        while not rec.stopped.is_set() and not rec.finish:
            now = monotonic_ns()
            if rec.paused:
                time.sleep(0.01)
                continue
            nxt = 100 if cur == 0 else 0
            comm = "worker" if nxt == 100 else "swapper"
            prev_comm = "worker" if cur == 100 else "swapper"
            if nxt:
                data.process_event(Sample("sched:sched_wakeup", now, 0, cur or 1,
                                          pid=nxt, comm=comm, common_pid=cur or 1,
                                          common_flags=0))
            data.process_event(Sample("sched:sched_switch", now, 0, cur,
                                      prev_pid=cur, prev_comm=prev_comm, prev_state=1,
                                      next_pid=nxt, next_comm=comm))
            cur = nxt
            time.sleep(0.005)

    tc.read_events = fake_read
    app = tc.TimechartApp("live", False, False, [], live=rec, window=1.0)
    try:
        async with app.run_test(size=(120, 40)) as pilot:
            for _ in range(300):
                with app.data.lock:
                    if app.data.pruned_to > rec.origin + 3000:
                        break
                await pilot.pause(0.05)
            with app.data.lock:
                if app.data.pruned_to <= rec.origin + 3000 or 300 in app.data.tasks:
                    raise RuntimeError("Task outside the window was not pruned")
                starts = [t.segs.starts[0] for t in app.data.tasks.values() if len(t.segs)]
                if not starts or min(starts) < app.data.pruned_to:
                    raise RuntimeError(f"Unpruned segments: {starts} < {app.data.pruned_to}")
            if app.window.last - app.window.first != SEC:
                raise RuntimeError(f"Unexpected window span: {app.window}")

            await pilot.press("space")
            await pilot.pause(0.2)
            if rec.pause_calls != [True] or "Paused" not in app.sub_title:
                raise RuntimeError(f"Did not pause: {rec.pause_calls} {app.sub_title}")
            frozen = app.window.last
            await pilot.pause(0.4)
            if app.window.last != frozen:
                raise RuntimeError("Window moved while paused")
            await pilot.press("space")
            await pilot.pause(0.3)
            if rec.pause_calls != [True, False] or not app.following:
                raise RuntimeError("Did not resume")

            await pilot.press("plus")
            await pilot.pause(0.2)
            if app.following or app.follow_cursor:
                raise RuntimeError("Zooming did not stop following")
            await pilot.press("0")
            await pilot.pause(0.2)
            if not app.following or not app.follow_cursor:
                raise RuntimeError("Resetting zoom did not resume following")
            await pilot.press("left")
            await pilot.pause(0.1)
            if not app.following or app.follow_cursor:
                raise RuntimeError("Moving cursor did not stop cursor following")
            await pilot.press("0")
            await pilot.pause(0.1)
            if not app.follow_cursor:
                raise RuntimeError("Resetting zoom did not resume cursor following")

            rec.finish = True
            for _ in range(100):
                if not app.recording:
                    break
                await pilot.pause(0.05)
            if app.recording or "Finished" not in app.sub_title:
                raise RuntimeError(f"Did not finish: {app.sub_title}")
    finally:
        rec.stop()

    # Multiple pause/resume cycles before buffered events arrive must still
    # close states at each unrecorded gap, and pipe round tracking must detect
    # unflushed rounds across tracing metadata.
    gap_data = tc.TimechartData()
    gap_data.process_event(Sample("sched:sched_switch", 1000, 0, 0,
                                  prev_pid=0, prev_comm="swapper", prev_state=1,
                                  next_pid=50, next_comm="runner"))
    with gap_data.lock:
        gap_data.mark_gap(2000)
        gap_data.mark_gap(4000)
    gap_data.process_event(Sample("sched:sched_switch", 2500, 0, 50,
                                  prev_pid=50, prev_comm="runner", prev_state=1,
                                  next_pid=0, next_comm="swapper"))
    gap_data.process_event(Sample("sched:sched_switch", 4500, 0, 0,
                                  prev_pid=0, prev_comm="swapper", prev_state=1,
                                  next_pid=50, next_comm="runner"))
    gap_data.finish()
    if list(zip(gap_data.tasks[50].segs.starts, gap_data.tasks[50].segs.ends)) != [(2000, 2500)]:
        raise RuntimeError(f"Unexpected gap segments: {gap_data.tasks[50].segs.starts}")
    gap_data.prune(2000)
    if gap_data.tasks[50].switches != 1:
        raise RuntimeError(f"Gap prune corrupted switches: {gap_data.tasks[50].switches}")
    gap_data.prune(2500)
    if 50 in gap_data.tasks:
        raise RuntimeError("Pruned task 50 should be empty")

    # Verify totals, switches, blocked/waiting checkpoints, out-of-order flushes,
    # unmerged I/O syscalls, and comm updates across exec.
    inv = tc.TimechartData()
    cur_comm = "perf-exec"
    class FakeThread:
        def comm(self):
            return cur_comm
    class FakeSession:
        def find_thread(self, _tid):
            return FakeThread()
    inv.session = FakeSession()
    inv.process_event(Sample("sched:sched_switch", 1000, 0, 0,
                             prev_pid=0, prev_comm="swapper", prev_state=1,
                             next_pid=10, next_comm="blocker"))
    # Task 10 blocks at 2000; task 11 runs to 5000 so checkpoint extends task 10.
    inv.process_event(Sample("sched:sched_switch", 2000, 0, 10,
                             prev_pid=10, prev_comm="blocker", prev_state=2,
                             next_pid=11, next_comm="other"))
    inv.process_event(Sample("sched:sched_wakeup", 5000, 1, 11,
                             pid=12, comm="waiter", common_pid=11, common_flags=0))
    with inv.lock:
        inv.checkpoint()
        inv.prune(3000)
    if (inv.tasks[10].state != tc.STATE_BLOCKED or
            inv.tasks[10].totals[tc.STATE_BLOCKED] != 2000 or
            inv.tasks[12].state != tc.STATE_WAITING):
        raise RuntimeError(f"Blocked/waiting state lost: {inv.tasks[10].totals}")
    # Earlier event on another CPU after checkpoint must not leak totals.
    inv.process_event(Sample("sched:sched_switch", 4800, 0, 11,
                             prev_pid=11, prev_comm="other", prev_state=0,
                             next_pid=0, next_comm="swapper"))
    inv.process_event(Sample("sched:sched_switch", 6000, 0, 11,
                             prev_pid=11, prev_comm="other", prev_state=1,
                             next_pid=0, next_comm="swapper"))
    with inv.lock:
        inv.prune(6000)
    if 11 in inv.tasks:
        raise RuntimeError(f"Leaked totals or switches: {inv.tasks[11].totals} "
                           f"{inv.tasks[11].switches}")
    # Adjacent and same-timestamp I/O syscalls must stay separate and update comm,
    # while ignoring perf's unset ':tid' thread placeholder.
    cur_comm = ":20"
    inv.process_event(Sample("sched:sched_wakeup", 6500, 0, 1,
                             pid=20, comm="launcher", common_pid=1, common_flags=0))
    inv.process_event(Sample("syscalls:sys_enter_read", 7000, 0, 20, fd=4))
    inv.process_event(Sample("syscalls:sys_exit_read", 7100, 0, 20, ret=4096))
    if inv.tasks[20].comm != "launcher":
        raise RuntimeError(f"Unset :tid placeholder overwrote comm: {inv.tasks[20].comm}")
    cur_comm = "cat"
    inv.process_event(Sample("syscalls:sys_enter_read", 7100, 0, 20, fd=4))
    inv.process_event(Sample("syscalls:sys_exit_read", 7200, 0, 20, ret=4096))
    inv.process_event(Sample("syscalls:sys_enter_read", 8000, 0, 20, fd=4))
    inv.process_event(Sample("syscalls:sys_exit_read", 8000, 0, 20, ret=512))
    inv.process_event(Sample("syscalls:sys_enter_read", 8000, 0, 20, fd=4))
    inv.process_event(Sample("syscalls:sys_exit_read", 8000, 0, 20, ret=512))
    t20 = inv.tasks[20]
    if (len(t20.io) != 4 or t20.io_bytes != 9216 or t20.comm != "cat" or
            t20.comms != ["launcher", "cat"]):
        raise RuntimeError(f"Unexpected I/O task state: {len(t20.io)} {t20.io_bytes} {t20.comms}")
    inv.process_event(Sample("sched:sched_switch", 8500, 0, 20,
                             prev_pid=20, prev_comm="cat", prev_state=1,
                             next_pid=0, next_comm="swapper"))
    with inv.lock:
        inv.prune(9000)
    if 20 in inv.tasks:
        raise RuntimeError(f"Leaked I/O bytes on prune: {t20.io_bytes}")
    inv.session = None

    tracker = tc.PerfPipeTracker()
    pipe_hdr = tc.struct.pack("=QQ", tracker.PERF_MAGIC, 16)
    td_rec = tc.struct.pack("=IHHI", tracker.HEADER_TRACING_DATA, 0, 12, 8) + b"12345678"
    sample_rec = tc.struct.pack("=IHHQ", 9, 0, 16, 0)
    # Feed byte-by-byte to exercise split headers.
    for b in pipe_hdr + td_rec + sample_rec + tracker.FINISHED_ROUND_EVENT:
        tracker.feed(bytes([b]))
    if not tracker.at_boundary() or not tracker.unflushed_round or tracker.rounds != 1:
        raise RuntimeError("PerfPipeTracker failed to track unflushed round")
    tracker.feed(tracker.FINISHED_ROUND_EVENT)
    if tracker.unflushed_round or tracker.rounds != 2:
        raise RuntimeError("PerfPipeTracker failed to clear unflushed round")

    # Also test live I/O-only mode (-I), including the shell filter quoting.
    io_events = tc.LiveRecorder("perf", False, False, [], None, io_only=True).events()
    if not io_events or not all(e.startswith("syscalls:sys_") for e in io_events):
        raise RuntimeError(f"Unexpected I/O events: {io_events}")
    orig_comm = open("/proc/self/comm", encoding="utf-8").read().strip()
    with tc.tempfile.NamedTemporaryFile("w", delete=False) as fake_perf:
        fake_perf.write(f"#!{tc.sys.executable}\n"
                        "import json, os, sys\n"
                        "sys.stderr.write(json.dumps([os.getpid(), sys.argv[1:]]) + '\\n')\n")
        fake_perf_path = fake_perf.name
    try:
        tc.os.chmod(fake_perf_path, 0o755)
        cmd_rec = tc.LiveRecorder(fake_perf_path, False, False, ["echo", "a b"], None,
                                  io_only=True)
        cmd_rec.start()
        cmd_rec.proc.wait(timeout=5)
        cmd_rec.stop()
        if cmd_rec.backlog() != 0.0:
            raise RuntimeError("backlog() after stop() should be 0.0")
        import json
        exec_pid, exec_argv = json.loads(cmd_rec.error_text())
        expected_filt = (f'comm != "ttimechart:{tc.os.getpid() & 0xffff:x}" && '
                         f"common_pid != {exec_pid}")
        filt_idx = exec_argv.index("--filter")
        if (exec_pid != cmd_rec.proc.pid or exec_argv[filt_idx + 1] != expected_filt or
                exec_argv[-3:] != ["--", "echo", "a b"]):
            raise RuntimeError(f"Unexpected I/O perf record argv: {exec_pid} {exec_argv}")
        if open("/proc/self/comm", encoding="utf-8").read().strip() != orig_comm:
            raise RuntimeError("Process comm was not restored after stop()")
        # Verify start() cleans up if starting control_thread fails.
        real_start = threading.Thread.start
        calls = 0
        def fail_second_thread(self_t):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("simulated thread start failure")
            real_start(self_t)
        threading.Thread.start = fail_second_thread
        try:
            fail_rec = tc.LiveRecorder(fake_perf_path, False, False, [], None, io_only=True)
            try:
                fail_rec.start()
                raise RuntimeError("Expected start() to fail")
            except RuntimeError as e:
                if "simulated thread start failure" not in str(e):
                    raise
        finally:
            threading.Thread.start = real_start
        if (fail_rec.ctl_fd != -1 or fail_rec.wake_r != -1 or fail_rec.tee_r != -1 or
                open("/proc/self/comm", encoding="utf-8").read().strip() != orig_comm):
            raise RuntimeError("Failed start() left unclosed fds or unmended comm")
    finally:
        tc.os.unlink(fake_perf_path)
    # Pump must preserve flush_round_target across partial record reads.
    pump_rec = tc.LiveRecorder("perf", False, False, [], None)
    pump_rec.wake_r, pump_rec.wake_w = tc.os.pipe()
    tc.os.set_blocking(pump_rec.wake_r, False)
    tc.os.set_blocking(pump_rec.wake_w, False)
    src_r, src_w = tc.os.pipe()
    dst_r, dst_w = tc.os.pipe()
    pump_t = threading.Thread(target=pump_rec.pump, args=(src_r, dst_w, None), daemon=True)
    pump_t.start()
    try:
        full_round = pipe_hdr + sample_rec + tracker.FINISHED_ROUND_EVENT
        with pump_rec.round_lock:
            pump_rec.flush_round_target = -1
            pump_rec.flush_seq = 1
        # Write a partial record first so tracker is not at a boundary yet.
        tc.os.write(src_w, full_round[:20])
        time.sleep(0.05)
        tc.os.write(src_w, full_round[20:])
        pump_rec.wake_pump()
        expected_len = len(full_round) + len(tracker.FINISHED_ROUND_EVENT)
        pumped = b""
        deadline = time.monotonic() + 2.0
        while len(pumped) < expected_len and time.monotonic() < deadline:
            ready, _, _ = tc.select.select([dst_r], [], [], 0.1)
            if ready:
                chunk = tc.os.read(dst_r, 4096)
                if not chunk:
                    break
                pumped += chunk
        tc.os.close(src_w)
        src_w = -1
        pump_t.join(timeout=2)
        if pumped != full_round + tracker.FINISHED_ROUND_EVENT:
            raise RuntimeError(f"Pump missed split-record flush: {len(pumped)} != {expected_len}")
    finally:
        if src_w >= 0:
            tc.os.close(src_w)
        tc.os.close(src_r)
        tc.os.close(dst_r)
        pump_rec.close_wake_fds()

    # Idle live window past last_time must not wipe open or finished states.
    idle_rec = FakeRecorder()
    idle_rec.origin = monotonic_ns() - 5 * SEC
    idle_app = tc.TimechartApp("live", False, False, [], live=idle_rec, window=1.0)
    idle_app.data.process_event(Sample("sched:sched_switch", idle_rec.origin + 1000, 0, 0,
                                       prev_pid=0, prev_comm="swapper", prev_state=1,
                                       next_pid=77, next_comm="quiet"))
    idle_app.data.process_event(Sample("power:cpu_idle", idle_rec.origin + 1500, 1, 0,
                                       cpu_id=1, state=1))
    idle_app.data.process_event(Sample("power:cpu_frequency", idle_rec.origin + 2000, 0, 77,
                                       cpu_id=0, state=2000000))
    with idle_app.data.lock:
        idle_app.data.checkpoint()
        idle_app.live_prune()
    if (77 not in idle_app.data.tasks or not len(idle_app.data.tasks[77].segs) or
            not len(idle_app.data.cpus[1].cstate)):
        raise RuntimeError("live_prune() wiped open states when idle past window")
    idle_app.data.finish()
    with idle_app.data.lock:
        idle_app.live_prune()
    if 77 not in idle_app.data.tasks or not len(idle_app.data.tasks[77].segs):
        raise RuntimeError("live_prune() after finish() wiped tasks")

    io_rec = FakeRecorder()

    def fake_io_read(data, _fd):
        now = monotonic_ns()
        # Self I/O should be ignored in live mode without counting as samples.
        own = tc.os.getpid()
        data.process_event(Sample("syscalls:sys_enter_read", now, 0, own, fd=3))
        data.process_event(Sample("syscalls:sys_exit_read", now + 1000, 0, own, ret=64))
        # Scheduler-only tasks must be ignored when io_only is set.
        data.process_event(Sample("sched:sched_switch", now + 1500, 0, 0,
                                  prev_pid=0, prev_comm="swapper", prev_state=1,
                                  next_pid=9999, next_comm="schedonly"))
        data.process_event(Sample("sched:sched_switch", now + 1800, 0, 9999,
                                  prev_pid=9999, prev_comm="schedonly", prev_state=1,
                                  next_pid=0, next_comm="swapper"))
        # Workload I/O should be recorded.
        data.process_event(Sample("syscalls:sys_enter_read", now + 2000, 0, 4242, fd=4))
        data.process_event(Sample("syscalls:sys_exit_read", now + 5000, 0, 4242, ret=4096))
        data.process_event(Sample("syscalls:sys_enter_write", now + 6000, 0, 4242, fd=5))
        data.process_event(Sample("syscalls:sys_exit_write", now + 9000, 0, 4242, ret=2048))

    tc.read_events = fake_io_read
    io_app = tc.TimechartApp("live", False, False, [], live=io_rec, window=1.0, io_only=True)
    async with io_app.run_test(size=(120, 40)) as pilot:
        for _ in range(100):
            if not io_app.recording:
                break
            await pilot.pause(0.05)
        await pilot.pause()
        tabs = io_app.query_one(tc.TabbedContent)
        if (tabs.active != "io" or not io_app.data.sched_tasks([]) or io_app.tasks or
                len(io_app.io_tasks) != 1 or io_app.data.io_events != 4 or
                io_app.data.nr_samples != 6):
            raise RuntimeError(f"Unexpected I/O state: active={tabs.active} "
                               f"tasks={len(io_app.tasks)} io_tasks={len(io_app.io_tasks)} "
                               f"events={io_app.data.io_events} samples={io_app.data.nr_samples}")
        import io as pyio
        from contextlib import redirect_stdout
        buf = pyio.StringIO()
        with redirect_stdout(buf):
            io_app.data.dump(False, False, [], io_only=True)
        if "tasks: 1," not in buf.getvalue() or "schedonly" in buf.getvalue():
            raise RuntimeError(f"Unexpected -I dump output: {buf.getvalue()}")
        tabs.active = "summary"
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        if tabs.active != "io":
            raise RuntimeError(f"Summary enter did not activate I/O tab: {tabs.active}")
        print("live synthetic ok")

asyncio.run(run())
EOF
	then
		echo "ttimechart live UI test (synthetic) [Failed: exception]"
		cat "${output}"
		err=1
		return
	fi
	if ! grep -q "live synthetic ok" "${output}"; then
		echo "ttimechart live UI test (synthetic) [Failed: unexpected output]"
		cat "${output}"
		err=1
		return
	fi
	echo "ttimechart live UI test (synthetic) [Success]"
}

test_live_record() {
	echo "ttimechart live record test"
	if [ "${system_wide}" != 1 ]; then
		# Live mode records system wide, like perf timechart record.
		echo "ttimechart live record test [Skipped: can't record system wide]"
		return
	fi
	rm -f "${perfdata}.live"
	if ! "$PYTHON" - "${PERF_BIN:-perf}" "${perfdata}.live" \
		"$(declare -f workload); workload" > "${output}" 2>&1 <<'EOF'
import asyncio
import sys
import ttimechart as tc

async def run() -> None:
    rec = tc.LiveRecorder(sys.argv[1], False, False, ["bash", "-c", sys.argv[3]], sys.argv[2])
    rec.start()
    app = tc.TimechartApp("live", False, False, [], live=rec, window=5.0)
    try:
        async with app.run_test(size=(120, 40)) as pilot:
            for _ in range(600):
                if not app.recording:
                    break
                await pilot.pause(0.1)
            if app.recording or not app.data.has_events():
                raise RuntimeError("Live recording of workload did not complete")
            print("live record ok")
    finally:
        rec.stop()

asyncio.run(run())
EOF
	then
		echo "ttimechart live record test [Failed: exception]"
		cat "${output}"
		err=1
		return
	fi
	if ! perf script ttimechart -i "${perfdata}.live" --dump > "${output}" 2>&1 ||
	   ! grep -q "^Duration: .*sched events: [1-9]" "${output}"; then
		echo "ttimechart live record test [Failed: saved perf.data unreadable]"
		cat "${output}"
		err=1
		return
	fi
	if perf timechart record -I -o "${perfdata}.live" -- true > /dev/null 2>&1; then
		rm -f "${perfdata}.live"
		if ! "$PYTHON" - "${PERF_BIN:-perf}" "${perfdata}.live" > "${output}" 2>&1 <<'EOF'
import asyncio
import sys
import ttimechart as tc

async def run() -> None:
    rec = tc.LiveRecorder(sys.argv[1], False, False,
                          ["bash", "-c", "cat /etc/hostname > /dev/null"],
                          sys.argv[2], io_only=True)
    rec.start()
    app = tc.TimechartApp("live", False, False, [], live=rec, window=5.0, io_only=True)
    try:
        async with app.run_test(size=(120, 40)) as pilot:
            for _ in range(600):
                if not app.recording:
                    break
                await pilot.pause(0.1)
            if app.recording or not app.data.io_events:
                raise RuntimeError("Live I/O recording of workload did not complete")
    finally:
        rec.stop()

asyncio.run(run())
EOF
		then
			echo "ttimechart live record test [Failed: live -I exception]"
			cat "${output}"
			err=1
			return
		fi
	fi
	echo "ttimechart live record test [Success]"
}

test_plumbing
test_no_events
test_live_synthetic

if ! record; then
	echo "Skipping remaining tests, failed to record scheduler events (permissions?)"
	if [ $err -eq 0 ]; then
		err=2
	fi
	cleanup
	exit $err
fi

test_dump
test_headless_ui
test_live_record

cleanup
exit $err
