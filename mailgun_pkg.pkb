create or replace package body mailgun_pkg is
/* mailgun API v0.2
  by Jeffrey Kemp

  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.
*/

-- Enter your mailgun public key here
g_public_api_key varchar2(200) := '';

-- Enter your mailgun secret key here
g_private_api_key varchar2(200) := '';

-- Enter your domain registered with mailgun here
g_my_domain varchar2(200) := '';

-- API Base URL (not including your domain)
g_api_url varchar2(200) := 'https://api.mailgun.net/v3/';

crlf constant varchar2(50) := chr(13) || chr(10);
boundary constant varchar2(30) := '-----v4np6rnptyb566a0y704sjeqv';
max_recipients constant integer := 1000; -- mailgun limitation for recipient variables

type t_v2arr is table of varchar2(32767) index by binary_integer;

type t_recipient is record
  (send_by    varchar2(3)    --to/cc/bcc
  ,email_spec varchar2(1000) -- name <email>
   -- mailgun recipient variables:
  ,email      varchar2(512) -- %recipient.email%
  ,name       varchar2(200) -- %recipient.name%
  ,first_name varchar2(200) -- %recipient.first_name%
  ,last_name  varchar2(200) -- %recipient.last_name%
  ,id         varchar2(200) -- %recipient.id%
  );

type t_attachment is record
  (blob_content blob
  ,clob_content clob
  ,header       varchar2(4000)
  );

type t_rcpt is table of t_recipient index by binary_integer;
type t_arr is table of t_attachment index by binary_integer;

g_recipient t_rcpt;
g_attachment t_arr;

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
  ) is
begin
  msg('init');
  
  g_public_api_key  := nvl(p_public_api_key, g_public_api_key);
  g_private_api_key := nvl(p_private_api_key, g_private_api_key);
  g_my_domain       := nvl(p_my_domain, g_my_domain);
  g_api_url         := nvl(p_api_url, g_api_url);

end init;

function get_json
  (p_url    in varchar2
  ,p_params in varchar2 := null
  ,p_user   in varchar2 := null
  ,p_pwd    in varchar2 := null
  ) return varchar2 is
  url   varchar2(4000) := p_url;
  req   utl_http.req;
  resp  utl_http.resp;
  name  varchar2(256);
  value varchar2(1024);
  buf   varchar2(32767);
