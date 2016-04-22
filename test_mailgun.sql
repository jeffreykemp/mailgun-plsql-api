-- Example of setting up this session
begin
  mailgun_pkg.init
    (p_public_api_key  => '...your mailgun public API key...'
    ,p_private_api_key => '...your mailgun private API key...'
    ,p_my_domain       => 'mydomain.com'
    ,p_wallet_path     => 'file:/oracle/wallets/test_wallet'
    ,p_wallet_password => 'secret'
    );
end;
/

-- Example of setting up this session (reverse proxy method)
begin
  mailgun_pkg.init
    (p_public_api_key  => '...your mailgun public API key...'
    ,p_private_api_key => '...your mailgun private API key...'
    ,p_my_domain       => 'mydomain.com'
    ,p_api_url         => 'http://api.mydomain.com/mailgun/v3/'
    );
end;
/

-- Determine whether an email address is valid
-- Expected output: "email is valid"
begin
  if mailgun_pkg.email_is_valid('chunkylover53@aol.com') then
    dbms_output.put_line('email is valid');
  else
    dbms_output.put_line('email is invalid');
  end if;
end;
/

-- Determine whether an email address is valid; get suggestion if available
-- Expected output: email is invalid; suggested "chunkylover53@aol.com"
declare
  is_valid   boolean;
  suggestion varchar2(512);
begin
  mailgun_pkg.validate_email
    (p_address    => 'chunkylover53@aol'
    ,p_is_valid   => is_valid
    ,p_suggestion => suggestion);
  if is_valid then
    dbms_output.put_line('email is valid');
  else
    dbms_output.put_line('email is invalid');
  end if;
  if suggestion is not null then
    dbms_output.put_line('suggested: ' || suggestion);
  end if;
end;
/


-- send a simple email
begin
  mailgun_pkg.send_email
    (p_from_email => 'Mr Sender <sender@example.com>'
    ,p_to_email   => 'Ms Recipient <recipient@example.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => 'Test Email Body'
    );
end;
/

-- send an email using all the options, including adding an unsubscribe link
begin
  mailgun_pkg.send_email
    (p_from_name    => 'Mr Sender'
    ,p_from_email   => 'sender@example.com'
    ,p_reply_to     => 'reply@example.com'
    ,p_to_name      => 'Mr Recipient'
    ,p_to_email     => 'recipient@example.com'
    ,p_cc           => 'Mrs CC <cc@example.com>'
    ,p_bcc          => 'Ms BCC <bcc@example.com>'
    ,p_subject      => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message      => '<html><body><strong>Test Email Body</strong>'
                    || '<p>'
                    || '<a href="' || mailgun_pkg.unsubscribe_link_tag || '">Unsubscribe</a>'
                    || '</body></html>'
    ,p_tag          => 'testtag2'
    ,p_mail_headers => '{ "Importance" : "high"' -- high/normal/low
                    || ', "Priority" : "urgent"' -- normal/urgent/non-urgent
                    || ', "Sensitivity" : "confidential"' -- personal/private/confidential
                    || ', "Expires" : "' || to_char(systimestamp + interval '7' day, 'Dy, dd Mon yyyy hh24:mi:ss tzh:tzm') || '"' -- expiry date/time
                    || '}'
    );
end;
/

-- send an email to multiple recipients; each recipient will only see their own
-- name in the "To" field (but they will see the "CC" recipient)
begin
  mailgun_pkg.send_to('Mr Recipient <recipient1@example.com>', p_id => 'id1');
  mailgun_pkg.send_to('bob.jones@example.com', p_first_name => 'Bob', p_last_name => 'Jones', p_id => 'id2');
  mailgun_pkg.send_to('jane.doe@example.com', p_first_name => 'Jane', p_last_name => 'Doe', p_id => 'id3');
  mailgun_pkg.send_cc('cc@example.com');
  mailgun_pkg.send_bcc('bcc@example.com','Mr Bcc');
  mailgun_pkg.send_email
    (p_from_email => 'Mr Sender <sender@example.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => 'Hi ' || mailgun_pkg.recipient_first_name || ','
                  || '<p>'
                  || 'This is the email body.'
                  || '<p>'
                  || 'This email was sent to ' || mailgun_pkg.recipient_name || '.'
                  || '<br>'
                  || 'Reference: ' || mailgun_pkg.recipient_id
    );
exception
  when others then
    mailgun_pkg.reset; -- clear any recipients from memory
    raise;
end;
/

-- send an email with some attachments
declare
  clob_content clob;
  blob_content blob;
begin

  -- generate a largish text file
  dbms_lob.createtemporary(clob_content,false);
  clob_content := lpad('x', 32767, 'x');
  dbms_lob.writeappend(clob_content, 32767, lpad('y',32767,'y'));
  dbms_lob.writeappend(clob_content, 3, 'EOF');
  dbms_output.put_line('file size=' || dbms_lob.getlength(clob_content));

  -- load a binary file
  -- source: https://github.com/mortenbra/alexandria-plsql-utils/blob/master/ora/file_util_pkg.pkb
  blob_content := alex.file_util_pkg.get_blob_from_file
    (p_directory_name => 'MY_DIRECTORY'
    ,p_file_name      => 'myimage.jpg');

  mailgun_pkg.attach
    (p_file_content => 'this is my file contents'
    ,p_file_name    => 'myfilesmall.txt'
    ,p_content_type => 'text/plain');

  mailgun_pkg.attach
    (p_file_content => clob_content
    ,p_file_name    => 'myfilelarge.txt'
    ,p_content_type => 'text/plain');

  mailgun_pkg.attach
    (p_file_content => blob_content
    ,p_file_name    => 'myimage.jpg'
    ,p_content_type => 'image/jpg'
    ,p_inline       => true);

  mailgun_pkg.send_email
    (p_from_email => 'Mr Sender <sender@example.com>'
    ,p_to_email   => 'Mrs Recipient <recipient@example.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => '<html><body><strong>Test Email Body</strong>'
                  || '<p>'
                  || 'There should be 2 attachments and an image below.'
                  || '<p>'
                  || '<img src="cid:myimage.jpg">'
                  || '</body></html>'
    );

exception
  when others then
    mailgun_pkg.reset; -- clear any attachments from memory
    raise;
end;
/
