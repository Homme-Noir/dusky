import os
import shutil
import subprocess
from typing import Any
from python.frontend.core_types import BaseEngine

class SystemdEngine(BaseEngine):
    """
    A unified Systemd backend engine for the Dusky TUI Ecosystem.
    Dynamically routes between systemctl --user, pkexec, and sudo.
    Hardened against TTY hangs and Polkit failures.
    """

    def __init__(self, config_path: str = ""):
        self._target_path = "/etc/systemd/system"
        self._sys_auth_prefix = self._determine_auth_method()

    def _determine_auth_method(self) -> list[str]:
        """Critically evaluates the safest privilege escalation method."""
        # 1. Non-interactive check (Catches NOPASSWD visudo or active sudo tickets)
        try:
            if subprocess.run(["sudo", "-n", "true"], capture_output=True, stdin=subprocess.DEVNULL, timeout=2).returncode == 0:
                return ["sudo"]
        except Exception:
            pass

        # 2. GUI Polkit (Best for Wayland/X11)
        has_display = bool(os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY"))
        if has_display and shutil.which("pkexec"):
            return ["pkexec"]

        # 3. Safe Fallback 
        return ["sudo"]

    @property
    def target_path(self) -> str:
        return self._target_path

    def _fetch_units(self, scope: str, list_cmd: str, state_filter: str = "") -> set:
        """Optimized fetcher querying both services and timers in a single subprocess."""
        cmd = ["systemctl", list_cmd, "--type=service,timer", "--no-pager", "--no-legend"]
        if scope == "user":
            cmd.insert(1, "--user")
        if state_filter:
            cmd.extend(["--state", state_filter])
            
        try:
            # stdin=DEVNULL ensures background commands NEVER hang the parser waiting for TTY auth
            res = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=5)
            return {line.split()[0] for line in res.stdout.splitlines() if line}
        except Exception:
            return set()

    def load_state(self) -> dict[str, Any]:
        state = {}
        for scope in ["user", "system"]:
            installed = self._fetch_units(scope, "list-unit-files")
            active = self._fetch_units(scope, "list-units", "active")
            for unit in installed:
                state[f"{scope}/{unit}"] = "true" if unit in active else "false"
        return state

    def write_value(self, target_key: str, target_scope: str, new_value: str, item_type: str = "bool") -> tuple[bool, str, str]:
        action = "enable" if new_value == "true" else "disable"
        
        cmd = ["systemctl"]
        if target_scope == "user":
            cmd.insert(1, "--user")
        else:
            cmd = self._sys_auth_prefix + ["systemctl"]

        cmd.extend([action, "--now", target_key])

        try:
            # 15s timeout protects against dead GUI polkit agents
            res = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=15)
            if res.returncode == 0:
                return True, f"{action.capitalize()}d {target_key}", res.stdout
            else:
                err_msg = res.stderr.strip()
                if not err_msg or "polkit" in err_msg.lower() or "terminal is required" in err_msg.lower():
                    err_msg = "Authentication failed (No GUI Polkit agent running?)."
                return False, f"Failed: {err_msg}", res.stderr
        except subprocess.TimeoutExpired:
            return False, "Failed: Action timed out (Polkit agent hung?)", ""
        except Exception as e:
            return False, f"Execution Error: {str(e)}", str(e)

    def write_batch(self, changes: list[tuple[str, str, str, str]]) -> tuple[bool, str, str]:
        user_enable, user_disable = [], []
        sys_enable, sys_disable = [], []
        
        for key, scope, val_str, _ in changes:
            if scope == "user":
                if val_str == "true": user_enable.append(key)
                else: user_disable.append(key)
            else:
                if val_str == "true": sys_enable.append(key)
                else: sys_disable.append(key)
        
        success_count = 0
        err_msgs = []
        debug_logs = []
        
        def _run_batch_cmd(scope: str, action: str, units: list[str]) -> tuple[bool, str, str]:
            if not units: return True, "", ""
            
            if scope == "user":
                cmd = ["systemctl", "--user"]
            else:
                cmd = self._sys_auth_prefix + ["systemctl"]
                
            cmd.extend([action, "--now"])
            cmd.extend(units)
            
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=20)
                if res.returncode == 0: return True, "", res.stdout
                
                err_msg = res.stderr.strip()
                if not err_msg or "polkit" in err_msg.lower() or "terminal is required" in err_msg.lower():
                    err_msg = "Auth failed (No GUI agent)."
                return False, err_msg, res.stderr
            except subprocess.TimeoutExpired:
                return False, "Action timed out", ""
            except Exception as e:
                return False, str(e), str(e)

        transactions = [
            ("user", "enable", user_enable),
            ("user", "disable", user_disable),
            ("system", "enable", sys_enable),
            ("system", "disable", sys_disable)
        ]
        
        for scope, action, units in transactions:
            if units:
                ok, err, dbg = _run_batch_cmd(scope, action, units)
                if ok:
                    success_count += len(units)
                else:
                    err_msgs.append(f"{scope} {action} failed: {err}")
                debug_logs.append(dbg)
        
        if success_count == len(changes):
            return True, f"Batched {success_count} systemd states seamlessly.", "\n".join(debug_logs)
        elif success_count > 0:
            return False, f"Partial success. Errors: {' | '.join(err_msgs)}", "\n".join(debug_logs)
        else:
            return False, f"Batch failed: {' | '.join(err_msgs)}", "\n".join(debug_logs)
