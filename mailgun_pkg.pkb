create or replace package body mailgun_pkg is
/* mailgun API v0.3
  by Jeffrey Kemp

  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.
*/

g_public_api_key  varchar2(200) := site_parameter.get_value('MAILGUN_PUBLIC_KEY');
g_private_api_key varchar2(200) := site_parameter.get_value('MAILGUN_SECRET_KEY');
g_my_domain       varchar2(200) := 'jk64.com';
g_api_url         varchar2(200) := 'http://api.jk64.com/mailgun/v3/'; --'https://api.mailgun.net/v3/';
g_wallet_path     varchar2(1000);
g_wallet_password varchar2(1000);

-- if true, log all data sent to/from mailgun server
g_verbose boolean := false;

queue_name   constant varchar2(30) := 'mailgun_queue';
queue_table  constant varchar2(30) := 'mailgun_queue_tab';
job_name     constant varchar2(30) := 'mailgun_process_queue';
payload_type constant varchar2(30) := 't_mailgun_email';

crlf constant varchar2(50) := chr(13) || chr(10);
boundary constant varchar2(30) := '-----v4np6rnptyb566a0y704sjeqv';
max_recipients constant integer := 1000; -- mailgun limitation for recipient variables

--type t_recipient is record
--  (send_by    varchar2(3)    --to/cc/bcc
--  ,email_spec varchar2(1000) -- name <email>
--   -- mailgun recipient variables:
--  ,email      varchar2(512) -- %recipient.email%
--  ,name       varchar2(200) -- %recipient.name%
--  ,first_name varchar2(200) -- %recipient.first_name%
--  ,last_name  varchar2(200) -- %recipient.last_name%
--  ,id         varchar2(200) -- %recipient.id%
--  );
--
--type t_attachment is record
--  (blob_content blob
--  ,clob_content clob
--  ,header       varchar2(4000)
--  );

--type t_rcpt is table of t_recipient index by binary_integer;
--type t_arr is table of t_attachment index by binary_integer;

g_recipient t_mailgun_recipient_arr;
g_attachment t_mailgun_attachment_arr;

e_no_queue_data exception;
pragma exception_init (e_no_queue_data, -25228);

procedure msg (p_msg in varchar2) is
begin
  apex_debug_message.log_message($$PLSQL_UNIT || ': ' || p_msg);
  dbms_output.put_line(p_msg);
end msg;

procedure assert (cond in boolean, err in varchar2) is
begin
  if not cond then
    raise_application_error(-20000, $$PLSQL_UNIT || ' assertion failed: ' || err);
  end if;
end assert;

procedure init
  (p_public_api_key  in varchar2 := null
  ,p_private_api_key in varchar2 := null
  ,p_my_domain       in varchar2 := null
  ,p_api_url         in varchar2 := null
  ,p_wallet_path     in varchar2 := null
  ,p_wallet_password in varchar2 := null
  ) is
begin
  msg('init');
  
  g_public_api_key  := nvl(p_public_api_key,  g_public_api_key);
  g_private_api_key := nvl(p_private_api_key, g_private_api_key);
  g_my_domain       := nvl(p_my_domain,       g_my_domain);
  g_api_url         := nvl(p_api_url,         g_api_url);
  g_wallet_path     := nvl(p_wallet_path,     g_wallet_path);
  g_wallet_password := nvl(p_wallet_password, g_wallet_password);

end init;

procedure log_headers (resp in out nocopy utl_http.resp) is
  name  varchar2(256);
  value varchar2(1024);
begin
  if g_verbose then
    for i in 1..utl_http.get_header_count(resp) loop
      utl_http.get_header(resp, i, name, value);
      msg(name || ': ' || value);
    end loop;
  end if;
end log_headers;

procedure set_wallet is
begin
  if g_wallet_path is not null or g_wallet_password is not null then
    utl_http.set_wallet(g_wallet_path, g_wallet_password);
  end if;
end set_wallet;

function get_response (resp in out nocopy utl_http.resp) return varchar2 is
  buf varchar2(32767);
begin

  begin
    utl_http.read_text(resp, buf, 32767);
  exception
    when utl_http.end_of_body then
      null;
  end;
  utl_http.end_response(resp);

  if g_verbose then
    msg(buf);
  end if;
  
  return buf;
end get_response;

