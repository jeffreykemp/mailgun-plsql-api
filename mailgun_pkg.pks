create or replace package mailgun_pkg is
/* mailgun API
  by Jeffrey Kemp
  
  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.

  Includes:
  
  * email validator
  NOTE: there is a jQuery plugin for email validation on the client as well
  For an Apex plugin, download from here:
  https://github.com/jeffreykemp/jk64-plugin-mailgunemailvalidator
  
  * API call to send an email
  NOTE: another alternative (one that also works with Apex's builtin emails
        is to use the mailgun SMTP interface instead.

  PREREQUISITES
  
  * Oracle Database 11gR2
  
  * Oracle Application Express 5.0 (just for the apex packages)
  
  * Grants to Oracle / Apex packages:
  
    grant execute on apex_util to myschema;
    grant execute on apex_json to myschema;
    grant execute on utl_http to myschema;
    grant execute on apex_debug_message to myschema;
    grant execute on dbms_output to myschema;
  
  * Mailgun account - sign up here: https://mailgun.com/signup

  * Your server must be able to connect via https to api.mailgun.net

*/

-- include this in your email to allow the recipient to unsubscribe from all
-- emails from your server
unsubscribe_link_all constant varchar2(100) := '%unsubscribe_url%';

-- include this in your email, and set a tag in the call to send_email, to
-- allow the recipient to unsubscribe from emails from your server with that tag
unsubscribe_link_tag constant varchar2(100) := '%tag_unsubscribe_url%';

-- validate_email: validate an email address (procedure version)
--   address:    email address to validate
--   is_valid:   true if the email address appears to be valid
--   suggestion: suggested correction for email address (may or may not be
--               set regardless of whether is_valid is true or false)
procedure validate_email
  (p_address    in varchar2
  ,p_is_valid   out boolean
  ,p_suggestion out varchar2
  );

-- email_is_valid: validate an email address (function wrapper)
--   address: email address to validate
--   returns true if address appears to be valid
function email_is_valid (p_address in varchar2) return boolean;

-- send a simple email
-- (to attach files to the email, call attach() for each attachment, then call
-- send_email last)
procedure send_email
  (p_from_name    in varchar2 := null
  ,p_from_email   in varchar2
  ,p_reply_to     in varchar2 := null
  ,p_to_name      in varchar2 := null
  ,p_to_email     in varchar2
  ,p_cc           in varchar2 := null
  ,p_bcc          in varchar2 := null
  ,p_subject      in varchar2
  ,p_message      in clob /*html allowed*/
  ,p_tag          in varchar2 := null
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

end mailgun_pkg;
/

show errors