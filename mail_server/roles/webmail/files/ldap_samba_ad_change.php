<?php

/**
 * Roundcube password plugin driver: a password CHANGE in Samba / Active
 * Directory, done as the user.
 *
 * Managed by Ansible (librenfra mail_server, role webmail).
 *
 * The packaged ldap_samba_ad driver REPLACES unicodePwd, which AD treats as
 * an administrator's reset: for a user's own account it ends in "Insufficient
 * access". This one does what AD calls a change - the old value removed and
 * the new one added in a single modify, bound as the user - which every user
 * may do, and to which the domain's policy (history, minimum age, complexity)
 * applies. Finding the user and binding as them is ldap_simple's.
 */

require_once __DIR__ . '/ldap_simple.php';

class rcube_ldap_samba_ad_change_password extends rcube_ldap_simple_password
{
    public function save($curpass, $passwd)
    {
        $ret = $this->connect($curpass);
        if ($ret !== true) {
            return $ret;
        }

        $change = [
            [
                'attrib' => 'unicodePwd',
                'modtype' => LDAP_MODIFY_BATCH_REMOVE,
                'values' => [password::hash_password($curpass, 'ad')],
            ],
            [
                'attrib' => 'unicodePwd',
                'modtype' => LDAP_MODIFY_BATCH_ADD,
                'values' => [password::hash_password($passwd, 'ad')],
            ],
        ];

        $this->_debug("C: Change password for {$this->user}");

        if (!ldap_modify_batch($this->conn, $this->user, $change)) {
            $errno = ldap_errno($this->conn);
            $this->_debug('S: ' . ldap_error($this->conn));
            ldap_unbind($this->conn);

            // Constraint violation: the domain's policy refused the new
            // password - too short or simple, used before, or changed too
            // recently.
            return $errno == 0x13 ? PASSWORD_CONSTRAINT_VIOLATION : PASSWORD_CONNECT_ERROR;
        }

        $this->_debug('S: OK');
        ldap_unbind($this->conn);

        return PASSWORD_SUCCESS;
    }
}
