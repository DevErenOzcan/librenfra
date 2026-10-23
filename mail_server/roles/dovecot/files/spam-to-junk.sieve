# Managed by Ansible (librenfra mail_server, role dovecot).
# rspamd adds "X-Spam: Yes" to mail it thinks is spam (roles/rspamd).
require ["fileinto"];
if header :is "X-Spam" "Yes" {
  fileinto "Junk";
  stop;
}
