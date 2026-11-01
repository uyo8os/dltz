"""Tests execute the exact Python payload embedded in the one-file installer."""
import collections
import contextlib
import datetime as dt
import gzip
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

SOURCE = (Path(__file__).resolve().parents[1] / "ssh-tg-notify.sh").read_text(encoding="utf-8")
PAYLOAD = SOURCE.split("    cat <<'GUARD_EOF'\n", 1)[1].split("\nGUARD_EOF\n", 1)[0]
guard = types.ModuleType("ssh_tg_guard")
exec(compile(PAYLOAD, "embedded-guard.py", "exec"), guard.__dict__)
NOW = dt.datetime(2026, 11, 1, 12, tzinfo=dt.timezone.utc).timestamp()
CONFIG = {"SERVER_NAME": "VMISS-Tri & _node", "TG_BOT_TOKEN": "123:TEST_token", "TG_CHAT_ID": "-10012345"}


def record(number, address="66.66.66.66", success=False, stamp=NOW, user="root"):
    return {"__CURSOR": f"cursor-{number}", "__REALTIME_TIMESTAMP": str(int(stamp * 1_000_000)),
            "MESSAGE": f'{"Accepted" if success else "Failed"} password for {user} from {address} port 54000 ssh2'}


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = guard.Store(self.root / "state.sqlite3")

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def outbox(self):
        return [json.loads(row[0]) for row in self.store.connection.execute("SELECT payload FROM outbox ORDER BY id")]

    def test_canonical_failures_and_ipv6(self):
        for method in ("password", "publickey", "keyboard-interactive/pam", "none"):
            event = guard.parse_auth(f"Failed {method} for invalid user admin from 2001:db8::1 port 12345 ssh2")
            self.assertEqual((event["ip"], event["user"], event["failed"]), ("2001:db8::1", "admin", True))
        self.assertEqual(guard.parse_auth("Failed password for root from ::ffff:66.66.66.66 port 55 ssh2")["ip"], "66.66.66.66")

    def test_summary_and_pam_logs_are_not_double_counted(self):
        for message in ("Invalid user root from 66.66.66.66 port 54", "pam_unix(sshd:auth): authentication failure",
                        "maximum authentication attempts exceeded for root from 66.66.66.66 port 54 ssh2",
                        "Partial publickey for root from 66.66.66.66 port 54 ssh2", None,
                        "Failed password for root from not-an-ip port 54 ssh2"):
            self.assertIsNone(guard.parse_auth(message))

    def test_threshold_is_eleven_and_alerts_once(self):
        for number in range(1, 11):
            self.store.consume(record(number))
        self.assertEqual(self.outbox(), [])
        self.store.consume(record(11))
        self.assertEqual(self.outbox()[0]["count"], 11)
        for number in range(12, 101):
            self.store.consume(record(number))
        self.assertEqual(len(self.outbox()), 1)

    def test_ip_streak_crosses_usernames_and_other_ips(self):
        for number in range(1, 11):
            self.store.consume(record(number, user=f"user{number}"))
            self.store.consume(record(f"other-{number}", address="66.66.66.67"))
        self.store.consume(record(11, user="root"))
        self.assertEqual((self.outbox()[0]["user"], self.outbox()[0]["ip"]), ("root", "66.66.66.66"))
        self.assertEqual(len(self.outbox()), 1)

    def test_success_resets_only_same_ip(self):
        for number in range(1, 11):
            self.store.consume(record(number))
            self.store.consume(record(f"other-{number}", address="66.66.66.67"))
        self.store.consume(record("success", success=True))
        self.store.consume(record(11, address="66.66.66.67"))
        self.store.consume(record(12))
        self.assertEqual([item["ip"] for item in self.outbox()], ["66.66.66.67"])
        for number in range(13, 23):
            self.store.consume(record(number))
        self.assertEqual(len(self.outbox()), 2)

    def test_restart_and_cursor_do_not_lose_or_duplicate_counts(self):
        for number in range(1, 11):
            self.store.consume(record(number))
        self.store.close()
        self.store = guard.Store(self.root / "state.sqlite3")
        self.store.consume(record(10))
        self.store.consume(record(11))
        self.store.consume(record(11))
        self.assertEqual(len(self.outbox()), 1)
        count = self.store.connection.execute("SELECT count FROM streaks").fetchone()[0]
        self.assertEqual(count, 11)

    def test_outbox_retries_and_survives_restart(self):
        for number in range(1, 12):
            self.store.consume(record(number))
        sender = mock.Mock(return_value=False)
        self.assertFalse(self.store.deliver_one(CONFIG, sender=sender, ports=lambda: "22", now=NOW))
        self.assertIsNone(self.store.deliver_one(CONFIG, sender=sender, ports=lambda: "22", now=NOW + 1))
        self.store.close()
        self.store = guard.Store(self.root / "state.sqlite3")
        sender.return_value = True
        self.assertTrue(self.store.deliver_one(CONFIG, sender=sender, ports=lambda: "22", now=NOW + 5))
        self.assertEqual(self.outbox(), [])
        self.assertEqual(sender.call_count, 2)

    def test_cursor_expiration_resets_streaks_without_losing_pending_alerts(self):
        for number in range(1, 12):
            self.store.consume(record(number))
        self.store.reset_streaks()
        self.assertIsNone(self.store.meta("cursor"))
        self.assertEqual(self.store.connection.execute("SELECT count(*) FROM streaks").fetchone()[0], 0)
        self.assertEqual(len(self.outbox()), 1)

    def test_rank_top_ten_is_sorted_and_exact_format(self):
        values = collections.Counter({f"66.66.66.{number}": number for number in range(1, 13)})
        values["66.66.66.61"] = 800
        values["66.66.66.62"] = 100
        with mock.patch.object(guard, "journal_counts", return_value=(values, 999)), \
                mock.patch.object(guard, "file_counts") as fallback:
            rows = guard.ranking(NOW)
            fallback.assert_not_called()
        self.assertEqual(rows[:2], [("66.66.66.61", 800), ("66.66.66.62", 100)])
        self.assertEqual(len(rows), 10)
        output = io.StringIO()
        with mock.patch.object(guard, "ranking", return_value=rows), \
                mock.patch.object(guard.sys, "argv", ["guard", "rank"]), contextlib.redirect_stdout(output):
            self.assertEqual(guard.main(), 0)
        self.assertEqual(output.getvalue().splitlines()[:2], ["800次 66.66.66.61", "100次 66.66.66.62"])
        self.assertEqual(len(output.getvalue().splitlines()), 10)

    def test_journal_window_and_malformed_records(self):
        entries = [record(1), record(2, stamp=NOW - 86400), record(3, stamp=NOW - 86401),
                   record(4, stamp=NOW + 1), record(5, success=True)]
        entries.append({"MESSAGE": "Failed password for root from 66.66.66.66 port 5 ssh2"})
        stream = io.StringIO("not json\n" + "\n".join(json.dumps(item) for item in entries))
        process = mock.Mock(stdout=stream)
        process.wait.return_value = 0
        with mock.patch.object(guard.shutil, "which", return_value="/usr/bin/journalctl"), \
                mock.patch.object(guard.subprocess, "Popen", return_value=process):
            counts, records = guard.journal_counts(NOW - 86400, NOW)
        self.assertEqual(counts, {"66.66.66.66": 2})
        self.assertEqual(records, 3)

    def test_rotated_and_gzip_syslog_use_timestamps_not_file_age(self):
        prefix = "2026-11-01T11:00:00+00:00 host sshd[22]: "
        event = record(1)["MESSAGE"]
        (self.root / "auth.log").write_text(prefix + event + "\n" + prefix + "Invalid user root from 66.66.66.66 port 5\n", encoding="utf-8")
        (self.root / "auth.log.1").write_text("2026-10-31T11:59:59+00:00 host sshd[22]: " + event + "\n", encoding="utf-8")
        with gzip.open(self.root / "auth.log.2.gz", "wt", encoding="utf-8") as stream:
            stream.write(prefix + event + "\n")
        # The alternate syslog copy must not double-count the same event.
        (self.root / "secure").write_text(prefix + event + "\n", encoding="utf-8")
        counts, available = guard.file_counts(NOW - 86400, NOW, self.root)
        self.assertTrue(available)
        self.assertEqual(counts, {"66.66.66.66": 2})

    def test_classic_syslog_year_boundary(self):
        local_now = dt.datetime(2026, 1, 1, 1).timestamp()
        stamp = guard.syslog_time("Dec 31 23:59:59 host sshd[2]: Failed password", local_now)
        self.assertEqual(dt.datetime.fromtimestamp(stamp).year, 2025)
        self.assertEqual(guard.syslog_time("invalid timestamp", NOW), None)

    def test_ranking_fallback_is_used_only_when_no_journal_records(self):
        with mock.patch.object(guard, "journal_counts", return_value=(collections.Counter(), 0)), \
                mock.patch.object(guard, "file_counts", return_value=({"1.2.3.4": 20}, True)) as fallback:
            self.assertEqual(guard.ranking(NOW), [("1.2.3.4", 20)])
            fallback.assert_called_once_with(NOW - 86400, NOW)

    def test_listening_ports_are_not_clients_ephemeral_ports(self):
        rows = '\n'.join([
            'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))',
            'LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=4))',
            'LISTEN 0 128 0.0.0.0:2324 0.0.0.0:* users:(("sshd",pid=1,fd=5))',
            'LISTEN 0 128 0.0.0.0:23555 0.0.0.0:* users:(("sshd",pid=1,fd=6))',
            'LISTEN 0 128 0.0.0.0:54000 0.0.0.0:* users:(("other",pid=2,fd=3))'])
        with mock.patch.object(guard, "output_of", return_value=rows):
            self.assertEqual(guard.ssh_ports(), "22、2324、23555")

    def test_socket_activation_ports(self):
        sockets = ["Listen=[::]:2222 (Stream)\nActiveState=active", "Listen=0.0.0.0:2324 (Stream)\nActiveState=active"]
        with mock.patch.object(guard, "output_of", side_effect=["", *sockets]):
            self.assertEqual(guard.ssh_ports(), "2222、2324")

    def test_inactive_socket_does_not_override_daemon_ports(self):
        with mock.patch.object(guard, "output_of", side_effect=["", "Listen=[::]:22 (Stream)\nActiveState=inactive", "", "port 2324\n"]):
            self.assertEqual(guard.ssh_ports(), "2324")

    def test_configured_ports_fallback_and_unknown(self):
        with mock.patch.object(guard, "output_of", side_effect=["", "", "", "port 22\nlistenaddress [::]:2222\n"]):
            self.assertEqual(guard.ssh_ports(), "2222")
        with mock.patch.object(guard, "output_of", return_value=""):
            self.assertEqual(guard.ssh_ports(), "未知")

    def test_alert_fields_and_test_label(self):
        event = {"user": "root", "ip": "66.66.66.66", "count": 11, "time": NOW}
        message = guard.alert_message(CONFIG, event, "22、2324、23555")
        self.assertEqual(len(message.splitlines()), 7)
        for expected in ("🚨 SSH 爆破提醒", "• 服务器: VMISS-Tri & _node", "• 用户: root",
                         "• 来源 IP: 66.66.66.66", "• 失败次数：11", "• 端口：22、2324、23555", "• 时间: "):
            self.assertIn(expected, message)
        self.assertIn("（测试）", guard.alert_message(CONFIG, event, "22", testing=True))

    def test_config_is_never_executed(self):
        path = self.root / "config"
        values = dict(CONFIG, SERVER_NAME="$(touch injected) & node")
        path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
        self.assertEqual(guard.read_config(path), values)
        path.write_text(path.read_text(encoding="utf-8") + "TG_CHAT_ID=999\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            guard.read_config(path)
        self.assertFalse((self.root / "injected").exists())

    def test_network_errors_do_not_expose_tokens(self):
        opener = mock.Mock()
        opener.open.side_effect = OSError("https://api.telegram.org/bot123:TEST_token/sendMessage")
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(guard.urllib.request, "build_opener", return_value=opener), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertFalse(guard.send_telegram(CONFIG, "test & text"))
        self.assertEqual(output.getvalue() + errors.getvalue(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
