create or replace package mailgun_pkg is
/* mailgun API v0.7
  https://github.com/jeffreykemp/mailgun-plsql-api
  by Jeffrey Kemp
*/

-- Substitution Strings supported by Mailgun

-- include this in your email to allow the recipient to unsubscribe from all
-- emails from your server
unsubscribe_link_all          constant varchar2(100) := '%unsubscribe_url%';

-- include this in your email, and set a tag in the call to send_email, to
-- allow the recipient to unsubscribe from emails from your server with that tag
unsubscribe_link_tag          constant varchar2(100) := '%tag_unsubscribe_url%';

-- include these in your email to substitute details about the recipient in the
-- subject line or message body
recipient_email               constant varchar2(100) := '%recipient.email%';
recipient_name                constant varchar2(100) := '%recipient.name%';
recipient_first_name          constant varchar2(100) := '%recipient.first_name%';
recipient_last_name           constant varchar2(100) := '%recipient.last_name%';
recipient_id                  constant varchar2(100) := '%recipient.id%';

-- default parameters
default_no_change             constant varchar2(4000) := '*NO-CHANGE*';
default_priority              constant integer := 3;
default_repeat_interval       constant varchar2(200) := 'FREQ=MINUTELY;INTERVAL=5;';
default_purge_repeat_interval constant varchar2(200) := 'FREQ=WEEKLY;BYDAY=SUN;BYHOUR=0;';
default_purge_msg_state       constant varchar2(100) := 'EXPIRED';
default_max_retries           constant number := 10; --allow failures before giving up on a message
default_retry_delay           constant number := 60; --wait seconds before trying this message again
default_page_size             constant number := 20; --rows to fetch per API call

-- mail datetime format
datetime_format               constant varchar2(100) := 'Dy, dd Mon yyyy hh24:mi:ss tzh:tzm';

-- whitelist actions
whitelist_suppress            constant varchar2(100) := 'suppress';
whitelist_raise_exception     constant varchar2(100) := 'raise_exception';

-- copy of utl_tcp.crlf for convenience
crlf                          constant varchar2(2) := chr(13) || chr(10);

-- init: set up mailgun parameters
--   default is to not change the given parameter
--   for details refer to:
--https://github.com/jeffreykemp/mailgun-plsql-api/wiki/API-Reference#procedure-init
procedure init
  (p_public_api_key               in varchar2 := default_no_change
  ,p_private_api_key              in varchar2 := default_no_change
  ,p_my_domain                    in varchar2 := default_no_change
  ,p_api_url                      in varchar2 := default_no_change
  ,p_wallet_path                  in varchar2 := default_no_change
  ,p_wallet_password              in varchar2 := default_no_change
  ,p_log_retention_days           in number := null
  ,p_default_sender_name          in varchar2 := default_no_change
  ,p_default_sender_email         in varchar2 := default_no_change
  ,p_queue_expiration             in number := null
  ,p_prod_instance_name           in varchar2 := default_no_change
  ,p_non_prod_recipient           in varchar2 := default_no_change
  ,p_required_sender_domain       in varchar2 := default_no_change
  ,p_recipient_whitelist          in varchar2 := default_no_change
  ,p_whitelist_action             in varchar2 := default_no_change
  );

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

