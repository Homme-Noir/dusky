import os
import re
import stat
import shutil
import tempfile
from pathlib import Path
from typing import Any

from python.frontend.core_types import BaseEngine

# Sentinel object to safely detect omitted defaults in overridden dict methods
_sentinel = object()

class BridgedStateDict(dict):
    """
    A bridged dictionary that prevents the TUI from marking optional parameters 
    as '[Missing]' and striking them out.
    
    Because kernel parameters are flags that are inherently 'optional' (their absence 
    just implies the kernel's default behavior), they should always be treated as 
    available and fully editable by the UI.
    """
    def __contains__(self, key: Any) -> bool:
        return True

    def __getitem__(self, key: Any) -> Any:
        return super().get(key, "unset")

    def get(self, key: Any, default: Any = _sentinel) -> Any:
        # Respect the caller's explicit default if provided, otherwise fallback to "unset"
        if default is _sentinel:
            return super().get(key, "unset")
        return super().get(key, default)


class CmdlineEngine(BaseEngine):
    """
    Bridged Intelligent engine for /etc/kernel/cmdline and similar kernel parameter files.
    
    Features:
    - Bridged State: Prevents optional parameters from rendering as missing/broken.
    - Type-Aware AST: Strictly separates boolean flags (rw) from KV pairs (root=xyz).
    - Token-Preservation: Uses regex to preserve the exact spacing and order of all arguments.
    - Sub-Key Mutability: Accurately parses and reassembles complex comma-separated values.
    - Duplicate Key Tracking: Properly indexes duplicate arguments.
    - Atomic Commits: Prevents corrupted states during power loss with full security context mirroring.
    """
    
    def __init__(self, config_path: str = "/etc/kernel/cmdline"):
        self.config_path = Path(config_path).expanduser().resolve()
        self.cache: BridgedStateDict = BridgedStateDict()
        self.file_mtime_ns: int = 0

    @property
    def target_path(self) -> str:
        return str(self.config_path)

    def load_state(self) -> dict[str, Any]:
        if not self.config_path.exists():
            return BridgedStateDict()

        self.cache = BridgedStateDict()
        
        try:
            with open(self.config_path, 'r', encoding='utf-8') as f:
                # Lock timestamp precision immediately after securing the file descriptor
                self.file_mtime_ns = os.fstat(f.fileno()).st_mtime_ns
                content = f.read().strip()
                
            # Advanced tokenization respecting single/double quotes
            tokens = re.split(r'((?:[^\s"\']|"[^"]*"|\'[^\']*\')+)', content)
            args = [t for t in tokens if t.strip()]
            counts: dict[str, int] = {}
            
            for arg in args:
                if "=" in arg:
                    k, v = arg.split("=", 1)
                else:
                    k, v = arg, "true"
                    
                counts[k] = counts.get(k, 0) + 1
                count = counts[k]
                
                if count == 1:
                    self.cache[f"DEFAULT/{k}"] = v
                self.cache[f"DEFAULT/{k}:{count}"] = v
                
                # Expose Sub-Keys for complex comma-separated values
                if "," in v and count == 1 and not (v.startswith('"') or v.startswith("'")):
                    sub_items = v.split(",")
                    for item in sub_items:
                        if "=" in item:
                            sk, sv = item.split("=", 1)
                            self.cache[f"DEFAULT/{k}.{sk}"] = sv
                        else:
                            self.cache[f"DEFAULT/{k}.{item}"] = "true"

        except OSError as e:
            print(f"Failed to read cmdline config {self.config_path}: {e}")
            
        return self.cache

    def write_value(self, target_key: str, target_scope: str, new_value: str, item_type: str = "string") -> tuple[bool, str, str]:
        return self.write_batch([(target_key, target_scope, new_value, item_type)])

    def write_batch(self, changes: list[tuple[str, str, str, str]]) -> tuple[bool, str, str]:
        if not changes:
            return True, "No pending changes.", ""

        content = ""
        if self.config_path.exists():
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    # Prevent TOCTOU modifications by verifying against the active file descriptor
                    current_mtime_ns = os.fstat(f.fileno()).st_mtime_ns
                    if current_mtime_ns > self.file_mtime_ns:
                        return False, f"File {self.config_path.name} modified externally. Reload required.", ""
                    content = f.read().strip().replace('\n', ' ')
            except OSError as e:
                return False, f"Failed to open config for verification: {e}", ""

        changes_dict = {(scope, key): (val, itype) for key, scope, val, itype in changes}
        applied_commits = set()
        
        try:
            tokens = re.split(r'((?:[^\s"\']|"[^"]*"|\'[^\']*\')+)', content)
            out_tokens: list[str] = []
            counts: dict[str, int] = {}
            
            for t in tokens:
                if not t.strip():
                    out_tokens.append(t)
                    continue
                    
                if "=" in t:
                    k, v = t.split("=", 1)
                else:
                    k, v = t, ""
                    
                counts[k] = counts.get(k, 0) + 1
                count = counts[k]
                
                lookup_exact = ("DEFAULT", f"{k}:{count}")
                lookup_base = ("DEFAULT", k)
                
                target_val = None
                target_itype = None
                matched_lookup = None
                
                # Check for absolute overrides first
                if lookup_exact in changes_dict:
                    target_val, target_itype = changes_dict[lookup_exact]
                    matched_lookup = lookup_exact
                elif count == 1 and lookup_base in changes_dict:
                    target_val, target_itype = changes_dict[lookup_base]
                    matched_lookup = lookup_base
                    
                if target_val is not None:
                    applied_commits.add(matched_lookup)
                    val_str = str(target_val)
                    val_lower = val_str.lower()
                    
                    if val_str in ("__DELETE__", "unset", "") or (target_itype == "bool" and val_lower == "false"):
                        # Safely collapse unbounded whitespace during deletion
                        if out_tokens and out_tokens[-1].isspace():
                            out_tokens.pop()
                    elif target_itype == "bool" and val_lower == "true":
                        out_tokens.append(k)
                    else:
                        out_tokens.append(f"{k}={val_str}")
                else:
                    # Check for sub-key modifications (e.g. rootflags.noatime)
                    matching_sub_keys = {}
                    for (c_scope, c_key), (c_val, c_itype) in changes_dict.items():
                        if c_scope != "DEFAULT":
                            continue
                        if c_key.startswith(f"{lookup_exact[1]}."):
                            matching_sub_keys[c_key.split(".", 1)[1]] = (c_key, c_val, c_itype)
                        elif count == 1 and c_key.startswith(f"{lookup_base[1]}."):
                            matching_sub_keys[c_key.split(".", 1)[1]] = (c_key, c_val, c_itype)
                            
                    if matching_sub_keys:
                        current_subs = {}
                        sub_order = []
                        
                        # Parse existing sub-keys safely
                        if v and not (v.startswith('"') or v.startswith("'")):
                            for item in v.split(','):
                                if not item: continue
                                sk, sv = item.split("=", 1) if "=" in item else (item, "true")
                                if sk not in current_subs:
                                    sub_order.append(sk)
                                current_subs[sk] = sv
                                
                        # Apply targeted sub-key changes in-place
                        for sk, (orig_c_key, c_val, c_itype) in matching_sub_keys.items():
                            val_str = str(c_val)
                            val_lower = val_str.lower()
                            applied_commits.add(("DEFAULT", orig_c_key))
                            
                            if val_str in ("__DELETE__", "unset", "") or (c_itype == "bool" and val_lower == "false"):
                                if sk in current_subs:
                                    del current_subs[sk]
                                    if sk in sub_order:
                                        sub_order.remove(sk)
                            else:
                                if sk not in current_subs:
                                    sub_order.append(sk)
                                current_subs[sk] = "true" if (c_itype == "bool" and val_lower == "true") else val_str
                                
                        # Reconstruct the token
                        if not current_subs:
                            if out_tokens and out_tokens[-1].isspace():
                                out_tokens.pop()
                        else:
                            new_v_parts = [sk if current_subs[sk] == "true" else f"{sk}={current_subs[sk]}" for sk in sub_order]
                            out_tokens.append(f"{k}={','.join(new_v_parts)}")
                    else:
                        out_tokens.append(t)
                        
            # Handle brand new keys (or complex sub-keys) appended to the end
            missing_changes = set(changes_dict.keys()) - applied_commits
            missing_structures: dict[str, dict[str, Any]] = {}
            
            for scope, key_raw in missing_changes:
                val, target_itype = changes_dict[(scope, key_raw)]
                val_str = str(val)
                val_lower = val_str.lower()
                
                if val_str in ("__DELETE__", "unset", "") or (target_itype == "bool" and val_lower == "false"):
                    continue
                    
                clean_key = key_raw.split(":")[0] if ":" in key_raw else key_raw
                
                # Route missing values to base parameter vs sub-keys
                if "." in clean_key:
                    base_k, sub_k = clean_key.split(".", 1)
                    if base_k not in missing_structures:
                        missing_structures[base_k] = {'val': None, 'itype': None, 'subs': {}}
                    missing_structures[base_k]['subs'][sub_k] = (val_str, target_itype)
                else:
                    base_k = clean_key
                    if base_k not in missing_structures:
                        missing_structures[base_k] = {'val': None, 'itype': None, 'subs': {}}
                    missing_structures[base_k]['val'] = val_str
                    missing_structures[base_k]['itype'] = target_itype
                    
                applied_commits.add((scope, key_raw))
                
            # Safely serialize unapplied constructs
            for base_k, struct in missing_structures.items():
                needs_space = False
                for tk in reversed(out_tokens):
                    if tk:
                        needs_space = bool(tk.strip())
                        break
                if needs_space:
                    out_tokens.append(" ")
                    
                if not struct['subs']:
                    if struct['itype'] == "bool" and struct['val'].lower() == "true":
                        out_tokens.append(base_k)
                    else:
                        out_tokens.append(f"{base_k}={struct['val']}")
                else:
                    v_parts = []
                    if struct['val'] is not None and struct['itype'] != "bool":
                        v_parts.append(struct['val'])
                        
                    for sk, (sv, s_itype) in struct['subs'].items():
                        v_parts.append(sk if (s_itype == "bool" and sv.lower() == "true") else f"{sk}={sv}")
                            
                    combined_v = ",".join(v_parts)
                    out_tokens.append(f"{base_k}={combined_v}" if combined_v else base_k)
                    
            final_content = "".join(out_tokens).strip() + "\n"
            
            # --- Safe Atomic File Commit with Security Context Preservation ---
            success = False
            status_msg = "Failed"
            temp_file_path = None
            
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode='w', delete=False, encoding='utf-8', dir=self.config_path.parent) as tf:
                temp_file_path = Path(tf.name)
                tf.write(final_content)
                
            if self.config_path.exists():
                try:
                    stat_info = self.config_path.stat()
                    shutil.copystat(self.config_path, temp_file_path)
                    os.chown(temp_file_path, stat_info.st_uid, stat_info.st_gid)
                except OSError: 
                    pass
                    
            os.replace(temp_file_path, self.config_path)
            
            # Immediately refresh the internal state tracking
            with open(self.config_path, 'r', encoding='utf-8') as f:
                self.file_mtime_ns = os.fstat(f.fileno()).st_mtime_ns
                
            success = True
            
        except OSError as e:
            return False, f"Atomic commit failed: {e}", ""
        finally:
            if 'temp_file_path' in locals() and temp_file_path and temp_file_path.exists() and not success:
                try: temp_file_path.unlink()
                except OSError: pass

        if success:
            return True, f"Successfully batched {len(applied_commits)} commits.", ""
            
        return False, status_msg, ""
