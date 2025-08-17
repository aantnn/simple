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

class ActionModule(ActionBase):
    """Provision FTP user row + webroot + vsftpd config in one go."""

    def _ensure_invocation(self, result):
        if 'invocation' not in result:
            if self._task.no_log:
                result['invocation'] = "CENSORED: no_log is set"
            else:
                result['invocation'] = self._task.args.copy()
                result['invocation']['module_args'] = self._task.args.copy()
        return result

    def _gen_hash(self, plain: str) -> str:
        alphabet = string.ascii_letters + string.digits + '._'
        salt = ''.join(secrets.choice(alphabet) for _ in range(12))
        digest = hashlib.sha512((salt + plain).encode()).digest()
        return f"$6${salt}${base64.b64encode(digest).decode()}"

    def _mysql_query(self, task_vars, **kwargs):
        return self._execute_module(
            module_name='community.mysql.mysql_query',
            module_args=kwargs,
            task_vars=task_vars
        )

    def _ensure_dir(self, task_vars, path, owner, group, mode):
        return self._execute_module(
            module_name='ansible.builtin.file',
            module_args=dict(path=path, state='directory', owner=owner, group=group, mode=mode),
            task_vars=task_vars
        )

    def _copy_file(self, task_vars, dest, content, owner, group, mode):
        return self._execute_module(
            module_name='ansible.builtin.copy',
            module_args=dict(dest=dest, content=content, owner=owner, group=group, mode=mode),
            task_vars=task_vars
        )

    def _template(self, task_vars, src, dest, owner, group, mode, extra_vars):
        return self._execute_module(
            module_name='ansible.builtin.template',
            module_args=dict(src=src, dest=dest, owner=owner, group=group, mode=mode),
            task_vars={**task_vars, **extra_vars}
        )
    VAR_PATTERNS = {
        'ftp_guest_user': re.compile(r'^\s*(?:guest_username|ftp_username|chown_username)\s*=\s*(\S+)', re.MULTILINE),
        'ftp_users_dir': re.compile(r'^\s*user_config_dir\s*=\s*(\S+)', re.MULTILINE),
        'pam_service_name': re.compile(r'^\s*pam_service_name\s*=\s*(\S+)', re.MULTILINE),
    }

    PAM_PATTERNS = {
        'db_login_user': re.compile(r'\buser=([^\s]+)'),
        'db_login_password': re.compile(r'\bpasswd=([^\s]+)'),
        'db_name': re.compile(r'\bdb=([^\s]+)'),
        'db_host': re.compile(r'\bhost=([^\s]+)')
    }

    def _read_remote_file(self, task_vars, path):
        res = self._execute_module(
            module_name='ansible.builtin.slurp',
            module_args={'src': path},
            task_vars=task_vars
        )
        if res.get('failed'):
            raise AnsibleActionFail(f"Unable to read {path}: {res}")
        return base64.b64decode(res['content']).decode('utf-8', errors='replace')
    def _parse_vars(self, text, patterns):
        out = {}
        for key, pat in patterns.items():
            m = pat.search(text)
            if m:
                out[key] = m.group(1)
        return out

    def run(self, tmp=None, task_vars=None):
        result = super(ActionModule, self).run(tmp, task_vars)
        args = self._task.args
        del tmp
        required = [
            'username', 'password', 'webroot', 'state'
        ]
        missing = [r for r in required if r not in args]
        if missing:
            self._ensure_invocation(result)
            raise AnsibleActionFail(f"Missing required args: {', '.join(missing)}")

        """Read database credential values from the configuration files"""
        vsftpd_conf = self._read_remote_file(task_vars, '/etc/vsftpd.conf')
        conf_vars = self._parse_vars(vsftpd_conf, self.VAR_PATTERNS)
        del vsftpd_conf
        pam_conf = self._read_remote_file(task_vars, f"/etc/pam.d/{conf_vars['pam_service_name']}")
        pam_vars = self._parse_vars(pam_conf, self.PAM_PATTERNS)
        del pam_conf
        conf_vars.update(pam_vars)
        del pam_vars
        try:
            # 1. Generate salted SHA‑512 hash
            hashed = self._gen_hash(args.get('password'))

            # 2. Insert/update DB row
            exec_result = self._mysql_query(
                task_vars,
                login_db=conf_vars.get('db_name'),
                login_user=conf_vars.get('db_login_user'),
                login_password=conf_vars.get('db_login_password'),
                login_host=conf_vars.get('db_host'),
                query=f"""
                INSERT INTO users (username, password, active)
                VALUES ('{args.get('username')}', '{hashed}', 1)
                ON DUPLICATE KEY UPDATE password=VALUES(password), active=1;
                """
            )
            result.update(exec_result)
            if result.get('failed'):
                raise AnsibleActionFail(message=result.get('msg'), result=result)

            # 3. Ensure webroot exists
            webroot = args.get('webroot')
            self._ensure_dir(task_vars, webroot, conf_vars.get('ftp_guest_user'), conf_vars.get('ftp_guest_user'), '0755')

            # 5. Deploy vsftpd per‑user config
            config_content = f"""
            local_root={webroot}
            write_enable=YES
            """
            self._copy_file(
                task_vars,
                dest=f"{conf_vars.get('ftp_users_dir')}/{args.get('username')}",
                content=config_content,
                owner='root',
                group='root',
                mode='0644')
            result.update(changed=True, msg=f"FTP user {args.get('username')} created/updated with webroot: {webroot}")
        except Exception as e:
                self._ensure_invocation(result)
                result.update(failed=True, msg=result.get('msg'))
                raise AnsibleActionFail(message=result.get('msg'), result=result)

        # Ensure invocation is always present and scrubbed
        self._ensure_invocation(result)
        return result