-- send an email
-- (to add more recipients or attach files to the email, call the relevant send_xx()
-- or attach() procedures before calling this)
-- for details refer to:
--https://github.com/jeffreykemp/mailgun-plsql-api/wiki/API-Reference#procedure-send_email
procedure send_email
  (p_from_name    in varchar2  := null
  ,p_from_email   in varchar2  := null
  ,p_reply_to     in varchar2  := null
  ,p_to_name      in varchar2  := null
  ,p_to_email     in varchar2  := null             -- optional if the send_xx have been called already
  ,p_cc           in varchar2  := null
  ,p_bcc          in varchar2  := null
  ,p_subject      in varchar2
  ,p_message      in clob                          -- html allowed
  ,p_tag          in varchar2  := null
  ,p_mail_headers in varchar2  := null             -- json structure of tag/value pairs
  ,p_priority     in number    := default_priority -- lower numbers are processed first
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
procedure create_queue
  (p_max_retries in number := default_max_retries
  ,p_retry_delay in number := default_retry_delay
  );

-- drop the queue
procedure drop_queue;

-- purge any expired (failed) emails stuck in the queue
procedure purge_queue (p_msg_state in varchar2 := default_purge_msg_state);

-- send emails in the queue
procedure push_queue
  (p_asynchronous in boolean := false);

-- create a job to periodically call push_queue
procedure create_job
  (p_repeat_interval in varchar2 := default_repeat_interval);

-- drop the push_queue job
procedure drop_job;

-- purge the logs older than the given number of days
procedure purge_logs (p_log_retention_days in number := null);

-- create a job to periodically call purge_logs
procedure create_purge_job
  (p_repeat_interval in varchar2 := default_purge_repeat_interval);

-- drop the purge_logs job
procedure drop_purge_job;

-- get mailgun stats
function get_stats
  (p_event_types     in varchar2 := 'all' -- comma-delimited list of event types (accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored)
  ,p_resolution      in varchar2 := null  -- default is "day"; can be "hour", "day" or "month"
  ,p_start_time      in date     := null  -- default is 7 days prior to end time
  ,p_end_time        in date     := null  -- default is now
  ,p_duration        in number   := null  -- backwards from p_end_time
  ) return t_mailgun_stat_arr pipelined;

-- get mailgun stats for a tag
function get_tag_stats
  (p_tag             in varchar2          -- tag name (no spaces allowed)
  ,p_event_types     in varchar2 := 'all' -- comma-delimited list of event types (accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored)
  ,p_resolution      in varchar2 := null  -- default is "day"; can be "hour", "day" or "month"
  ,p_start_time      in date     := null  -- default is 7 days prior to end time
  ,p_end_time        in date     := null  -- default is now
  ,p_duration        in number   := null  -- backwards from p_end_time
  ) return t_mailgun_stat_arr pipelined;

-- get mailgun event log
-- filter expression examples - https://documentation.mailgun.com/api-events.html#filter-expression
function get_events
  (p_start_time      in date     := null -- default is now
  ,p_end_time        in date     := null -- default is to keep going back in history as far as possible
  ,p_page_size       in number   := default_page_size -- rows to fetch per API call; max 300
  ,p_event           in varchar2 := null -- filter expression (accepted,rejected,delivered,failed,opened,clicked,unsubscribed,complained,stored)
  ,p_sender          in varchar2 := null -- filter expression, e.g. '"sample@example.com"'
  ,p_recipient       in varchar2 := null -- filter expression, e.g. 'gmail OR hotmail'
  ,p_subject         in varchar2 := null -- filter expression, e.g. 'foo AND bar'
  ,p_tags            in varchar2 := null -- filter expression, e.g. 'NOT internal'
  ,p_severity        in varchar2 := null -- for failed events; "temporary" or "permanent"
  ) return t_mailgun_event_arr pipelined;

-- get mailgun tags
function get_tags
  (p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_tag_arr pipelined;

-- add a tag, or update a tag description
procedure update_tag
  (p_tag         in varchar2 -- no spaces allowed
  ,p_description in varchar2 := null);

-- delete a tag
procedure delete_tag (p_tag in varchar2);  -- no spaces allowed

-- get bounces, unsubscribes, or complaints
function get_suppressions
  (p_type  in varchar2 -- 'bounces', 'unsubscribes', or 'complaints'
  ,p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_suppression_arr pipelined;

-- remove an email address from the bounce list
procedure delete_bounce (p_email_address in varchar2);

-- add an email address to the unsubscribed list
procedure add_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null);

-- remove an email address from the unsubscribed list
procedure delete_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null);

-- remove an email address from the complaint list
procedure delete_complaint (p_email_address in varchar2);

-- Send a test email.
-- Settings can be overridden just for this call (i.e. they won't be saved)
-- e.g. to test whether new settings will work.
procedure send_test_email
  (p_from_name       in varchar2 := null
  ,p_from_email      in varchar2 := null
  ,p_to_name         in varchar2 := null
  ,p_to_email        in varchar2
  ,p_subject         in varchar2 := null -- if null, a subject will be generated
  ,p_message         in varchar2 := null -- if null, a message will be generated
  ,p_private_api_key in varchar2 := default_no_change
  ,p_my_domain       in varchar2 := default_no_change
  ,p_api_url         in varchar2 := default_no_change
  ,p_wallet_path     in varchar2 := default_no_change
  ,p_wallet_password in varchar2 := default_no_change
  );

end mailgun_pkg;
/

show errors