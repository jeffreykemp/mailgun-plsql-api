create or replace package mailgun_aq_pkg is
/* mailgun asynchronous API v0.4
  by Jeffrey Kemp
  
  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.

  * Grants to Oracle packages required:
  
    grant create job to myschema;
    grant execute on dbms_aq to myschema;
    grant execute on dbms_aqadm to myschema;
    grant execute on dbms_scheduler to myschema;
    grant execute on dbms_utility to myschema;
  
  NOTE: requirement for dbms_aqadm may be relaxed by creating the queue
        manually and removing the relevant procedures from this package.
  
  * The job will not call mailgun_pkg.init, so the following constants must be
    hardcoded in the mailgun_pkg package for your environment:
  
    g_public_api_key
    g_private_api_key
    g_my_domain
    g_api_url
    g_wallet_path
    g_wallet_password

*/

-- default queue priority
priority_default constant integer := 3;

-- default job frequency
repeat_interval_default constant varchar2(200) := 'FREQ=MINUTELY;INTERVAL=5;';

-- send an email asychronously
-- (to add more recipients or attach files to the email, call the relevant mailgun_pkg.send_xx()
-- or mailgun_pkg.attach() procedures before calling this)
procedure send_email
  (p_from_name      in varchar2 := null
  ,p_from_email     in varchar2
  ,p_reply_to       in varchar2 := null
  ,p_to_name        in varchar2 := null
  ,p_to_email       in varchar2 := null -- optional if the send_xx have been called already
  ,p_cc             in varchar2 := null
  ,p_bcc            in varchar2 := null
  ,p_subject        in varchar2
  ,p_message        in clob /*html allowed*/
  ,p_tag            in varchar2 := null
  ,p_mail_headers   in varchar2 := null /*json*/
  ,p_priority       in number   := priority_default -- lower numbers are processed first
  );

-- create the queue for asynchronous emails
procedure create_queue;

-- drop the queue
procedure drop_queue;

-- purge any expired (failed) emails stuck in the queue
procedure purge_queue;

-- send emails in the queue
procedure push_queue;

-- create a job to periodically call push_queue
procedure create_job
  (p_repeat_interval in varchar2 := repeat_interval_default);

-- drop the job
procedure drop_job;

end mailgun_aq_pkg;
/

show errors
