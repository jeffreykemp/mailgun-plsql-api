create or replace package body mailgun_pkg is
/* mailgun API v0.6
  by Jeffrey Kemp
*/

-- If you get "PLS-00322: declaration of a constant 'x' must contain an initialization assignment",
-- it's probably because you forgot to edit the constants below.

g_public_api_key  constant varchar2(200) /*:= 'TODO: put your public API key here' */;
g_private_api_key constant varchar2(200) /*:= 'TODO: put your private API key here' */;
g_my_domain       constant varchar2(200) /*:= 'TODO: put your domain here' */;
g_api_url         constant varchar2(200) := 'https://api.mailgun.net/v3/'; --TODO: change this if you are using reverse proxy method
g_wallet_path     constant varchar2(1000) := ''; --TODO: put your wallet path here if using Oracle wallet
g_wallet_password constant varchar2(1000) := ''; --TODO: put your wallet password here if using Oracle wallet

boundary          constant varchar2(100) := '-----gjtvt1fu9f77frut4d45770ec7clc3p6nr11uhu476tzmp24nt';
max_recipients    constant integer := 1000; -- mailgun limitation for recipient variables
queue_name        constant varchar2(100) := sys_context('userenv','current_schema')||'.mailgun_queue';
queue_table       constant varchar2(100) := sys_context('userenv','current_schema')||'.mailgun_queue_tab';
job_name          constant varchar2(30) := 'mailgun_process_queue';
payload_type      constant varchar2(100) := sys_context('userenv','current_schema')||'.t_mailgun_email';
max_dequeue_count constant integer := 1000;

-- if true, log all data sent to/from mailgun server
g_verbose         boolean := false;

g_recipient       t_mailgun_recipient_arr;
g_attachment      t_mailgun_attachment_arr;

e_no_queue_data exception;
pragma exception_init (e_no_queue_data, -25228);

/******************************************************************************
**                                                                           **
**                              PRIVATE METHODS                              **
**                                                                           **
******************************************************************************/

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

function enc_chars (m in varchar2) return varchar2 is
begin
  return regexp_replace(asciistr(m),'\\([0-9A-F]{4})','&#x\1;');
end enc_chars;

function enc_chars (clob_content in clob) return clob is
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 8000;
  buf          varchar2(8000);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
  out_clob     clob;
begin
  msg('enc_chars[clob]');

  assert(clob_content is not null, 'enc_chars: clob_content cannot be null');
  dbms_lob.createtemporary(out_clob, false, dbms_lob.call);
  file_len := dbms_lob.getlength (clob_content);
  msg('enc_chars ' || file_len || ' bytes');
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    dbms_lob.read (clob_content, amt, filepos, buf);
    buf := enc_chars(buf);
    dbms_lob.writeappend(out_clob, length(buf), buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    dbms_lob.read (clob_content, modulo, filepos, buf);
    buf := enc_chars(buf);
    dbms_lob.writeappend(out_clob, length(buf), buf);
  end if;

  return out_clob;
end enc_chars;

function utc_to_session_tz (ts in varchar2) return timestamp is
begin
  return to_timestamp_tz(ts, 'Dy, dd Mon yyyy hh24:mi:ss tzr') at local;
end utc_to_session_tz;

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
  ,p_method in varchar2 := 'GET'
  ) return varchar2 is
  url   varchar2(4000) := p_url;
  req   utl_http.req;
  resp  utl_http.resp;
  buf   varchar2(32767);
begin
  msg('get_json ' || p_url || ' ' || p_params);
  
  assert(p_url is not null, 'get_json: p_url cannot be null');
  assert(p_method is not null, 'get_json: p_method cannot be null');
  
  if p_params is not null then
    url := url || '?' || p_params;
  end if;
  
  set_wallet;

  req := utl_http.begin_request(url => url, method => p_method);

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

function rcpt_count return number is
begin
  if g_recipient is not null then
    return g_recipient.count;
  end if;
  return 0;
end rcpt_count;

function attch_count return number is
begin
  if g_attachment is not null then
    return g_attachment.count;
  end if;
  return 0;
end attch_count;

procedure add_recipient
  (p_email      in varchar2
  ,p_name       in varchar2
  ,p_first_name in varchar2
  ,p_last_name  in varchar2
  ,p_id         in varchar2
  ,p_send_by    in varchar2
  ) is
  name varchar2(4000);
begin
  msg('add_recipient ' || p_send_by || ': ' || p_name || ' <' || p_email || '> #' || p_id);
  
  assert(rcpt_count < max_recipients, 'maximum recipients per email exceeded (' || max_recipients || ')');
  
  assert(p_email is not null, 'add_recipient: p_email cannot be null');
  assert(p_send_by is not null, 'add_recipient: p_send_by cannot be null');
  assert(p_send_by in ('to','cc','bcc'), 'p_send_by must be to/cc/bcc');

  -- don't allow a list of email addresses in one call
  assert(instr(p_email,',')=0, 'add_recipient: p_email cannot contain commas (,)');
  assert(instr(p_email,';')=0, 'add_recipient: p_email cannot contain semicolons (;)');
  
  name := nvl(p_name, trim(p_first_name || ' ' || p_last_name));

  if g_recipient is null then
    g_recipient := t_mailgun_recipient_arr();
  end if;
  g_recipient.extend(1);
  g_recipient(g_recipient.last) := t_mailgun_recipient
    ( send_by     => p_send_by
    , email_spec  => case when p_email like '% <%>'
                     then p_email
                     else nvl(name, p_email) || ' <' || p_email || '>'
                     end
    , email       => case when p_email like '% <%>'
                     then rtrim(ltrim(regexp_substr(p_email, '<.*>', 1, 1), '<'), '>')
                     else p_email
                     end
    , name        => name
    , first_name  => p_first_name
    , last_name   => p_last_name
    , id          => p_id
    );