function get_json
  (p_url    in varchar2
  ,p_params in varchar2 := null
  ,p_user   in varchar2 := null
  ,p_pwd    in varchar2 := null
  ) return varchar2 is
  url   varchar2(4000) := p_url;
  req   utl_http.req;
  resp  utl_http.resp;
  buf   varchar2(32767);
begin
  msg('get_json ' || p_url);
  
  assert(p_url is not null, 'get_json: p_url cannot be null');
  
  if p_params is not null then
    url := url || '?' || p_params;
  end if;
  
  set_wallet;

  req := utl_http.begin_request(url, 'GET');

  if p_user is not null or p_pwd is not null then
    utl_http.set_authentication(req, p_user, p_pwd);
  end if;

  utl_http.set_header (req,'Accept','application/json');

  resp := utl_http.get_response(req);
  msg('HTTP response: ' || resp.status_code || ' ' || resp.reason_phrase);

  log_headers(resp);

  if resp.status_code != '200' then
    raise_application_error(-20000, 'get_json call failed ' || resp.status_code || ' ' || resp.reason_phrase || ' [' || url || ']');
  end if;

  buf := get_response(resp);

  msg('...finish [' || length(buf) || ']');
  return buf;
end get_json;

procedure validate_email
  (p_address    in varchar2
  ,p_is_valid   out boolean
  ,p_suggestion out varchar2
  ) is
  str          varchar2(32767);
  is_valid_str varchar2(100);
begin
  msg('validate_email ' || p_address);
  
  assert(g_public_api_key is not null, 'validate_email: your mailgun public API key not set');
  assert(p_address is not null, 'validate_email: p_address cannot be null');
  
  str := get_json
    (p_url    => g_api_url || 'address/validate'
    ,p_params => 'address=' || apex_util.url_encode(p_address)
    ,p_user   => 'api'
    ,p_pwd    => g_public_api_key);
  
  apex_json.parse(str);

  msg('address=' || apex_json.get_varchar2('address'));

  is_valid_str := apex_json.get_varchar2('is_valid');
  msg('is_valid_str=' || is_valid_str);
  
  p_is_valid := is_valid_str = 'true';

  p_suggestion := apex_json.get_varchar2('did_you_mean');
  msg('suggestion=' || p_suggestion);

end validate_email;

function email_is_valid (p_address in varchar2) return boolean is
  is_valid   boolean;
  suggestion varchar2(512);  
begin
  msg('email_is_valid ' || p_address);
  
  validate_email
    (p_address    => p_address
    ,p_is_valid   => is_valid
    ,p_suggestion => suggestion);
  
  return is_valid;
end email_is_valid;

function field_header (tag in varchar2) return varchar2 is
begin
  assert(tag is not null, 'field_header: tag cannot be null');
  return '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="' || tag || '"' || crlf
    || crlf;
end field_header;

function form_field (tag in varchar2, data in varchar2) return varchar2 is
begin
  return case when data is not null
         then field_header(tag) || data || crlf
         end;
end form_field;

procedure write_text
  (req in out nocopy utl_http.req
  ,buf in varchar2) is
begin
  if g_verbose then
    msg(buf);
  end if;
  utl_http.write_text(req, buf);
end write_text;

procedure write_clob
  (req          in out nocopy utl_http.req
  ,file_content in clob) is
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 32767;
  buf          varchar2(32767);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
