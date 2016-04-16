declare
  is_valid   boolean;
  suggestion varchar2(512);
begin
  mailgun_pkg.validate_email
    (p_address    => 'test@gmail'
    ,p_is_valid   => is_valid
    ,p_suggestion => suggestion);
end;
/

begin
  if mailgun_pkg.email_is_valid('test@gmail') then
    dbms_output.put_line('email is valid');
  else
    dbms_output.put_line('email is invalid');
  end if;
end;
/

-- send a simple email
begin
  mailgun_pkg.send_email
    (p_from_email => 'sender@jk64.com'
    ,p_to_email   => 'recipient@jk64.com'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => 'Test Email Body'
    );
end;
/

-- send an email using all the options, including adding an unsubscribe link
begin
  mailgun_pkg.send_email
    (p_from_name  => 'Mr Sender'
    ,p_from_email => 'sender@jk64.com'
    ,p_reply_to   => 'reply@jk64.com'
    ,p_to_name    => 'Mr Recipient'
    ,p_to_email   => 'recipient@jk64.com'
    ,p_cc         => 'cc@jk64.com'
    ,p_bcc        => 'bcc@jk64.com'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => '<html><body><strong>Test Email Body</strong>'
                  || '<p>'
                  || '<a href="' || mailgun_pkg.unsubscribe_link_tag || '">Unsubscribe</a>'
                  || '</body></html>'
    ,p_tag        => 'testtag2'
    );
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
  blob_content := alex.file_util_pkg.get_blob_from_file
    (p_directory_name => 'MY_DIRECTORY'
    ,p_file_name      => 'myimage.png');
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
    ,p_file_name    => 'myimage.png'
    ,p_content_type => 'image/png'
    ,p_inline       => true);
  mailgun_pkg.send_email
    (p_from_name  => 'Mr Sender'
    ,p_from_email => 'sender@jk64.com'
    ,p_to_name    => 'Mr Recipient'
    ,p_to_email   => 'recipient@jk64.com'
    ,p_subject    => 'test subject ' || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
    ,p_message    => '<html><body><strong>Test Email Body</strong>'
                  || '<p>'
                  || 'There should be 3 attachments.'
                  || '<p>'
                  || '<img src="cid:myimage.png">'
                  || '</body></html>'
    );
exception
  when others then
    mailgun_pkg.reset; -- clear any attachments from memory
    raise;
end;
/