end add_recipient;

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

procedure add_attachment
  (p_file_name    in varchar2
  ,p_blob_content in blob := null
  ,p_clob_content in clob := null
  ,p_content_type in varchar2
  ,p_inline       in boolean
  ) is
begin
  msg('add_attachment ' || p_file_name);

  if g_attachment is null then
    g_attachment := t_mailgun_attachment_arr();
  end if;
  g_attachment.extend(1);
  g_attachment(g_attachment.last) := t_mailgun_attachment
    ( file_name     => p_file_name
    , blob_content  => p_blob_content
    , clob_content  => p_clob_content
    , header        => attachment_header
        (p_file_name    => p_file_name
        ,p_content_type => p_content_type
        ,p_inline       => p_inline)
    );

end add_attachment;

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

function render_mail_headers (mail_headers in varchar2) return varchar2 is
  vals apex_json.t_values;
  tag  varchar2(32767);
  val  apex_json.t_value;
  buf  varchar2(32767);
begin
  msg('render_mail_headers');

  apex_json.parse(vals, mail_headers);

  tag := vals.first;
  loop
    exit when tag is null;

    val := vals(tag);

    -- Mailgun accepts arbitrary MIME headers with the "h:" prefix, e.g.
    -- h:Priority
    case val.kind
    when apex_json.c_varchar2 then
      msg('h:'||tag||' = ' || val.varchar2_value);
      buf := buf || form_field('h:'||tag, val.varchar2_value);
    when apex_json.c_number then
      msg('h:'||tag||' = ' || val.number_value);
      buf := buf || form_field('h:'||tag, to_char(val.number_value));
    else
      null;
    end case;

    tag := vals.next(tag);
  end loop;
  
  return buf;
end render_mail_headers;

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

procedure send_email (p_payload in out nocopy t_mailgun_email) is
  url              varchar2(32767) := g_api_url || g_my_domain || '/messages';
  header           clob;
  sender           varchar2(4000);
  recipients_to    varchar2(32767);
  recipients_cc    varchar2(32767);
  recipients_bcc   varchar2(32767);
  footer           varchar2(100);
  req              utl_http.req;
  resp             utl_http.resp;
  my_scheme        varchar2(256);
  my_realm         varchar2(256);
  attachment_size  integer;
  resp_text        varchar2(32767);
  recipient_count  integer := 0;
  attachment_count integer := 0;
  log              mailgun_email_log%rowtype;

  procedure append_recipient (rcpt_list in out varchar2, r in t_mailgun_recipient) is
  begin    
    if rcpt_list is not null then
      rcpt_list := rcpt_list || ',';
    end if;
    rcpt_list := rcpt_list || r.email_spec;
  end append_recipient;
  
  procedure add_recipient_variable (r in t_mailgun_recipient) is
  begin    
    apex_json.open_object(r.email);
    apex_json.write('email',      r.email);
    apex_json.write('name',       r.name);
    apex_json.write('first_name', r.first_name);
    apex_json.write('last_name',  r.last_name);
    apex_json.write('id',         r.id);
    apex_json.close_object;
  end add_recipient_variable;
  
  procedure append_header (buf in varchar2) is
  begin
    dbms_lob.writeappend(header, length(buf), buf);
  end append_header;
  
  procedure log_response (p_sqlerrm in varchar2 := null) is
    -- needs to commit the log entry independently of calling transaction
    pragma autonomous_transaction;
  begin
    msg('log_response ' || p_sqlerrm);

    log.requested_ts    := p_payload.requested_ts;
    log.from_name       := p_payload.reply_to;
    log.from_email      := p_payload.from_email;
    log.reply_to        := p_payload.reply_to;
    log.to_name         := p_payload.to_name;
    log.to_email        := p_payload.to_email;
    log.cc              := p_payload.cc;
    log.bcc             := p_payload.bcc;
    log.subject         := p_payload.subject;
    log.message         := SUBSTR(p_payload.message, 1, 4000);
    log.tag             := p_payload.tag;
    log.mail_headers    := SUBSTR(p_payload.mail_headers, 1, 4000);
    log.recipients      := SUBSTR(recipients_to, 1, 4000);

    if p_sqlerrm is null then

      log.sent_ts  := systimestamp;

      apex_json.parse( resp_text );
      log.mailgun_id      := apex_json.get_varchar2('id');
      log.mailgun_message := apex_json.get_varchar2('message');
    
      msg('response: ' || log.mailgun_message);
      msg('msg id: ' || log.mailgun_id);
     
    else
    
      log.mailgun_message := p_sqlerrm;
    
    end if;

    insert into mailgun_email_log values log;
    msg('inserted mailgun_email_log: ' || sql%rowcount);

    msg('commit');
    commit;
    
  end log_response;