begin
  assert(file_content is not null, 'write_clob: file_content cannot be null');
  file_len := dbms_lob.getlength (file_content);
  msg('write_clob ' || file_len || ' bytes');
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    dbms_lob.read (file_content, amt, filepos, buf);
    write_text(req, buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    dbms_lob.read (file_content, modulo, filepos, buf);
    write_text(req, buf);
  end if;
end write_clob;

procedure write_blob
  (req          in out nocopy utl_http.req
  ,file_content in out nocopy blob) is
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 2000;
  buf          raw(2000);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
begin
  assert(file_content is not null, 'write_blob: file_content cannot be null');
  file_len := dbms_lob.getlength (file_content);
  msg('write_blob ' || file_len || ' bytes');
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    dbms_lob.read (file_content, amt, filepos, buf);
    utl_http.write_raw(req, buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    dbms_lob.read (file_content, modulo, filepos, buf);
    utl_http.write_raw(req, buf);
  end if;
end write_blob;

procedure send_email_synchronous (p_payload in out nocopy t_mailgun_email) is
  url              varchar2(32767) := g_api_url || g_my_domain || '/messages';
  header           clob;
  sender           varchar2(4000);
  recipients_to    varchar2(32767);
  recipients_cc    varchar2(32767);
  recipients_bcc   varchar2(32767);
  footer           varchar2(100);
  content_length   integer;
  req              utl_http.req;
  resp             utl_http.resp;
  resp_started     boolean := false;
  my_scheme        varchar2(256);
  my_realm         varchar2(256);
  buf              varchar2(32767);
  recipient_count  integer := 0;
  attachment_count integer := 0;

  procedure append_recipient (rcpt_list in out varchar2, r in t_mailgun_recipient) is
  begin
    
    if rcpt_list is not null then
      rcpt_list := rcpt_list || ', ';
    end if;
    rcpt_list := rcpt_list || r.email_spec;
    
    apex_json.open_object(r.email);
    apex_json.write('email',      r.email);
    apex_json.write('name',       r.name);
    apex_json.write('first_name', r.first_name);
    apex_json.write('last_name',  r.last_name);
    apex_json.write('id',         r.id);
    apex_json.close_object;

  end append_recipient;

begin
  msg('send_email_synchronous ' || p_payload.to_email || ' "' || p_payload.subject || '"');
  
  assert(g_private_api_key is not null, 'send_email_synchronous: your mailgun private API key not set');
  assert(g_my_domain is not null, 'send_email_synchronous: your mailgun domain not set');
  assert(p_payload.from_email is not null, 'send_email_synchronous: from_email cannot be null');
  
  if p_payload.from_email like '% <%>%' then
    sender := p_payload.from_email;
  else
    sender := nvl(p_payload.from_name,p_payload.from_email) || ' <'||p_payload.from_email||'>';
  end if;

  if p_payload.recipient is not null then
    recipient_count := p_payload.recipient.count;
  end if;

  if p_payload.to_email is not null then
    assert(recipient_count = 0, 'cannot mix multiple recipients with to_email parameter');
    if p_payload.to_email like '% <%>%' then
      recipients_to := p_payload.to_email;
    else
      recipients_to := nvl(p_payload.to_name, p_payload.to_email) || ' <' || p_payload.to_email || '>';
    end if;
  end if;

  recipients_cc  := p_payload.cc;
  recipients_bcc := p_payload.bcc;
  
  apex_json.initialize_clob_output;
  apex_json.open_object;
  
  if recipient_count > 0 then
    for i in 1..recipient_count loop

      case p_payload.recipient(i).send_by
      when 'to'  then
        append_recipient(recipients_to, p_payload.recipient(i));
        
      when 'cc'  then
        append_recipient(recipients_cc, p_payload.recipient(i));

      when 'bcc' then
        append_recipient(recipients_bcc, p_payload.recipient(i));
      end case;

    end loop;
  end if;
  
  assert(recipients_to is not null, 'send_email: recipients list cannot be empty');
  
  apex_json.close_object;
  dbms_lob.createtemporary(header, false, dbms_lob.call);

  header := crlf
    || form_field('from', sender)
    || form_field('h:Reply-To', p_payload.reply_to)
    || form_field('to', recipients_to)
    || form_field('cc', recipients_cc)
    || form_field('bcc', recipients_bcc)
    || form_field('o:tag', p_payload.tag)
    || form_field('subject', p_payload.subject)
    || field_header('recipient-variables');
  
  dbms_lob.append(header, apex_json.get_clob_output);

  buf := crlf || field_header('html');
  dbms_lob.writeappend(header, length(buf), buf);

  dbms_lob.append(header, p_payload.message);

  dbms_lob.writeappend(header, length(crlf), crlf);

  footer := '--' || boundary || '--';
  
  content_length := dbms_lob.getlength(header)
                  + length(footer);

  if p_payload.attachment is not null then
    attachment_count := p_payload.attachment.count;
  end if;

  if attachment_count > 0 then
    for i in 1..attachment_count loop

      content_length := content_length
                      + length(p_payload.attachment(i).header)
                      + length(crlf);

      if p_payload.attachment(i).clob_content is not null then
        content_length := content_length
                        + dbms_lob.getlength(p_payload.attachment(i).clob_content);
      elsif p_payload.attachment(i).blob_content is not null then
        content_length := content_length
                        + dbms_lob.getlength(p_payload.attachment(i).blob_content);
      end if;

    end loop;
  end if;
  
  msg('content_length=' || content_length);

  -- Turn off checking of status code. We will check it by ourselves.
  utl_http.set_response_error_check(false);

  set_wallet;
  
  req := utl_http.begin_request(url, 'POST');
  
  utl_http.set_authentication(req, 'api', g_private_api_key); -- Use HTTP Basic Authen. Scheme
  
  utl_http.set_header(req, 'Content-Type', 'multipart/form-data; boundary="' || boundary || '"');
  utl_http.set_header(req, 'Content-Length', content_length);
  
  msg('writing message contents...');
  
  write_clob(req, header);

  if attachment_count > 0 then
    for i in 1..attachment_count loop

      write_text(req, p_payload.attachment(i).header);

      if p_payload.attachment(i).clob_content is not null then
        write_clob(req, p_payload.attachment(i).clob_content);
      elsif p_payload.attachment(i).blob_content is not null then
        write_blob(req, p_payload.attachment(i).blob_content);
      end if;

      write_text(req, crlf);

    end loop;
  end if;

  write_text(req, footer);
  
  msg('reading response from server...');
  
  resp := utl_http.get_response(req);
  resp_started := true;
  
  if (resp.status_code = utl_http.http_unauthorized) then
    utl_http.get_authentication(resp, my_scheme, my_realm, false);
    msg('Unauthorized: please supply the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.');
    utl_http.end_response(resp);
    raise_application_error(-20000, 'unauthorized');
  elsif (resp.status_code = utl_http.http_proxy_auth_required) then
    utl_http.get_authentication(resp, my_scheme, my_realm, true);
    msg('Proxy auth required: please supplied the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.');
    utl_http.end_response(resp);
    raise_application_error(-20000, 'proxy auth required');
  end if;
  
  log_headers(resp);

  if resp.status_code != '200' then
    raise_application_error(-20000, 'post failed ' || resp.status_code || ' ' || resp.reason_phrase || ' [' || url || ']');
  end if;
  
  -- expected response will be a json document like this:
  --{
  --  "id": "<messageid@domain>",
  --  "message": "Queued. Thank you."
  --}
  msg(get_response(resp));
  
  apex_json.free_output;
  dbms_lob.freetemporary(header);
  
  msg('send_email_synchronous finished');
exception
  when others then
    msg(SQLERRM);
    reset;
    apex_json.free_output;
    if header is not null then
      dbms_lob.freetemporary(header);
    end if;
    if resp_started then utl_http.end_response (resp); end if;
    raise;
end send_email_synchronous;

procedure send_email
  (p_from_name      in varchar2 := null
  ,p_from_email     in varchar2
  ,p_reply_to       in varchar2 := null
  ,p_to_name        in varchar2 := null
  ,p_to_email       in varchar2 := null
  ,p_cc             in varchar2 := null
  ,p_bcc            in varchar2 := null
  ,p_subject        in varchar2
  ,p_message        in clob
  ,p_tag            in varchar2 := null
  ,p_priority       in number   := priority_default
  ) is
  enq_opts        dbms_aq.enqueue_options_t;
  enq_msg_props   dbms_aq.message_properties_t;
  payload         t_mailgun_email;
  msgid           raw(16);
  recipient_count integer := 0;
begin
  msg('send_email ' || p_to_email || ' "' || p_subject || '"');
  
  assert(g_private_api_key is not null, 'send_email: your mailgun private API key not set');
  assert(g_my_domain is not null, 'send_email: your mailgun domain not set');
  assert(p_from_email is not null, 'send_email: p_from_email cannot be null');

  if g_recipient is not null then
    recipient_count := g_recipient.count;
  end if;

  if p_to_email is not null then
    assert(recipient_count = 0, 'cannot mix multiple recipients with p_to_email parameter');
  else
    assert(recipient_count > 0, 'must be at least one recipient');
  end if;
  
  payload := t_mailgun_email
    ( from_name  => p_from_name
    , from_email => p_from_email
    , reply_to   => p_reply_to
    , to_name    => p_to_name
    , to_email   => p_to_email
    , cc         => p_cc
    , bcc        => p_bcc
    , subject    => p_subject
    , message    => p_message
    , tag        => p_tag
    , recipient  => g_recipient
    , attachment => g_attachment
    );

  enq_msg_props.expiration := 6 * 60 * 60; -- expire after 6 hours
  enq_msg_props.priority   := p_priority;

  dbms_aq.enqueue
    (queue_name         => user||'.'||queue_name
    ,enqueue_options    => enq_opts
    ,message_properties => enq_msg_props
    ,payload            => payload
    ,msgid              => msgid
    );
  
  msg('email queued ' || msgid);
  
  reset;
  
  msg('send_email finished');
exception
  when others then
    msg(sqlerrm);
    msg(dbms_utility.format_error_stack);
    msg(dbms_utility.format_error_backtrace);
    reset;
    raise;
end send_email;

procedure add_recipient
  (p_email      in varchar2
  ,p_name       in varchar2
  ,p_first_name in varchar2
  ,p_last_name  in varchar2
  ,p_id         in varchar2
  ,p_send_by    in varchar2
  ) is
  email_spec varchar2(4000);
  email      varchar2(512);
  r t_mailgun_recipient;
begin
  msg('add_recipient ' || p_send_by || ': ' || p_name || ' <' || p_email || '> #' || p_id);
  
  if g_recipient is not null then
    assert(g_recipient.count < max_recipients, 'maximum recipients per email exceeded (' || max_recipients || ')');
  end if;
  
  assert(p_email is not null, 'add_recipient: p_email cannot be null');
  assert(p_send_by is not null, 'add_recipient: p_send_by cannot be null');
  assert(p_send_by in ('to','cc','bcc'), 'p_send_by must be to/cc/bcc');

  if p_email like '% <%>' then
    email_spec := p_email;
    email      := rtrim(ltrim(regexp_substr(p_email, '<.*>', 1, 1), '<'), '>');
  else
    email_spec := nvl(r.name, p_email) || ' <' || p_email || '>';
    email      := p_email;
  end if;
  
  r := t_mailgun_recipient
    ( p_send_by
    , email_spec
    , email
    , nvl(p_name, trim(p_first_name || ' ' || p_last_name))
    , p_first_name
    , p_last_name
    , p_id
    );

  if g_recipient is null then
    g_recipient := t_mailgun_recipient_arr();
  end if;
  g_recipient.extend(1);
  g_recipient(g_recipient.last) := r;

end add_recipient;

procedure send_to
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ,p_send_by    in varchar2 := 'to'
  ) is
begin
  add_recipient
    (p_email      => p_email
    ,p_name       => p_name
    ,p_first_name => p_first_name
    ,p_last_name  => p_last_name
    ,p_id         => p_id
    ,p_send_by    => p_send_by);
end send_to;

procedure send_cc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ) is
begin
  add_recipient
    (p_email      => p_email
    ,p_name       => p_name
    ,p_first_name => p_first_name
    ,p_last_name  => p_last_name
    ,p_id         => p_id
    ,p_send_by    => 'cc');
