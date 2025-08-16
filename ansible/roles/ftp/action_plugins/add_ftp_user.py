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

from ansible.plugins.action import ActionBase
from ansible.module_utils._text import to_text
import os
import subprocess

try:
    import mysql.connector
    HAS_MYSQL = True
except ImportError:
    HAS_MYSQL = False

class ActionModule(ActionBase):
    def run(self, tmp=None, task_vars=None):
        if not HAS_MYSQL:
            return {'failed': True, 'msg': 'Missing python mysql.connector module'}

        result = super().run(tmp, task_vars)
        args = self._task.args

        required = ['ftp_vuser', 'ftp_vpass', 'webroot']
        missing = [k for k in required if k not in args]
        if missing:
            result['failed'] = True
            result['msg'] = f"Missing required arguments: {', '.join(missing)}"
            return result

        ftp_vuser = args['ftp_vuser']
        ftp_vpass = args['ftp_vpass']
        webroot = args['webroot']
        template_path = args.get('template', 'conf/vsftpd_user.conf')

        guest_user = 'www-data'
        config_path = args.get('ftp_config')
        if not config_path:
            config_path = os.path.join(os.path.dirname(__file__), '..', 'conf', 'ftp.conf')
        config = self.load_config(config_path)

        ftp_db = config.get('FTP_DB')
        ftp_users_dir = config.get('FTP_USERS_DIR')

        if not ftp_db or not ftp_users_dir:
            result['failed'] = True
            result['msg'] = f"Missing FTP_DB or FTP_USERS_DIR in config file: {config_path}"
            return result

        try:
            hashed = self.hash_password(ftp_vpass)
            self.insert_user(ftp_db, ftp_vuser, hashed)
            self.configure_user_root(webroot, ftp_vuser, ftp_users_dir, guest_user, template_path)
            result['changed'] = True
            result['msg'] = f"FTP user '{ftp_vuser}' created and configured."
        except Exception as e:
            result['failed'] = True
            result['msg'] = f"Error: {to_text(e)}"

        return result

    def load_config(self, path):
        config = {}
        if not os.path.isfile(path):
            return config
        with open(path) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    key, val = line.split('=', 1)
                    config[key.strip()] = val.strip()
        return config

    def hash_password(self, plain):
        salt = subprocess.check_output(['openssl', 'rand', '-base64', '12']).decode().strip().replace('/', '.').replace('+', '_')
        hashed = subprocess.check_output(['openssl', 'passwd', '-6', '-salt', salt, plain]).decode().strip()
        return hashed

    def insert_user(self, db_name, username, hashed):
        conn = mysql.connector.connect(database=db_name)
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO users (username, password, active)
            VALUES (%s, %s, 1)
            ON DUPLICATE KEY UPDATE password=VALUES(password), active=1;
        """, (username, hashed))
        conn.commit()
        cursor.close()
        conn.close()

    def configure_user_root(self, webroot, username, ftp_users_dir, guest_user, template_filename, task_vars):
        os.makedirs(webroot, exist_ok=True)
        os.chown(webroot, self.get_uid(guest_user), self.get_gid(guest_user))

        template_args = {
            "src": os.path.join(self._TEMPLATES_DIR, template_filename),
            "dest": os.path.join(ftp_users_dir, username),
            "owner": username,
            "group": username,
            "mode": "0644",
        }

        template_task = self._task.copy()
        template_task.args = template_args

        template_action = self._shared_loader_obj.action_loader.get(
            "ansible.legacy.template",
            task=template_task,
            connection=self._connection,
            play_context=self._play_context,
            loader=self._loader,
            templar=self._templar,
            shared_loader_obj=self._shared_loader_obj,
        )
        result = template_action.run(task_vars=task_vars)
        return result


    def get_uid(self, user):
        import pwd
        return pwd.getpwnam(user).pw_uid

    def get_gid(self, user):
        import pwd
        return pwd.getpwnam(user).pw_gid
