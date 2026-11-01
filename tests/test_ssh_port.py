"""Exercise the embedded port changer without modifying system files/services."""
import contextlib
import io
from pathlib import Path
import re
import shutil
import tempfile
import types
import unittest
from unittest import mock

SOURCE = (Path(__file__).resolve().parents[1] / "ssh-tg-notify.sh").read_text(encoding="utf-8")
PAYLOAD = SOURCE.split("    cat <<'PORT_TOOL_EOF'\n", 1)[1].split("\nPORT_TOOL_EOF\n", 1)[0]
ports = types.ModuleType("ssh_port_tool")
exec(compile(PAYLOAD, "embedded-port-tool.py", "exec"), ports.__dict__)


class FakeBackend:
    socket = None
    socket_bindings = set()

    def __init__(self):
        self.applied = 0
        self.verified = []

    def apply(self):
        self.applied += 1

    def verify(self, required, removed):
        self.verified.append((set(required), set(removed)))

    def socket_plan(self, *_args, **_kwargs):
        return {}


class PortTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config = self.root / "sshd_config"
        self.original = b"# SSH settings\nPort 22\nPermitRootLogin prohibit-password\n"
        self.config.write_bytes(self.original)
        self.backend = FakeBackend()
        self.output = io.StringIO()

    def tearDown(self):
        self.temporary.cleanup()

    def settings(self):
        selected = re.findall(r"^Port ([0-9]+)$", self.config.read_text(encoding="utf-8"), re.MULTILINE)
        return "".join(f"port {value}\nlistenaddress 0.0.0.0:{value}\n" for value in selected)

    def fake_run(self, arguments):
        if arguments[0] == "cp":
            shutil.copy2(arguments[-2], arguments[-1])
            return ""
        if arguments[0] == "fake-sshd":
            return self.settings() if "-T" in arguments else ""
        self.fail("Unexpected external command: " + repr(arguments))

    def change(self, answers, rows=None):
        if rows is None:
            rows = [("0.0.0.0", 22, True, False)]
        with mock.patch.object(ports, "run", side_effect=self.fake_run), \
                mock.patch.object(ports.shutil, "which", return_value="fake-sshd"), \
                mock.patch.object(ports, "SystemdBackend", return_value=self.backend), \
                mock.patch.object(ports, "listeners", return_value=rows), \
                contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            return ports.change(self.config, self.root / "backups", prompt=mock.Mock(side_effect=answers))

    def transaction(self):
        return ports.Transaction("fake-sshd", self.config, self.backend, self.root / "backups")

    def test_port_input_range_duplicates_and_separators(self):
        self.assertEqual(ports.parse_ports("0022,2324 23555 22"), [22, 2324, 23555])
        for value in ("", "0", "65536", "-1", "22x", "22; id", "$(id)", "2.2", "22\x00"):
            with self.assertRaises(ValueError, msg=value):
                ports.parse_ports(value)

    def test_main_and_global_includes_are_changed_without_auth_changes(self):
        included = self.root / "conf.d" / "provider.conf"
        included.parent.mkdir()
        included.write_bytes(b"Port 2324\nPasswordAuthentication no\n")
        self.config.write_bytes(b"Include conf.d/*.conf\nPort 22\nMatch User backup\n    ForceCommand internal-sftp\n")
        editor = ports.ConfigEditor(self.config, "port 22\nport 2324\n")
        plan = editor.plan({2222}, staged=False)
        self.assertIn(b"# ssh-tg-notify previous: Port 2324", plan[included])
        self.assertIn(b"PasswordAuthentication no\n", plan[included])
        self.assertIn(b"Port 2222\n", plan[self.config])
        self.assertIn(b"Match User backup\n    ForceCommand internal-sftp\n", plan[self.config])

    def test_listen_address_staging_preserves_each_old_address_port(self):
        self.config.write_text("Port 22\nListenAddress 127.0.0.1:2324\nListenAddress 192.0.2.1:22\nListenAddress [::1]:23555\n", encoding="utf-8")
        editor = ports.ConfigEditor(self.config, "port 22\n")
        plan = editor.plan({22, 2324, 23555, 2222}, staged=True, additions={2222})[self.config].decode()
        self.assertIn("ListenAddress 127.0.0.1:2324\n", plan)
        self.assertIn("ListenAddress 127.0.0.1:2222\n", plan)
        self.assertNotIn("ListenAddress 192.0.2.1:2324", plan)
        self.assertNotIn("ListenAddress 127.0.0.1:22\n", plan)
        self.assertIn("ListenAddress [::1]:23555\n", plan)
        final = editor.plan({2222}, staged=False)[self.config].decode()
        self.assertEqual(final.count("ListenAddress "), 3)
        self.assertNotIn(":23555", final)

    def test_bare_listen_addresses_and_rdomain(self):
        self.config.write_text("Port 22\nListenAddress ::\nListenAddress 192.0.2.1 rdomain 1\n", encoding="utf-8")
        editor = ports.ConfigEditor(self.config, "port 22\n")
        result = editor.plan({2222, 2324}, staged=False)[self.config].decode()
        self.assertIn("ListenAddress [::]:2222\n", result)
        self.assertIn("ListenAddress 192.0.2.1:2324 rdomain 1\n", result)

    def test_repeated_change_does_not_duplicate_managed_port_block(self):
        editor = ports.ConfigEditor(self.config, "port 22\n")
        self.config.write_bytes(editor.plan({2222}, staged=False)[self.config])
        editor = ports.ConfigEditor(self.config, "port 2222\n")
        changed = editor.plan({2324}, staged=False)[self.config].decode()
        self.assertEqual(changed.count(ports.BEGIN), 1)
        self.assertNotIn("Port 2222\n", changed)
        self.assertEqual(re.findall(r"^Port (\d+)$", changed, re.MULTILINE), ["2324"])

    def test_unrelated_crlf_lines_are_preserved_byte_for_byte(self):
        self.config.write_bytes(b"Port 22\r\n# keep this comment\r\nPasswordAuthentication no\r\n")
        editor = ports.ConfigEditor(self.config, "port 22\n")
        result = editor.plan({2222}, staged=False)[self.config]
        self.assertIn(b"# keep this comment\r\nPasswordAuthentication no\r\n", result)

    def test_damaged_managed_block_is_rejected(self):
        for content in (ports.BEGIN + "\nPort 22\n", ports.END + "\n",
                        ports.BEGIN + "\nPasswordAuthentication yes\n" + ports.END + "\n"):
            with self.assertRaises(ValueError):
                ports.strip_port_block(content)

    def test_include_loop_and_external_include_are_rejected(self):
        self.config.write_text("Include sshd_config\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ports.ConfigEditor(self.config, "port 22\n")
        outside = self.root.parent / "outside-ssh.conf"
        self.config.write_text("Include " + outside.as_posix() + "\n", encoding="utf-8")
        with mock.patch.object(ports.glob, "glob", return_value=[str(outside)]), self.assertRaises(ValueError):
            ports.ConfigEditor(self.config, "port 22\n")

    def test_successful_change_has_two_phases_and_persistent_backups(self):
        self.change(["2222", "yes"])
        self.assertEqual(self.backend.verified, [({22, 2222}, set()), ({2222}, {22})])
        self.assertEqual(self.backend.applied, 2)
        self.assertEqual(ports.effective_ports(self.settings()), {2222})
        backups = list((self.root / "backups").rglob("manifest.json"))
        self.assertEqual(len(backups), 2)
        self.assertTrue(any(path.read_bytes() == self.original for path in (self.root / "backups").rglob("0")))

    def test_decline_or_eof_keeps_both_ports(self):
        for response in ("no", EOFError()):
            self.config.write_bytes(self.original)
            self.backend = FakeBackend()
            self.change(["2222", response])
            self.assertEqual(ports.effective_ports(self.settings()), {22, 2222})
            self.assertEqual(self.backend.applied, 1)

    def test_cancel_and_same_port_make_no_backup_or_reload(self):
        for answer in ("", "22", EOFError()):
            self.change([answer])
            self.assertEqual(self.config.read_bytes(), self.original)
            self.assertEqual(self.backend.applied, 0)
            self.assertFalse((self.root / "backups").exists())

    def test_occupied_port_is_rejected_before_any_write(self):
        with self.assertRaises(ValueError):
            self.change(["2222"], [("0.0.0.0", 22, True, False), ("0.0.0.0", 2222, False, False)])
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.backend.applied, 0)

    def test_validation_failure_restores_files_without_reloading(self):
        real = self.fake_run
        def invalid(arguments):
            if arguments[0] == "fake-sshd" and "-t" in arguments:
                raise RuntimeError("invalid candidate")
            return real(arguments)
        with mock.patch.object(ports, "run", side_effect=invalid), contextlib.redirect_stderr(self.output):
            transaction = self.transaction()
            with self.assertRaises(RuntimeError):
                transaction.apply({self.config: b"Port 2222\n"}, {2222})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.backend.applied, 0)

    def test_reload_failure_restores_and_reloads_original(self):
        self.backend.apply = mock.Mock(side_effect=[RuntimeError("reload failed"), None])
        with mock.patch.object(ports, "run", side_effect=self.fake_run), contextlib.redirect_stderr(self.output):
            with self.assertRaises(RuntimeError):
                self.transaction().apply({self.config: b"Port 2222\n"}, {2222})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.backend.apply.call_count, 2)

    def test_not_listening_rolls_back_to_last_working_phase(self):
        self.backend.verify = mock.Mock(side_effect=[None, RuntimeError("no listener"), None])
        with self.assertRaises(RuntimeError):
            self.change(["2222", "yes"])
        self.assertEqual(ports.effective_ports(self.settings()), {22, 2222})
        self.assertEqual(self.backend.applied, 3)
        self.assertEqual(self.backend.verify.call_args, mock.call({22, 2222}, ()))

    def test_interruption_during_reload_restores_original_configuration(self):
        self.backend.apply = mock.Mock(side_effect=[KeyboardInterrupt(), None])
        with mock.patch.object(ports, "run", side_effect=self.fake_run), contextlib.redirect_stderr(self.output):
            with self.assertRaises(KeyboardInterrupt):
                self.transaction().apply({self.config: b"Port 2222\n"}, {2222})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.backend.apply.call_count, 2)

    def test_effective_config_mismatch_is_rejected(self):
        with mock.patch.object(ports, "run", side_effect=self.fake_run), contextlib.redirect_stderr(self.output):
            with self.assertRaises(RuntimeError):
                self.transaction().apply({self.config: b"Port 22\nPort 2222\n"}, {2222})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.backend.applied, 0)

    def test_new_socket_dropin_is_removed_on_failure(self):
        dropin = self.root / "ssh.socket.d" / "ports.conf"
        self.backend.apply = mock.Mock(side_effect=[RuntimeError("restart failed"), None])
        with mock.patch.object(ports, "run", side_effect=self.fake_run), contextlib.redirect_stderr(self.output):
            with self.assertRaises(RuntimeError):
                self.transaction().apply({self.config: b"Port 2222\n", dropin: b"[Socket]\nListenStream=2222\n"}, {2222})
        self.assertFalse(dropin.exists())
        self.assertEqual(self.config.read_bytes(), self.original)

    def backend_info(self, socket=False, kill_mode="process", custom=""):
        service = {"Id": "ssh.service", "ActiveState": "active", "CanReload": "yes", "KillMode": kill_mode,
                   "ExecStart": "/usr/sbin/sshd -D " + custom, "MainPID": "0"}
        socket_info = {"Id": "ssh.socket", "ActiveState": "active" if socket else "inactive", "Accept": "no",
                       "Triggers": "ssh.service", "Listen": "127.0.0.1:22 (Stream) [::1]:2324 (Stream)"}
        return lambda name: socket_info if name.endswith(".socket") else service

    def test_service_mode_uses_reload_only(self):
        with mock.patch.object(ports.SystemdBackend, "info", side_effect=self.backend_info()), \
                mock.patch.object(ports, "run") as execute:
            backend = ports.SystemdBackend(defaults_paths=())
            backend.apply()
        execute.assert_called_once_with(["systemctl", "reload", "ssh.service"])

    def test_socket_mode_preserves_addresses_and_old_bindings_during_staging(self):
        with mock.patch.object(ports.SystemdBackend, "info", side_effect=self.backend_info(socket=True)):
            backend = ports.SystemdBackend(defaults_paths=())
        backend.dropin = self.root / "ports.conf"
        text = backend.socket_plan({22, 2324, 2222}, True, additions={2222})[backend.dropin].decode()
        self.assertIn("ListenStream=\n", text)
        self.assertIn("ListenStream=127.0.0.1:2222\n", text)
        self.assertNotIn("ListenStream=127.0.0.1:2324", text)
        self.assertNotIn("ListenStream=[::1]:22\n", text)
        self.assertIn("ListenStream=[::1]:2324\n", text)
        final = backend.socket_plan({2222}, False)[backend.dropin].decode()
        self.assertEqual(final.count("ListenStream="), 3)
        self.assertNotIn(":2324", final)

    def test_socket_mode_with_session_killing_service_is_rejected(self):
        with mock.patch.object(ports.SystemdBackend, "info", side_effect=self.backend_info(socket=True, kill_mode="control-group")), \
                self.assertRaises(ValueError):
            ports.SystemdBackend(defaults_paths=())

    def test_custom_command_line_configuration_is_rejected(self):
        for option in ("-p2222", "-f /custom/sshd_config", "-frelative_config", "-oPort=2222"):
            with mock.patch.object(ports.SystemdBackend, "info", side_effect=self.backend_info(custom=option)), \
                    self.assertRaises(ValueError, msg=option):
                ports.SystemdBackend(defaults_paths=())

    def test_listener_verification_checks_ssh_owner_and_removed_ports(self):
        with mock.patch.object(ports.SystemdBackend, "info", side_effect=self.backend_info()):
            backend = ports.SystemdBackend(defaults_paths=())
        with mock.patch.object(ports, "listeners", return_value=[("0.0.0.0", 2222, True, False)]):
            backend.verify({2222}, {22})
        with mock.patch.object(ports, "listeners", return_value=[("0.0.0.0", 2222, False, False)]), \
                mock.patch.object(ports.time, "sleep"), self.assertRaises(RuntimeError):
            backend.verify({2222}, {22})

    def test_ss_parser_handles_ipv4_ipv6_and_socket_owners(self):
        output = 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'
        output += 'LISTEN 0 128 [::]:2222 [::]:* users:(("systemd",pid=1,fd=4))\n'
        with mock.patch.object(ports, "run", return_value=output):
            self.assertEqual(ports.listeners(), [("0.0.0.0", 22, True, False), ("::", 2222, False, True)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