begin
  msg('get_json ' || p_url);
  
  assert(p_url is not null, 'get_json: p_url cannot be null');
  
  if p_params is not null then
    url := url || '?' || p_params;
  end if;

  req := utl_http.begin_request (url=> url, method => 'GET');
  if p_user is not null or p_pwd is not null then
    utl_http.set_authentication(req, p_user, p_pwd);
  end if;
  utl_http.set_header (req,'Accept','application/json');

  resp := utl_http.get_response(req);
  msg('HTTP response: ' || resp.status_code || ' ' || resp.reason_phrase);

  for i in 1..utl_http.get_header_count(resp) loop
    utl_http.get_header(resp, i, name, value);
    msg(name || ': ' || value);
  end loop;

  if resp.status_code != '200' then
    raise_application_error(-20000, 'get_json call failed ' || resp.status_code || ' ' || resp.reason_phrase || ' [' || url || ']');
  end if;

  begin
    utl_http.read_text(resp, buf, 32767);
  exception
    when utl_http.end_of_body then
      null;
  end;
  utl_http.end_response(resp);

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
    msg(buf);
    utl_http.write_text(req, buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    dbms_lob.read (file_content, modulo, filepos, buf);
    msg(buf);
    utl_http.write_text(req, buf);
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

procedure send_email
  (p_from_name    in varchar2 := null
  ,p_from_email   in varchar2
  ,p_reply_to     in varchar2 := null
  ,p_to_name      in varchar2 := null
  ,p_to_email     in varchar2 := null
  ,p_cc           in varchar2 := null
  ,p_bcc          in varchar2 := null
  ,p_subject      in varchar2
  ,p_message      in clob
  ,p_tag          in varchar2 := null
  ) is
  url            varchar2(32767) := g_api_url || g_my_domain || '/messages';
  header         clob;
  sender         varchar2(4000);
  recipients_to  varchar2(32767);
  recipients_cc  varchar2(32767);
  recipients_bcc varchar2(32767);
  footer         varchar2(100);
  content_length integer;
  req            utl_http.req;
  resp           utl_http.resp;
  resp_started   boolean := false;
  my_scheme      varchar2(256);
  my_realm       varchar2(256);
  name           varchar2(256);
  value          varchar2(256);
  buf            varchar2(32767);

  procedure append_recipient (rcpt_list in out varchar2, r in t_recipient) is
  begin
    
    if rcpt_list is not null then
      rcpt_list := rcpt_list || ', ';
    end if;
    rcpt_list := rcpt_list || r.email_spec;
    
    apex_json.open_object(r.email);
    apex_json.write('email', r.email);
    apex_json.write('name', r.name);
    apex_json.write('first_name', r.first_name);
    apex_json.write('last_name', r.last_name);
    apex_json.write('id', r.id);
    apex_json.close_object;

  end append_recipient;

begin
  msg('send_email ' || p_to_email || ' "' || p_subject || '"');

  assert(g_private_api_key is not null, 'send_email: your mailgun private API key not set');
  assert(g_my_domain is not null, 'send_email: your mailgun domain not set');
  assert(p_from_email is not null, 'send_email: p_from_email cannot be null');
  
  if p_from_email like '% <%>%' then
    sender := p_from_email;
  else
    sender := nvl(p_from_name,p_from_email) || ' <'||p_from_email||'>';
  end if;

  if p_to_email is not null then
    send_to
      (p_email => p_to_email
      ,p_name  => p_to_name);
  end if;

  if p_cc is not null then
    send_cc(p_cc);
  end if;

  if p_bcc is not null then
    send_bcc(p_bcc);
  end if;
  
  apex_json.initialize_clob_output;
  apex_json.open_object;

  if g_recipient.count > 0 then
    for i in 1..g_recipient.count loop
      case g_recipient(i).send_by
      when 'to'  then append_recipient(recipients_to, g_recipient(i));
      when 'cc'  then append_recipient(recipients_cc, g_recipient(i));
      when 'bcc' then append_recipient(recipients_bcc, g_recipient(i));
      end case;
    end loop;
  end if;
  
  assert(recipients_to is not null, 'send_email: recipients list cannot be empty');
  
  apex_json.close_object;
  dbms_lob.createtemporary(header, false, dbms_lob.call);

  header := crlf
    || form_field('from', sender)
    || form_field('h:Reply-To', p_reply_to)
    || form_field('to', recipients_to)
    || form_field('cc', recipients_cc)
    || form_field('bcc', recipients_bcc)
    || form_field('o:tag', p_tag)
    || form_field('subject', p_subject)
    || field_header('recipient-variables');
  
  dbms_lob.append(header, apex_json.get_clob_output);

  buf := crlf || field_header('html');
  dbms_lob.writeappend(header, length(buf), buf);

  dbms_lob.append(header, p_message);

  dbms_lob.writeappend(header, length(crlf), crlf);

  footer := '--' || boundary || '--';
  
  content_length := dbms_lob.getlength(header)
                  + length(footer);

  if g_attachment.count > 0 then
    for i in 1..g_attachment.count loop

      content_length := content_length
                      + length(g_attachment(i).header)
                      + length(crlf);

      if g_attachment(i).clob_content is not null then
        content_length := content_length
                        + dbms_lob.getlength(g_attachment(i).clob_content);
      elsif g_attachment(i).blob_content is not null then
        content_length := content_length
                        + dbms_lob.getlength(g_attachment(i).blob_content);
      end if;

    end loop;
  end if;
  
  msg('content_length=' || content_length);

  -- Turn off checking of status code. We will check it by ourselves.
  utl_http.set_response_error_check(false);
  
  req := utl_http.begin_request(url, method=>'POST');
  
  utl_http.set_authentication(req, 'api', g_private_api_key); -- Use HTTP Basic Authen. Scheme
  
  utl_http.set_header(req, 'Content-Type', 'multipart/form-data; boundary="' || boundary || '"');
  utl_http.set_header(req, 'Content-Length', content_length);
  
  msg('writing message contents...');
  
  msg(header);
  write_clob(req, header);

  if g_attachment.count > 0 then
    for i in 1..g_attachment.count loop

      utl_http.write_text(req, g_attachment(i).header);

      if g_attachment(i).clob_content is not null then
        write_clob(req, g_attachment(i).clob_content);
      elsif g_attachment(i).blob_content is not null then
        write_blob(req, g_attachment(i).blob_content);
      end if;

      utl_http.write_text(req, crlf);

    end loop;
  end if;

  msg(footer);
  utl_http.write_text(req, footer);
  
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
  
  -- log any headers from the server
  for i in 1..utl_http.get_header_count(resp) loop
    utl_http.get_header(resp, i, name, value);
    msg(name || ': ' || value);
  end loop;
  
  -- log any response from the server
  begin
    utl_http.read_text (resp, buf, 32767);
    -- expected response will be a json document like this:
    --{
    --  "id": "<messageid@domain>",
    --  "message": "Queued. Thank you."
    --}
    msg(buf);
  exception
    when utl_http.end_of_body then
      null;
  end;
  utl_http.end_response (resp);
  
  reset;
  apex_json.free_output;
  dbms_lob.freetemporary(header);
  
  msg('send_email finished');
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
end send_email;

procedure add_recipient
  (p_email      in varchar2
  ,p_name       in varchar2
  ,p_first_name in varchar2
  ,p_last_name  in varchar2
  ,p_id         in varchar2
  ,p_send_by    in varchar2
  ) is
  r t_recipient;
begin
  msg('add_recipient ' || p_send_by || ': ' || p_name || ' <' || p_email || '> #' || p_id);
  
  assert(g_recipient.count < max_recipients, 'maximum recipients per email exceeded (' || max_recipients || ')');
  
  assert(p_email is not null, 'add_recipient: p_email cannot be null');
  assert(p_send_by is not null, 'add_recipient: p_send_by cannot be null');
  assert(p_send_by in ('to','cc','bcc'), 'p_send_by must be to/cc/bcc');

  r.send_by    := p_send_by;
  r.name       := nvl(p_name, trim(p_first_name || ' ' || p_last_name));
  r.first_name := p_first_name;
  r.last_name  := p_last_name;
  r.id         := p_id;
  if p_email like '% <%>' then
    r.email_spec := p_email;
    r.email      := rtrim(ltrim(regexp_substr(p_email, '<.*>', 1, 1), '<'), '>');
  else
    r.email_spec := nvl(r.name, p_email) || ' <' || p_email || '>';
    r.email      := p_email;
  end if;

  g_recipient(nvl(g_recipient.last,0)+1) := r;

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
  attachment t_attachment;
begin
  msg('attach');
  
  assert(p_file_content is not null, 'attach(blob): p_file_content cannot be null');
  
  attachment.header := attachment_header
    (p_file_name    => p_file_name
    ,p_content_type => p_content_type
    ,p_inline       => p_inline);
  attachment.blob_content := p_file_content;  
  
  g_attachment(nvl(g_attachment.last,0)+1) := attachment;
  
end attach;

procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  attachment t_attachment;
begin
  msg('attach');

  assert(p_file_content is not null, 'attach(clob): p_file_content cannot be null');
  
  attachment.header := attachment_header
    (p_file_name    => p_file_name
    ,p_content_type => p_content_type
    ,p_inline       => p_inline);
  attachment.clob_content := p_file_content;
  
  g_attachment(nvl(g_attachment.last,0)+1) := attachment;
  
end attach;

procedure reset is
begin
  msg('reset');
  
  g_recipient.delete;
  g_attachment.delete;

end reset;

end mailgun_pkg;
/

show errors