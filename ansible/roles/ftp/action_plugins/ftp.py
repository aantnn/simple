"""
# How to call modules from another
    module_return = self._execute_module(module_name='ansible.legacy.copy', module_args=new_module_args, task_vars=task_vars) -  https://github.com/ansible/ansible/blob/0467e1eaa930dbe885192579d829d38f2d9d2f2c/lib/ansible/plugins/action/copy.py#L343

ActionBase._execute_module
└── ActionBase._configure_module
    └── PluginLoader.find_plugin_with_context
        └── PluginLoader._resolve_plugin_step  / legacy https://github.com/ansible/ansible/blob/0467e1eaa930dbe885192579d829d38f2d9d2f2c/lib/ansible/plugins/action/__init__.py#L298
            └── PluginLoader._find_plugin_by_fqcr
                └── AnsibleCollectionRef.from_fqcr
"""

import re
from ansible.plugins.action import ActionBase
from ansible.errors import AnsibleError, AnsibleActionFail
from ansible.module_utils._text import to_text
import secrets, string, hashlib, base64


SENSITIVE_KEY_PAT = re.compile(
    r"(pass|password|passwd|secret|token|key|api[_-]?key|auth|authorization|cookie|content|query|queries)$",
    re.IGNORECASE,
)


def _safe_identifier(s: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", s):
        raise AnsibleActionFail(message="Invalid username")
    return s


def _safe_sql_literal(s: str) -> str:
    return s.replace("'", "''")


class ActionModule(ActionBase):
    """Provision FTP user row + webroot + vsftpd config in one go."""

    def run(self, tmp=None, task_vars=None):
        result = super(ActionModule, self).run(tmp, task_vars)
        del tmp
        args = self._task.args

        try:
            self._validate_required_args(args, result)
            conf_vars = self._gather_configuration_vars(task_vars, result)
           

            changed = False
            changed |= self._update_ftp_user_cred_in_database(
                args, conf_vars, task_vars, result
            )
            changed |= self._ensure_webroot_directory(
                args, conf_vars, task_vars, result
            )
            changed |= self._create_vsftpd_user_config_file(
                args, conf_vars, task_vars, result
            )

            result.update(
                changed=changed,
                msg=f"FTP user {args['username']} created/updated with webroot: {args['webroot']}",
            )

        except AnsibleActionFail as ex:
            result.setdefault("failed", True)
            result.setdefault("msg", ex.message)
            self._ensure_invocation(result)
        except Exception as ex:
            result.setdefault("failed", True)
            import traceback; 
            tr = traceback.format_exc()
            result.setdefault("msg", f"Unhandled error in action plugin {tr}")
            self._ensure_invocation(result)
            raise AnsibleActionFail(message=result["msg"], result=result, orig_exc=ex)

        self._ensure_invocation(result)
        return result
    
    VAR_PATTERNS = {
        "ftp_guest_user": re.compile(
            r"^\s*(?:guest_username|ftp_username|chown_username)\s*=\s*(\S+)",
            re.MULTILINE,
        ),
        "ftp_users_dir": re.compile(r"^\s*user_config_dir\s*=\s*(\S+)", re.MULTILINE),
        "pam_service_name": re.compile(
            r"^\s*pam_service_name\s*=\s*(\S+)", re.MULTILINE
        ),
    }

    PAM_PATTERNS = {
        "db_login_user": re.compile(r"\buser=([^\s]+)"),
        "db_login_password": re.compile(r"\bpasswd=([^\s]+)"),
        "db_name": re.compile(r"\bdb=([^\s]+)"),
        "db_host": re.compile(r"\bhost=([^\s]+)"),
    }

    def _ensure_invocation(self, result):
        if self._task.no_log:
            result["invocation"] = "CENSORED: no_log is set"
            return result

        result["invocation"] = self._task.args.copy()
        result["invocation"]["module_args"] = self._task.args.copy()

        invocation = result["invocation"]
        module_args = result["invocation"]["module_args"]

        for key, value in invocation.items():
            if SENSITIVE_KEY_PAT.search(str(key)):
                invocation[key] = f"CENSORED: {key} is a no_log parameter"
                if key in module_args:
                    module_args[key] = "VALUE_SPECIFIED_IN_NO_LOG_PARAMETER"

        for k, v in result.items():
            if SENSITIVE_KEY_PAT.search(str(k)):
                result[k] = "VALUE_SPECIFIED_IN_NO_LOG_PARAMETER"
        return result

    def _gen_hash(self, plain: str) -> str:
        alphabet = string.ascii_letters + string.digits + "._"
        salt = "".join(secrets.choice(alphabet) for _ in range(12))
        digest = hashlib.sha512((salt + plain).encode()).digest()
        return f"$6${salt}${base64.b64encode(digest).decode()}"

    def _mysql_query(self, task_vars, **kwargs):
        return self._execute_module(
            module_name="community.mysql.mysql_query",
            module_args=kwargs,
            task_vars=task_vars,
        )

    def _ensure_dir(self, task_vars, path, owner, group, mode):
        return self._execute_module(
            module_name="ansible.builtin.file",
            module_args=dict(
                path=path, state="directory", owner=owner, group=group, mode=mode
            ),
            task_vars=task_vars,
        )

    def _copy_file(self, task_vars, dest, content, owner, group, mode):
        # Build the args dict exactly like a normal task would see them
        copy_args = dict(
            dest=dest, content=content, owner=owner, group=group, mode=mode
        )
        copy_task = self._task.copy()
        copy_task.args = copy_args

        # Delegate to the actual copy ActionModule implementation
        return self._shared_loader_obj.action_loader.get(
            "ansible.builtin.copy",
            task=copy_task,
            connection=self._connection,
            play_context=self._play_context,
            loader=self._loader,
            templar=self._templar,
            shared_loader_obj=self._shared_loader_obj,
        ).run(task_vars=task_vars)

    def _read_remote_file(self, task_vars, path, result: dict):
        res = self._execute_module(
            module_name="ansible.builtin.slurp",
            module_args={"src": path},
            task_vars=task_vars,
        )
        result.update(res)
        if res.get("failed"):
            raise AnsibleActionFail(
                message=f"ansible.builtin.slurp: {result.get("msg")}",
                orig_exc=result.get("exception"),
                result=result,
            )
        return base64.b64decode(res["content"]).decode("utf-8", errors="replace")

    def _parse_vars(self, text, patterns):
        out = {}
        for key, pat in patterns.items():
            m = pat.search(text)
            if m:
                out[key] = m.group(1)
            else:
                raise ConfigVarMissingError(key)
        return out

   

    def _validate_required_args(self, args, result):
        """Validate that all required arguments are present."""
        required = ["username", "password", "webroot", "state"]
        missing = [r for r in required if r not in args]
        if missing:
            self._ensure_invocation(result)
            raise AnsibleActionFail(
                message=f"Missing required args: {', '.join(missing)}"
            )

    def _gather_configuration_vars(self, task_vars, result):
        """Collect all necessary configuration variables from system files."""

        vsftpd_conf = self._read_remote_file(task_vars, "/etc/vsftpd.conf", result)
        conf_vars = self._parse_vars(vsftpd_conf, self.VAR_PATTERNS)
        pam_conf = self._read_remote_file(
            task_vars, f"/etc/pam.d/{conf_vars['pam_service_name']}", result
        )
        pam_vars = self._parse_vars(pam_conf, self.PAM_PATTERNS)
        conf_vars.update(pam_vars)
        return conf_vars

    def _update_ftp_user_cred_in_database(
        self, args, conf_vars, task_vars, result: dict
    ):
        """Update or create the FTP user in the database."""
        hashed = self._gen_hash(args["password"])
        uname = _safe_identifier(args["username"])

        q = (
            "INSERT INTO users (username, password, active) "
            f"VALUES ('{_safe_sql_literal(uname)}','{_safe_sql_literal(hashed)}',1) "
            "ON DUPLICATE KEY UPDATE password=VALUES(password), active=1;"
        )

        exec_result = self._mysql_query(
            task_vars,
            login_db=conf_vars["db_name"],
            login_user=conf_vars["db_login_user"],
            login_password=conf_vars["db_login_password"],
            login_host=conf_vars["db_host"],
            query=q,
        )

        if exec_result.get("failed"):
            result.update(exec_result)
            raise AnsibleActionFail(
                message=result.get("msg"),
                orig_exc=result.get("exception"),
                result=result,
            )

        return exec_result.get("changed", False)

    def _ensure_webroot_directory(self, args, conf_vars, task_vars, result):
        """Ensure the webroot directory exists with correct permissions."""
        exec_result = self._ensure_dir(
            task_vars,
            args["webroot"],
            conf_vars["ftp_guest_user"],
            conf_vars["ftp_guest_user"],
            "0755",
        )

        if exec_result.get("failed"):
            result.update(exec_result)
            raise AnsibleActionFail(
                message=result.get("msg"),
                orig_exc=result.get("exception"),
                result=result,
            )

        return exec_result.get("changed", False)

    def _create_vsftpd_user_config_file(self, args, conf_vars, task_vars, result):
        """Create the user-specific vsftpd configuration file."""
        config_content = f"local_root={args['webroot']}\nwrite_enable=YES\n"
        uname = _safe_identifier(args["username"])

        copy_task = self._task.copy()
        copy_task.args = dict(
            dest=f"{conf_vars['ftp_users_dir']}/{uname}",
            content=config_content,
            owner=conf_vars["ftp_guest_user"],
            group=conf_vars["ftp_guest_user"],
            mode="0644",
        )
        copy_task.no_log = True  # extra safety

        exec_result = self._shared_loader_obj.action_loader.get(
            "ansible.builtin.copy",
            task=copy_task,
            connection=self._connection,
            play_context=self._play_context,
            loader=self._loader,
            templar=self._templar,
            shared_loader_obj=self._shared_loader_obj,
        ).run(task_vars=task_vars)

        if exec_result.get("failed"):
            result.update(exec_result)
            raise AnsibleActionFail(
                message=result.get("msg"),
                orig_exc=result.get("exception"),
                result=result,
            )

        return exec_result.get("changed", False)


class ConfigVarMissingError(AnsibleActionFail):
    ERROR_DESCRIPTIONS = {
        "ftp_guest_user": ("Missing 'guest_username' in /etc/vsftpd.conf."),
        "ftp_users_dir": (
            "Missing 'user_config_dir' in /etc/vsftpd.conf. "
            "Prevents configuration from being deployed for the new FTP account."
        ),
        "pam_service_name": (
            "Missing 'pam_service_name' in /etc/vsftpd.conf. "
            "This specifies the PAM service file in /etc/pam.d/ that controls authentication "
            "for FTP logins. Without it, the plugin cannot locate and parse the associated "
            "PAM configuration to extract database login credentials."
        ),
        "db_login_user": ("No 'user=<username>' found in PAM configuration. "),
        "db_login_password": ("No 'passwd=<password>' found in PAM configuration. "),
        "db_name": ("No 'db=<name>' found in PAM configuration. "),
        "db_host": ("No 'host=<hostname|IP>' found in PAM configuration. "),
    }
    """Raised when a required configuration variable is missing or invalid."""

    def __init__(self, key: str, *, source: str = None):
        # Base message from mapping, or a fallback
        message = self.ERROR_DESCRIPTIONS.get(
            key, f"Missing or invalid configuration value for '{key}'"
        )
        # Optionally append source file info
        if source:
            message = f"{message} (source: {source})"

        super().__init__(message=message)
        self.key = key
        self.source = source