begin
  msg('send_email(payload) ' || p_payload.to_email || ' "' || p_payload.subject || '"');
  
  assert(g_private_api_key is not null, 'send_email: your mailgun private API key not set');
  assert(g_my_domain is not null, 'send_email: your mailgun domain not set');
  assert(p_payload.from_email is not null, 'send_email: from_email cannot be null');
  
  if p_payload.recipient is not null then
    recipient_count := p_payload.recipient.count;
  end if;

  if p_payload.attachment is not null then
    attachment_count := p_payload.attachment.count;
  end if;
  
  if p_payload.from_email like '% <%>%' then
    sender := p_payload.from_email;
  else
    sender := nvl(p_payload.from_name,p_payload.from_email) || ' <'||p_payload.from_email||'>';
  end if;

  if p_payload.to_email is not null then
    assert(recipient_count = 0, 'cannot mix multiple recipients with to_email parameter');

    if p_payload.to_name is not null 
    and p_payload.to_email not like '% <%>%'
    and instr(p_payload.to_email, ',') = 0
    and instr(p_payload.to_email, ';') = 0 then
      -- to_email is just a single, simple email address, and we have a to_name
      recipients_to := nvl(p_payload.to_name, p_payload.to_email) || ' <' || p_payload.to_email || '>';
    else
      -- to_email is a formatted name+email, or a list, or we don't have any to_name
      recipients_to := replace(p_payload.to_email, ';', ',');
    end if;

  end if;

  recipients_cc  := replace(p_payload.cc, ';', ',');
  recipients_bcc := replace(p_payload.bcc, ';', ',');
  
  if recipient_count > 0 then
    for i in 1..recipient_count loop
      -- construct the comma-delimited recipient lists
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
  
  dbms_lob.createtemporary(header, false, dbms_lob.call);

  append_header(crlf
    || form_field('from', sender)
    || form_field('h:Reply-To', p_payload.reply_to)
    || form_field('to', recipients_to)
    || form_field('cc', recipients_cc)
    || form_field('bcc', recipients_bcc)
    || form_field('o:tag', p_payload.tag)
    || form_field('subject', p_payload.subject)
    );
    
  if recipient_count > 0 then
    begin
      -- construct the recipient variables json object
      apex_json.initialize_clob_output;
      apex_json.open_object;  
      for i in 1..recipient_count loop
        add_recipient_variable(p_payload.recipient(i));
      end loop;      
      apex_json.close_object;

      append_header(field_header('recipient-variables'));
      dbms_lob.append(header, apex_json.get_clob_output);
      
      apex_json.free_output;     
    exception
      when others then
        apex_json.free_output;
        raise;
    end;
  end if;

  if p_payload.mail_headers is not null then
    append_header(render_mail_headers(p_payload.mail_headers));
  end if;

  append_header(field_header('html'));
  dbms_lob.append(header, p_payload.message);
  append_header(crlf);

  footer := '--' || boundary || '--';

  -- encode characters (like MS Word "smart quotes") that the mail system can't handle
  header := enc_chars(header);
  
  log.total_bytes := dbms_lob.getlength(header)
                   + length(footer);

  if attachment_count > 0 then
    for i in 1..attachment_count loop

      if p_payload.attachment(i).clob_content is not null then
        attachment_size := dbms_lob.getlength(p_payload.attachment(i).clob_content);
      elsif p_payload.attachment(i).blob_content is not null then
        attachment_size := dbms_lob.getlength(p_payload.attachment(i).blob_content);
      end if;

      log.total_bytes := log.total_bytes
                       + length(p_payload.attachment(i).header)
                       + attachment_size
                       + length(crlf);
      
      if log.attachments is not null then
        log.attachments := log.attachments || ', ';
      end if;
      log.attachments := log.attachments || p_payload.attachment(i).file_name || ' (' || attachment_size || ' bytes)';

    end loop;
  end if;
  
  msg('content_length=' || log.total_bytes);

  -- Turn off checking of status code. We will check it by ourselves.
  utl_http.set_response_error_check(false);

  set_wallet;
  
  req := utl_http.begin_request(url, 'POST');
  
  utl_http.set_authentication(req, 'api', g_private_api_key); -- Use HTTP Basic Authen. Scheme
  
  utl_http.set_header(req, 'Content-Type', 'multipart/form-data; boundary="' || boundary || '"');
  utl_http.set_header(req, 'Content-Length', log.total_bytes);
  
  msg('writing message contents...');
  
  write_clob(req, header);

  dbms_lob.freetemporary(header);

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

  begin
    msg('reading response from server...');
    resp := utl_http.get_response(req);
    
    log_headers(resp);

    if resp.status_code = utl_http.http_unauthorized then
      utl_http.get_authentication(resp, my_scheme, my_realm, false);
      msg('Unauthorized: please supply the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.');
      raise_application_error(-20000, 'unauthorized');
    elsif resp.status_code = utl_http.http_proxy_auth_required then
      utl_http.get_authentication(resp, my_scheme, my_realm, true);
      msg('Proxy auth required: please supplied the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.');
      raise_application_error(-20000, 'proxy auth required');
    end if;
    
    if resp.status_code != '200' then
      raise_application_error(-20000, 'post failed ' || resp.status_code || ' ' || resp.reason_phrase || ' [' || url || ']');
    end if;
    
    -- expected response will be a json document like this:
    --{
    --  "id": "<messageid@domain>",
    --  "message": "Queued. Thank you."
    --}
    resp_text := get_response(resp);

  exception
    when others then
      utl_http.end_response(resp);
      raise;
  end;

  log_response;
  
  msg('send_email(payload) finished');
