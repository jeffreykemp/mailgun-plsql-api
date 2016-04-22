create or replace package mailgun_pkg is
/* mailgun API v0.4
  by Jeffrey Kemp
  
  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.

FEATURES
  
  * email validator
  NOTE: there is a jQuery plugin for email validation on the client as well
  For an Apex plugin, download from here:
  https://github.com/jeffreykemp/jk64-plugin-mailgunemailvalidator
  
  * API call to send an email; multiple attachments supported.
  
  * Setup procedures to manage a queue and job for asynchronous emails.
  
  NOTE: another alternative (one that also works with Apex's builtin emails
        is to use the mailgun SMTP interface instead.

PREREQUISITES
  
  * Oracle Database 11gR2
  
  * Oracle Application Express 5.0 (just for the apex packages)
  
  * Grants to Oracle / Apex packages:
  
    grant create job to myschema;
    grant create procedure to myschema;
    grant execute on apex_debug to myschema;
    grant execute on apex_json to myschema;
    grant execute on apex_util to myschema;
    grant execute on dbms_aq to myschema;
    grant execute on dbms_aqadm to myschema;
    grant execute on dbms_output to myschema;
    grant execute on dbms_scheduler to myschema;
    grant execute on dbms_utility to myschema;
    grant execute on utl_http to myschema;

  NOTE: requirement for dbms_aqadm may be relaxed by creating the queue
        manually and removing the relevant procedures from this package.
    
  * Your server must be able to connect via https to api.mailgun.net

  * Mailgun account - sign up here: https://mailgun.com/signup

  * The following constants must be set in the mailgun_pkg package
    for your environment before this can be used.
  
    g_public_api_key
    g_private_api_key
    g_my_domain
    g_api_url
    g_wallet_path
    g_wallet_password

*/

-- Substitution Strings supported by Mailgun

-- include this in your email to allow the recipient to unsubscribe from all
-- emails from your server
unsubscribe_link_all    constant varchar2(100) := '%unsubscribe_url%';

-- include this in your email, and set a tag in the call to send_email, to
-- allow the recipient to unsubscribe from emails from your server with that tag
unsubscribe_link_tag    constant varchar2(100) := '%tag_unsubscribe_url%';

-- include these in your email to substitute details about the recipient in the
-- subject line or message body
recipient_email         constant varchar2(100) := '%recipient.email%';
recipient_name          constant varchar2(100) := '%recipient.name%';
recipient_first_name    constant varchar2(100) := '%recipient.first_name%';
recipient_last_name     constant varchar2(100) := '%recipient.last_name%';
recipient_id            constant varchar2(100) := '%recipient.id%';

-- default queue priority
priority_default        constant integer := 3;

-- default job frequency
repeat_interval_default constant varchar2(200) := 'FREQ=MINUTELY;INTERVAL=5;';

-- validate_email: validate an email address (procedure version)
--   p_address:    email address to validate
--   p_is_valid:   true if the email address appears to be valid
--   p_suggestion: suggested correction for email address (may or may not be
--                 set regardless of whether is_valid is true or false)
procedure validate_email
  (p_address    in varchar2
  ,p_is_valid   out boolean
  ,p_suggestion out varchar2
  );

-- email_is_valid: validate an email address (function wrapper)
--   address: email address to validate
--   returns true if address appears to be valid
function email_is_valid (p_address in varchar2) return boolean;

-- send an email in the current session (synchronous)
-- (to send an email, use mailgun_aq_pkg.send_email)
-- (to add more recipients or attach files to the email, call the relevant send_xx()
-- or attach() procedures before calling this)
procedure send_email
  (p_from_name    in varchar2  := null
  ,p_from_email   in varchar2
  ,p_reply_to     in varchar2  := null
  ,p_to_name      in varchar2  := null
  ,p_to_email     in varchar2  := null             -- optional if the send_xx have been called already
  ,p_cc           in varchar2  := null
  ,p_bcc          in varchar2  := null
  ,p_subject      in varchar2
  ,p_message      in clob                          -- html allowed
  ,p_tag          in varchar2  := null
  ,p_mail_headers in varchar2  := null             -- json structure of tag/value pairs
  ,p_priority     in number    := priority_default -- lower numbers are processed first
  );

-- call these BEFORE send_email to add multiple recipients
-- p_email:      (required) email address
-- p_name:       (optional) person's full name
-- p_first_name: (optional) person's first/given name
-- p_last_name:  (optional) person's last/surname
-- p_id:         (optional) unique id for the recipient
-- p_send_by:    (optional) use this parameter if you want, instead of calling
--               the different send_xx procedures
procedure send_to
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ,p_send_by    in varchar2 := 'to' -- must be to/cc/bcc
  );
procedure send_cc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  );
procedure send_bcc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  );

-- call these BEFORE send_email to add an attachment or inline image
-- multiple attachments may be added
-- if inline is true, you can include the image in the email message by:
-- <img src="cid:myfilename.jpg">
procedure attach
  (p_file_content in blob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  );
procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  );

-- call this to clear any attachments (note: send_email does this for you)
-- (e.g. if your proc raises an exception before it can send the email)
procedure reset;

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

-- set verbose option on/off
procedure verbose (p_on in boolean := true);

end mailgun_pkg;
/

show errors