end send_cc;

procedure send_bcc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ) is
begin
  add_recipient
    (p_email      => p_email
    ,p_name       => p_name
    ,p_first_name => p_first_name
    ,p_last_name  => p_last_name
    ,p_id         => p_id
    ,p_send_by    => 'bcc');
end send_bcc;

function attachment_header
  (p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean
  ) return varchar2 is
begin

  assert(p_file_name is not null, 'attachment_header: p_file_name cannot be null');
  assert(p_content_type is not null, 'attachment_header: p_content_type cannot be null');

  return '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="'
    || case when p_inline then 'inline' else 'attachment' end
    || '"; filename="' || p_file_name || '"' || crlf
    || 'Content-Type: ' || p_content_type || crlf
    || crlf;

end attachment_header;

procedure attach
  (p_file_content in blob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  r t_mailgun_attachment;
begin
  msg('attach(blob) ' || p_file_name);
  
  assert(p_file_content is not null, 'attach(blob): p_file_content cannot be null');

  r := t_mailgun_attachment
    ( p_file_content
    , null /*clob*/
    , attachment_header
      (p_file_name    => p_file_name
      ,p_content_type => p_content_type
      ,p_inline       => p_inline)
    );
  
  if g_attachment is null then
    g_attachment := t_mailgun_attachment_arr();
  end if;
  g_attachment.extend(1);
  g_attachment(g_attachment.last) := r;
  
end attach;

procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  r t_mailgun_attachment;
begin
  msg('attach(clob) ' || p_file_name);

  assert(p_file_content is not null, 'attach(clob): p_file_content cannot be null');

  r := t_mailgun_attachment
    ( null /*blob*/
    , p_file_content
    , attachment_header
      (p_file_name    => p_file_name
      ,p_content_type => p_content_type
      ,p_inline       => p_inline)
    );
  
  if g_attachment is null then
    g_attachment := t_mailgun_attachment_arr();
  end if;
  g_attachment.extend(1);
  g_attachment(g_attachment.last) := r;
  
end attach;

procedure create_queue is
begin
  msg('create_queue ' || queue_name);

  dbms_aqadm.create_queue_table
    (queue_table        => user||'.'||queue_table
    ,queue_payload_type => user||'.'||payload_type
    ,storage_clause     => 'nested table user_data.recipient store as mailgun_recipient_tab'
                        ||',nested table user_data.attachment store as mailgun_attachment_tab'
    );

  dbms_aqadm.create_queue
    (queue_name     =>  user||'.'||queue_name
    ,queue_table    =>  user||'.'||queue_table
    ,max_retries    =>  60 --allow failures before giving up on a message
    ,retry_delay    =>  10 --wait seconds before trying this message again
    );

  dbms_aqadm.start_queue (user||'.'||queue_name);

end create_queue;

procedure drop_queue is
begin
  msg('drop_queue ' || queue_name);
  
  dbms_aqadm.stop_queue (user||'.'||queue_name);
  
  dbms_aqadm.drop_queue (user||'.'||queue_name);
  
  dbms_aqadm.drop_queue_table (user||'.'||queue_table);  

end drop_queue;

procedure purge_queue is
  v_opt dbms_aqadm.aq$_purge_options_t;
begin
  msg('purge_queue ' || queue_table);

  dbms_aqadm.purge_queue_table
    (queue_table     => user||'.'||queue_table
    ,purge_condition => q'[ qtview.msg_state = 'EXPIRED' ]'
    ,purge_options   => v_opt);

end purge_queue;

procedure push_queue as
  r_dequeue_options    dbms_aq.dequeue_options_t;
  r_message_properties dbms_aq.message_properties_t;
  l_msgid              raw(16);
  l_payload            t_mailgun_email;
  l_msg                varchar2(4000);
  l_resp               varchar2(4000);
begin
  msg('push_queue');
  
  r_dequeue_options.wait := dbms_aq.no_wait;

  -- loop through all messages in the queue until there is none
  -- exit this loop when the e_no_queue_data exception is raised.
  loop    

    dbms_aq.dequeue
      (queue_name         => user||'.'||queue_name
      ,dequeue_options    => r_dequeue_options
      ,message_properties => r_message_properties
      ,payload            => l_payload
      ,msgid              => l_msgid
      );

    -- process the message
    send_email_synchronous (l_payload);  

    commit; -- the queue will treat the message as succeeded

  end loop;

exception
  when e_no_queue_data then
    msg('push_queue finished');
  when others then
    rollback;
    msg(sqlerrm);
    msg(dbms_utility.format_error_stack);
    msg(dbms_utility.format_error_backtrace);
    raise;
end push_queue;

procedure create_job (repeat_interval in varchar2 := repeat_interval_default) is
begin
  msg('create_job ' || job_name);

  dbms_scheduler.create_job
    (job_name        => job_name
    ,job_type        => 'PLSQL_BLOCK'
    ,job_action      => 'begin '||$$PLSQL_UNIT||'.push_queue; end;'
    ,start_date      => systimestamp
    ,repeat_interval => repeat_interval
    );

  dbms_scheduler.set_attribute(job_name,'restartable',true);

  dbms_scheduler.enable(job_name);

end create_job;

procedure drop_job is
begin
  msg('drop_job ' || job_name);

  dbms_scheduler.drop_job (job_name);

end drop_job;

procedure reset is
begin
  msg('reset');
  
  if g_recipient is not null then
    g_recipient.delete;
  end if;
  
  if g_attachment is not null then
    g_attachment.delete;
  end if;

end reset;

procedure verbose (p_on in boolean := true) is
begin
  msg('verbose ' || apex_debug.tochar(p_on));
  
  g_verbose := p_on;

end verbose;

end mailgun_pkg;
/

show errors