exception
  when others then
    log_response(p_sqlerrm => SQLERRM);
    if header is not null then
      dbms_lob.freetemporary(header);
    end if;
    raise;
end send_email;

/******************************************************************************
**                                                                           **
**                              PUBLIC METHODS                               **
**                                                                           **
******************************************************************************/

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
  ) is
  enq_opts        dbms_aq.enqueue_options_t;
  enq_msg_props   dbms_aq.message_properties_t;
  payload         t_mailgun_email;
  msgid           raw(16);
begin
  msg('send_email ' || p_to_email || ' "' || p_subject || '"');
  
  assert(g_private_api_key is not null, 'send_email: your mailgun private API key not set');
  assert(g_my_domain is not null, 'send_email: your mailgun domain not set');
  assert(p_from_email is not null, 'send_email: p_from_email cannot be null');

  if p_to_email is not null then
    assert(rcpt_count = 0, 'cannot mix multiple recipients with p_to_email parameter');
  else
    assert(rcpt_count > 0, 'must be at least one recipient');
  end if;
  
  payload := t_mailgun_email
    ( requested_ts => systimestamp
    , from_name    => p_from_name
    , from_email   => p_from_email
    , reply_to     => p_reply_to
    , to_name      => p_to_name
    , to_email     => p_to_email
    , cc           => p_cc
    , bcc          => p_bcc
    , subject      => p_subject
    , message      => p_message
    , tag          => p_tag
    , mail_headers => p_mail_headers
    , recipient    => g_recipient
    , attachment   => g_attachment
    );

  reset;

  enq_msg_props.expiration := 6 * 60 * 60; -- expire after 6 hours
  enq_msg_props.priority   := p_priority;

  dbms_aq.enqueue
    (queue_name         => queue_name
    ,enqueue_options    => enq_opts
    ,message_properties => enq_msg_props
    ,payload            => payload
    ,msgid              => msgid
    );
  
  msg('email queued ' || msgid);
  
  msg('send_email finished');
exception
  when others then
    msg(sqlerrm);
    msg(dbms_utility.format_error_stack);
    msg(dbms_utility.format_error_backtrace);
    raise;
end send_email;

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

