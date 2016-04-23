--TODO: replace jk64.com with example.com

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


-- send a simple email, puts it on the queue
begin
  mailgun_pkg.send_email
    (p_from_email => 'Mr Sender <sender@jk64.com>'
    ,p_to_email   => 'Ms Recipient <recipient@jk64.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => 'Test Email Body'
    );
  commit;
end;
/

-- push the queue
begin
  mailgun_pkg.push_queue;
end;
/

-- send an email using all the options
begin
  mailgun_pkg.send_email
    (p_from_name    => 'Mr Sender'
    ,p_from_email   => 'sender@jk64.com'
    ,p_reply_to     => 'reply@jk64.com'
    ,p_to_name      => 'Mr Recipient'
    ,p_to_email     => 'recipient@jk64.com'
    ,p_cc           => 'Mrs CC <cc@jk64.com>'
    ,p_bcc          => 'Ms BCC <bcc@jk64.com>'
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
  mailgun_pkg.push_queue; -- this issues a commit
end;
/

-- send an email to multiple recipients; each recipient will only see their own
-- name in the "To" field (but they will see the "CC" recipient)
begin
  mailgun_pkg.send_to('Mr Recipient <recipient1@jk64.com>', p_id => 'id1');
  mailgun_pkg.send_to('bob.jones@jk64.com', p_first_name => 'Bob', p_last_name => 'Jones', p_id => 'id2');
  mailgun_pkg.send_to('jane.doe@jk64.com', p_first_name => 'Jane', p_last_name => 'Doe', p_id => 'id3');
  mailgun_pkg.send_cc('cc@jk64.com');
  mailgun_pkg.send_bcc('bcc@jk64.com','Mr Bcc');
  mailgun_pkg.send_email
    (p_from_email => 'Mr Sender <sender@jk64.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => 'Hi ' || mailgun_pkg.recipient_first_name || ','
                  || '<p>'
                  || 'This is the email body.'
                  || '<p>'
                  || 'This email was sent to ' || mailgun_pkg.recipient_name || '.'
                  || '<br>'
                  || 'Reference: ' || mailgun_pkg.recipient_id
    );
  mailgun_pkg.push_queue; -- this issues a commit
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
    (p_from_email => 'Mr Sender <sender@jk64.com>'
    ,p_to_email   => 'Mrs Recipient <recipient@jk64.com>'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => '<html><body><strong>Test Email Body</strong>'
                  || '<p>'
                  || 'There should be 2 attachments and an image below.'
                  || '<p>'
                  || '<img src="cid:myimage.jpg">'
                  || '</body></html>'
    );

  mailgun_pkg.push_queue; -- this issues a commit

exception
  when others then
    mailgun_pkg.reset; -- clear any attachments from memory
    raise;
end;
/