procedure attach
  (p_file_content in blob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
begin
  msg('attach(blob) ' || p_file_name || ' ' || dbms_lob.getlength(p_file_content) || ' bytes');
  
  assert(p_file_content is not null, 'attach(blob): p_file_content cannot be null');
  
  add_attachment
    (p_file_name    => p_file_name
    ,p_blob_content => p_file_content
    ,p_content_type => p_content_type
    ,p_inline       => p_inline
    );
  
end attach;

procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
begin
  msg('attach(clob) ' || p_file_name || ' ' || dbms_lob.getlength(p_file_content) || ' bytes');

  assert(p_file_content is not null, 'attach(clob): p_file_content cannot be null');

  add_attachment
    (p_file_name    => p_file_name
    ,p_clob_content => p_file_content
    ,p_content_type => p_content_type
    ,p_inline       => p_inline
    );
  
end attach;

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

procedure create_queue
  (p_max_retries in number := default_max_retries
  ,p_retry_delay in number := default_retry_delay
  ) is
begin
  msg('create_queue ' || queue_name);

  dbms_aqadm.create_queue_table
    (queue_table        => queue_table
    ,queue_payload_type => payload_type
    ,sort_list          => 'priority,enq_time'
    ,storage_clause     => 'nested table user_data.recipient store as mailgun_recipient_tab'
                        ||',nested table user_data.attachment store as mailgun_attachment_tab'
    );

  dbms_aqadm.create_queue
    (queue_name     =>  queue_name
    ,queue_table    =>  queue_table
    ,max_retries    =>  p_max_retries
    ,retry_delay    =>  p_retry_delay
    );

  dbms_aqadm.start_queue (queue_name);

end create_queue;

procedure drop_queue is
begin
  msg('drop_queue ' || queue_name);
  
  dbms_aqadm.stop_queue (queue_name);
  
  dbms_aqadm.drop_queue (queue_name);
  
  dbms_aqadm.drop_queue_table (queue_table);  

end drop_queue;

procedure purge_queue (p_msg_state IN VARCHAR2 := default_purge_msg_state) is
  r_opt dbms_aqadm.aq$_purge_options_t;
begin
  msg('purge_queue ' || queue_table);

  dbms_aqadm.purge_queue_table
    (queue_table     => queue_table
    ,purge_condition => case when p_msg_state is not null
                        then replace(q'[ qtview.msg_state = '#STATE#' ]'
                                    ,'#STATE#', p_msg_state)
                        end
    ,purge_options   => r_opt);

end purge_queue;

procedure push_queue (p_asynchronous in boolean := true) as
  r_dequeue_options    dbms_aq.dequeue_options_t;
  r_message_properties dbms_aq.message_properties_t;
  msgid                raw(16);
  payload              t_mailgun_email;
  dequeue_count        integer := 0;
  job                  binary_integer;
begin
  msg('push_queue');
  
  if p_asynchronous then
  
    dbms_job.submit
      (job  => job
      ,what => $$PLSQL_UNIT || '.push_queue(p_asynchronous=>false);'
      );
      
    msg('submitted job=' || job);
      
  else

    -- commit any emails requested in the current session
    commit;
    
    r_dequeue_options.wait := dbms_aq.no_wait;

    -- loop through all messages in the queue until there is none
    -- exit this loop when the e_no_queue_data exception is raised.
    loop    

      dbms_aq.dequeue
        (queue_name         => queue_name
        ,dequeue_options    => r_dequeue_options
        ,message_properties => r_message_properties
        ,payload            => payload
        ,msgid              => msgid
        );
      
      msg('payload priority: ' || r_message_properties.priority
        || ' enqeued: ' || to_char(r_message_properties.enqueue_time,'dd/mm/yyyy hh24:mi:ss')
        || ' attempts: ' || r_message_properties.attempts);

      -- process the message
      send_email (p_payload => payload);  

      commit; -- the queue will treat the message as succeeded
      
      -- don't bite off everything in one go
      dequeue_count := dequeue_count + 1;
      exit when dequeue_count >= max_dequeue_count;
    end loop;

  end if;
    
exception
  when e_no_queue_data then
    msg('push_queue finished count=' || dequeue_count);
  when others then
    rollback; -- the queue will treat the message as failed
    msg(sqlerrm);
    msg(dbms_utility.format_error_stack);
    msg(dbms_utility.format_error_backtrace);
    raise;
end push_queue;

procedure create_job
  (p_repeat_interval in varchar2 := repeat_interval_default) is
begin
  msg('create_job ' || job_name);
  
  assert(p_repeat_interval is not null, 'create_job: p_repeat_interval cannot be null');

  dbms_scheduler.create_job
    (job_name        => job_name
    ,job_type        => 'plsql_block'
    ,job_action      => 'begin '||$$PLSQL_UNIT||'.push_queue(p_asynchronous=>false); end;'
    ,start_date      => systimestamp
    ,repeat_interval => p_repeat_interval
    );

  dbms_scheduler.set_attribute(job_name,'restartable',true);

  dbms_scheduler.enable(job_name);

end create_job;

procedure drop_job is
begin
  msg('drop_job ' || job_name);

  begin
    dbms_scheduler.stop_job (job_name);
  exception
    when others then
      if sqlcode != -27366 /*job already stopped*/ then
        raise;
      end if;
  end;
  
  dbms_scheduler.drop_job (job_name);

end drop_job;

function get_epoch (p_date in date) return number as
  /*
  Purpose: get epoch (number of seconds since January 1, 1970)
  Credit: Alexandria PL/SQL Library (AMAZON_AWS_AUTH_PKG)
  https://github.com/mortenbra/alexandria-plsql-utils
  Who     Date        Description
  ------  ----------  -------------------------------------
  MBR     09.01.2011  Created
  */
begin
  return trunc((p_date - date'1970-01-01') * 24 * 60 * 60);
end get_epoch;

function epoch_to_dt (p_epoch in number) return date as
begin
  return date'1970-01-01' + (p_epoch / 24 / 60 / 60);
end epoch_to_dt;

procedure url_param (buf in out varchar2, attr in varchar2, val in varchar2) is
begin
  if val is not null then
    if buf is not null then
      buf := buf || '&';
    end if;
    buf := buf || attr || '=' || apex_util.url_encode(val);
  end if;
end url_param;

procedure url_param (buf in out varchar2, attr in varchar2, dt in date) is
begin
  if dt is not null then
    if buf is not null then
      buf := buf || '&';
    end if;
    buf := buf || attr || '=' || get_epoch(dt);
  end if;
end url_param;

-- get mailgun stats
function get_stats
  (p_event_types     in varchar2 := 'all'
  ,p_resolution      in varchar2 := null
  ,p_start_time      in date     := null
  ,p_end_time        in date     := null
  ,p_duration        in number   := null
  ) return t_mailgun_stat_arr is

  prm    varchar2(4000);
  str    clob;
  cnt    number;
  arr    t_mailgun_stat_arr := t_mailgun_stat_arr();
  res    varchar2(10);
  dt     date;

  procedure emit (i in integer, stat_name in varchar2, stat_detail in varchar2) is
    val number;
  begin
    val := apex_json.get_number(p_path=>'stats[%d].'||stat_name||'.'||stat_detail, p0=>i);
    if val > 0 then
      arr.EXTEND(1);
      arr(arr.LAST) := t_mailgun_stat
        ( stat_datetime => dt
        , resolution    => res
        , stat_name     => stat_name
        , stat_detail   => stat_detail
        , val           => val
        );
    end if;
  end emit;
begin
  assert(p_event_types is not null, 'p_event_types cannot be null');
  assert(p_resolution in ('hour','day','month'), 'p_resolution must be day, month or hour');
  assert(p_start_time is null or p_duration is null, 'p_start_time or p_duration may be set but not both');
  assert(p_duration >= 1 and p_duration = trunc(p_duration), 'p_duration must be a positive integer');
  
  if lower(p_event_types) = 'all' then
    prm := 'accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored';
  else
    prm := replace(lower(p_event_types),' ','');
  end if;
  -- convert comma-delimited list to parameter list
  prm := 'event=' || replace(apex_util.url_encode(prm), ',', '&'||'event=');
  
  url_param(prm, 'start', p_start_time);
  url_param(prm, 'end', p_end_time);
  url_param(prm, 'resolution', p_resolution);
  if p_duration is not null then
    url_param(prm, 'duration', p_duration || substr(p_resolution,1,1));
  end if;

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/stats/total'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);
  
  apex_json.parse(str);
  
  cnt := apex_json.get_count('stats');
  res := apex_json.get_varchar2('resolution');
  
  for i in 1..cnt loop
    dt := utc_to_session_tz(apex_json.get_varchar2(p_path=>'stats[%d].time',p0=>i));
    emit(i,'accepted','incoming');
    emit(i,'accepted','outgoing');
    emit(i,'accepted','total');
    emit(i,'delivered','smtp');
    emit(i,'delivered','http');
    emit(i,'delivered','total');
    emit(i,'failed.temporary','espblock');
    emit(i,'failed.permanent','suppress-bounce');
    emit(i,'failed.permanent','suppress-unsubscribe');
    emit(i,'failed.permanent','suppress-complaint');
    emit(i,'failed.permanent','bounce');
    emit(i,'failed.permanent','total');
    emit(i,'stored','total');
    emit(i,'opened','total');
    emit(i,'clicked','total');
    emit(i,'unsubscribed','total');
    emit(i,'complained','total');
  end loop;

  return arr;
end get_stats;

-- get mailgun stats
function get_tag_stats
  (p_tag             in varchar2
  ,p_event_types     in varchar2 := 'all'
  ,p_resolution      in varchar2 := null
  ,p_start_time      in date     := null
  ,p_end_time        in date     := null
  ,p_duration        in number   := null
  ) return t_mailgun_stat_arr is

  prm    varchar2(4000);
  str    clob;
  cnt    number;
  arr    t_mailgun_stat_arr := t_mailgun_stat_arr();
  res    varchar2(10);
  dt     date;

  procedure emit (i in integer, stat_name in varchar2, stat_detail in varchar2) is
    val number;
  begin
    val := apex_json.get_number(p_path=>'stats[%d].'||stat_name||'.'||stat_detail, p0=>i);
    if val > 0 then
      arr.EXTEND(1);
      arr(arr.LAST) := t_mailgun_stat
        ( stat_datetime => dt
        , resolution    => res
        , stat_name     => stat_name
        , stat_detail   => stat_detail
        , val           => val
        );
    end if;
  end emit;
begin
  assert(p_tag is not null, 'p_tag cannot be null');
  assert(instr(p_tag,' ') = 0, 'p_tag cannot contain spaces');
  assert(p_event_types is not null, 'p_event_types cannot be null');
  assert(p_resolution in ('hour','day','month'), 'p_resolution must be day, month or hour');
  assert(p_start_time is null or p_duration is null, 'p_start_time or p_duration may be set but not both');
  assert(p_duration >= 1 and p_duration = trunc(p_duration), 'p_duration must be a positive integer');
  
  if lower(p_event_types) = 'all' then
    prm := 'accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored';
  else
    prm := replace(lower(p_event_types),' ','');
  end if;
  -- convert comma-delimited list to parameter list
  prm := 'event=' || replace(apex_util.url_encode(prm), ',', '&'||'event=');
  
  url_param(prm, 'start', p_start_time);
  url_param(prm, 'end', p_end_time);
  url_param(prm, 'resolution', p_resolution);
  if p_duration is not null then
    url_param(prm, 'duration', p_duration || substr(p_resolution,1,1));
  end if;

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/tags/' || apex_util.url_encode(p_tag) || '/stats'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);
  
  apex_json.parse(str);

  cnt := apex_json.get_count('stats');
  res := apex_json.get_varchar2('resolution');
  
  for i in 1..cnt loop
    dt := utc_to_session_tz(apex_json.get_varchar2(p_path=>'stats[%d].time',p0=>i));
    emit(i,'accepted','incoming');
    emit(i,'accepted','outgoing');
    emit(i,'accepted','total');
    emit(i,'delivered','smtp');
    emit(i,'delivered','http');
    emit(i,'delivered','total');
    emit(i,'failed.temporary','espblock');
    emit(i,'failed.permanent','suppress-bounce');
    emit(i,'failed.permanent','suppress-unsubscribe');
    emit(i,'failed.permanent','suppress-complaint');
    emit(i,'failed.permanent','bounce');
    emit(i,'failed.permanent','total');
    emit(i,'stored','total');
    emit(i,'opened','total');
    emit(i,'clicked','total');
    emit(i,'unsubscribed','total');
    emit(i,'complained','total');
  end loop;

  return arr;
end get_tag_stats;

-- return a comma-delimited string based on the array found at p_path (must already contain a %d), with
-- all values for the given attribute
function json_arr_str
  (p_path in varchar2
  ,p0     in varchar2
  ,p_attr in varchar2
  ) return varchar2 is
  cnt number;
  buf varchar2(32767);
begin
  cnt := apex_json.get_count(p_path, p0);
  for i in 1..cnt loop
    if buf is not null then
      buf := buf || ',';
    end if;
    buf := buf || apex_json.get_varchar2(p_path || '[%d].' || p_attr, p0, i);
  end loop;
  return buf;
end json_arr_str;

-- comma-delimited list of attributes
function json_members_list
  (p_path in varchar2
  ,p0     in varchar2
  ) return varchar2 is
  arr wwv_flow_t_varchar2;
  buf varchar2(32767);
begin
  arr := apex_json.get_members(p_path, p0);
  if arr.count > 0 then
    for i in 1..arr.count loop
      if buf is not null then
        buf := buf || ',';
      end if;
      buf := buf || arr(i);
    end loop;
  end if;
  return buf;
exception
  when value_error /*not an array or object*/ then
    return null;
end json_members_list;

-- comma-delimited list of attribute/value pairs
function json_value_pairs
  (p_path in varchar2
  ,p0     in varchar2
  ) return varchar2 is
  arr wwv_flow_t_varchar2;
  buf varchar2(32767);
begin
  arr := apex_json.get_members(p_path, p0);
  if arr.count > 0 then
    for i in 1..arr.count loop
      if buf is not null then
        buf := buf || ',';
      end if;
      buf := buf || arr(i) || ':' || apex_json.get_varchar2(p_path || '.' || arr(i), p0);
    end loop;
  end if;
  return buf;
exception
  when value_error /*not an array or object*/ then
    return null;
end json_value_pairs;

function get_events
  (p_start_time      in date     := null
  ,p_end_time        in date     := null
  ,p_page_size       in number   := default_page_size -- max 300
  ,p_event           in varchar2 := null
  ,p_sender          in varchar2 := null
  ,p_recipient       in varchar2 := null
  ,p_subject         in varchar2 := null
  ,p_tags            in varchar2 := null
  ,p_severity        in varchar2 := null
  ) return t_mailgun_event_arr pipelined is

  prm  varchar2(4000);
  str  clob;
  cnt  number;
  url  varchar2(4000);

begin
  assert(p_page_size <= 300, 'p_page_size cannot be greater than 300 (' || p_page_size || ')');
  assert(p_severity in ('temporary','permanent'), 'p_severity must be "temporary" or "permanent"');
  
  url_param(prm, 'begin', p_start_time);
  url_param(prm, 'end', p_end_time);
  url_param(prm, 'limit', p_page_size);
  url_param(prm, 'event', p_event);
  url_param(prm, 'from', p_sender);
  url_param(prm, 'recipient', p_recipient);
  url_param(prm, 'subject', p_subject);
  url_param(prm, 'tags', p_tags);
  url_param(prm, 'severity', p_severity);
  
  -- url to get first page of results
  url := g_api_url || g_my_domain || '/events';
  
  loop
  
    str := get_json
      (p_url    => url
      ,p_params => prm
      ,p_user   => 'api'
      ,p_pwd    => g_private_api_key);  

    apex_json.parse(str);

    cnt := apex_json.get_count('items');
    
    exit when cnt = 0;
    
    for i in 1..cnt loop
      pipe row (t_mailgun_event
        ( event                => substr(apex_json.get_varchar2('items[%d].event', i), 1, 100)
        , event_ts             => epoch_to_dt(apex_json.get_number('items[%d].timestamp', i))
        , event_id             => substr(apex_json.get_varchar2('items[%d].id', i), 1, 200)
        , message_id           => substr(apex_json.get_varchar2('items[%d].message.headers."message-id"', i), 1, 200)
        , sender               => substr(apex_json.get_varchar2('items[%d].envelope.sender', i), 1, 4000)
        , recipient            => substr(apex_json.get_varchar2('items[%d].recipient', i), 1, 4000)
        , subject              => substr(apex_json.get_varchar2('items[%d].message.headers.subject', i), 1, 4000)
        , attachments          => substr(json_arr_str('items[%d].message.attachments', i, 'filename'), 1, 4000)
        , size_bytes           => apex_json.get_number('items[%d].message.size', i)
        , method               => substr(apex_json.get_varchar2('items[%d].method', i), 1, 100)
        , tags                 => substr(json_members_list('items[%d].tags', i), 1, 4000)
        , user_variables       => substr(json_value_pairs('items[%d]."user-variables"', i), 1, 4000)
        , log_level            => substr(apex_json.get_varchar2('items[%d]."log-level"', i), 1, 100)
        , failed_severity      => substr(apex_json.get_varchar2('items[%d].severity', i), 1, 100)
        , failed_reason        => substr(apex_json.get_varchar2('items[%d].reason', i), 1, 100)
        , delivery_status      => substr(trim(apex_json.get_varchar2('items[%d]."delivery-status".code', i)
                                    || ' ' || apex_json.get_varchar2('items[%d]."delivery-status".message', i)
                                    || ' ' || apex_json.get_varchar2('items[%d]."delivery-status".description', i)
                                             ),1, 4000)
        , geolocation          => substr(trim(apex_json.get_varchar2('items[%d].geolocation.country', i)
                                    || ' ' || apex_json.get_varchar2('items[%d].geolocation.region', i)
                                    || ' ' || apex_json.get_varchar2('items[%d].geolocation.city', i)
                                             ), 1, 4000)
        , recipient_ip         => substr(apex_json.get_varchar2('items[%d].ip', i), 1, 100)
        , client_info          => substr(trim(apex_json.get_varchar2('items[%d]."client-info"."client-type"', i)
                                    || ' ' || apex_json.get_varchar2('items[%d]."client-info"."client-os"', i)
                                    || ' ' || apex_json.get_varchar2('items[%d]."client-info"."device-type"', i)
                                    || ' ' || apex_json.get_varchar2('items[%d]."client-info"."client-name"', i)
                                             ), 1, 4000)
        , client_user_agent    => substr(apex_json.get_varchar2('items[%d]."client-info"."user-agent"', i), 1, 4000)
        ));
    end loop;
    
    -- get next page of results
    prm := null;
    url := apex_json.get_varchar2('paging.next');    
    -- convert url to use reverse-apache version, if necessary
    url := replace(url, 'https://api.mailgun.net/v3/', g_api_url);
    exit when url is null;
  end loop;
    
  return;
end get_events;

function get_tags
  (p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_tag_arr pipelined is

  prm  varchar2(4000);
  str  clob;
  cnt  number;

begin
  url_param(prm, 'limit', p_limit);
  
  str := get_json
    (p_url    => g_api_url || g_my_domain || '/tags'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);

  apex_json.parse(str);

  cnt := apex_json.get_count('items');
  
  for i in 1..cnt loop
    pipe row (t_mailgun_tag
      ( tag_name    => substr(apex_json.get_varchar2('items[%d].tag', i), 1, 4000)
      , description => substr(apex_json.get_varchar2('items[%d].description', i), 1, 4000)
      ));
  end loop;
    
  return;
end get_tags;

procedure update_tag
  (p_tag         in varchar2
  ,p_description in varchar2 := null) is
  prm  varchar2(4000);
  str  clob;
begin
  assert(p_tag is not null, 'p_tag cannot be null');
  assert(instr(p_tag,' ') = 0, 'p_tag cannot contain spaces');

  url_param(prm, 'description', p_description);
  
  str := get_json
    (p_method => 'PUT'
    ,p_url    => g_api_url || g_my_domain || '/tags/' || apex_util.url_encode(p_tag)
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);
  
  -- normally it returns {"message":"Tag updated"}
end update_tag;

procedure delete_tag (p_tag in varchar2) is
  prm  varchar2(4000);
  str  clob;
begin
  assert(p_tag is not null, 'p_tag cannot be null');
  assert(instr(p_tag,' ') = 0, 'p_tag cannot contain spaces');
  
  str := get_json
    (p_method => 'DELETE'
    ,p_url    => g_api_url || g_my_domain || '/tags/' || apex_util.url_encode(p_tag)
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);
  
  -- normally it returns {"message":"Tag deleted"}
end delete_tag;

function get_suppressions
  (p_type  in varchar2 -- 'bounces', 'unsubscribes', or 'complaints'
  ,p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_suppression_arr pipelined is

  prm  varchar2(4000);
  str  clob;
  cnt  number;

begin
  assert(p_type is not null, 'p_type cannot be null');
  assert(p_type in ('bounces','unsubscribes','complaints'), 'p_type must be bounces, unsubscribes, or complaints');

  url_param(prm, 'limit', p_limit);
  
  str := get_json
    (p_url    => g_api_url || g_my_domain || '/' || p_type
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key);

  apex_json.parse(str);

  cnt := apex_json.get_count('items');
  
  for i in 1..cnt loop
    pipe row (t_mailgun_suppression
      ( suppression_type => substr(p_type, 1, length(p_type)-1)
      , email_address    => substr(apex_json.get_varchar2('items[%d].address', i), 1, 4000)
      , unsubscribe_tag  => substr(apex_json.get_varchar2('items[%d].tag', i), 1, 4000)
      , bounce_code      => substr(apex_json.get_varchar2('items[%d].code', i), 1, 255)
      , bounce_error     => substr(apex_json.get_varchar2('items[%d].error', i), 1, 4000)
      , created_dt       => utc_to_session_tz(apex_json.get_varchar2('items[%d].created_at', i))
      ));
  end loop;
    
  return;
end get_suppressions;

-- remove an email address from the bounce list
procedure delete_bounce (p_email_address in varchar2) is
  prm  varchar2(4000);
  str  clob;
begin
  assert(p_email_address is not null, 'p_email_address cannot be null');

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/bounces/' || apex_util.url_encode(p_email_address)
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key
    ,p_method => 'DELETE');

  -- normally it returns {"address":"...the address...","message":"Bounced address has been removed"}
end delete_bounce;

-- add an email address to the unsubscribe list
procedure add_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null
  ) is
  prm  varchar2(4000);
  str  clob;
begin
  assert(p_email_address is not null, 'p_email_address cannot be null');

  url_param(prm, 'address', p_email_address);
  url_param(prm, 'tag', p_tag);

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/unsubscribes'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key
    ,p_method => 'POST');

end add_unsubscribe;

-- remove an email address from the unsubscribe list
procedure delete_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null
  ) is
  prm  varchar2(4000);
  str  clob;
begin
  assert(p_email_address is not null, 'p_email_address cannot be null');

  url_param(prm, 'tag', p_tag);

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/unsubscribes/' || apex_util.url_encode(p_email_address)
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key
    ,p_method => 'DELETE');

  -- normally it returns {"message":"Unsubscribe event has been removed"}
end delete_unsubscribe;

-- remove an email address from the complaint list
procedure delete_complaint (p_email_address in varchar2) is
  str  clob;
begin
  assert(p_email_address is not null, 'p_email_address cannot be null');

  str := get_json
    (p_url    => g_api_url || g_my_domain || '/complaints/' || apex_util.url_encode(p_email_address)
    ,p_user   => 'api'
    ,p_pwd    => g_private_api_key
    ,p_method => 'DELETE');

  apex_json.parse(str);

  -- normally it returns {"message":"Spam complaint has been removed"}
end delete_complaint;

procedure verbose (p_on in boolean := true) is
begin
  msg('verbose ' || apex_debug.tochar(p_on));
  
  g_verbose := p_on;

end verbose;

end mailgun_pkg;
/

show errors
