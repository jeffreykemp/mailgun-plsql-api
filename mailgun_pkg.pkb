create or replace package body mailgun_pkg is

-- Enter your mailgun public key here
MAILGUN_PUBLIC_API_KEY constant varchar2(200) := '';

-- Enter your mailgun secret key here
MAILGUN_PRIVATE_API_KEY constant varchar2(200) := '';

-- Enter your domain registered with mailgun here
MAILGUN_MY_DOMAIN constant varchar2(200) := '';

-- API Base URL (not including your domain)
MAILGUN_API_URL constant varchar2(200) := 'https://api.mailgun.net/v3/';

crlf constant varchar2(50) := chr(13) || chr(10);
boundary constant varchar2(30) := '-----v4np6rnptyb566a0y704sjeqv';

type t_v2arr is table of varchar2(32767) index by binary_integer;
type t_attachment is record
  (blob_content blob
  ,clob_content clob
  ,header       varchar2(4000)
  );
type t_arr is table of t_attachment index by binary_integer;
g_attachment t_arr;

procedure msg (p_msg in varchar2) is
begin
  apex_debug_message.log_message($$PLSQL_UNIT || ': ' || p_msg);
  dbms_output.put_line(p_msg);
end msg;

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
  
  if MAILGUN_PUBLIC_API_KEY is null then
    raise_application_error(-20000, 'validate_email: you must first edit '||$$PLSQL_UNIT||' to set MAILGUN_PUBLIC_API_KEY');
  end if;
  
  str := get_json
    (p_url    => MAILGUN_API_URL || 'address/validate'
    ,p_params => 'address=' || apex_util.url_encode(p_address)
    ,p_user   => 'api'
    ,p_pwd    => MAILGUN_PUBLIC_API_KEY);
  
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
  ,p_to_email     in varchar2
  ,p_cc           in varchar2 := null
  ,p_bcc          in varchar2 := null
  ,p_subject      in varchar2
  ,p_message      in clob
  ,p_tag          in varchar2 := null
  ) is
  url            varchar2(32767) := MAILGUN_API_URL || MAILGUN_MY_DOMAIN
                                 || '/messages';
  header         varchar2(32767);
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
begin
  msg('send_email ' || p_to_email || ' "' || p_subject || '"');

  if MAILGUN_PRIVATE_API_KEY is null then
    raise_application_error(-20000, 'validate_email: you must first edit '||$$PLSQL_UNIT||' to set MAILGUN_PRIVATE_API_KEY');
  end if;
  
  header := crlf
    || form_field('from', nvl(p_from_name,p_from_email) || ' <'||p_from_email||'>')
    || form_field('to', nvl(p_to_name,p_to_email) || ' <'||p_to_email||'>')
    || form_field('cc', p_cc)
    || form_field('bcc', p_bcc)
    || form_field('h:Reply-To', p_reply_to)
    || form_field('o:tag', p_tag)
    || form_field('subject', p_subject)
    || field_header('html');
  footer := '--' || boundary || '--';
  
  content_length := length(header)
                  + dbms_lob.getlength(p_message) + length(crlf)
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
  
  utl_http.set_authentication(req, 'api', MAILGUN_PRIVATE_API_KEY); -- Use HTTP Basic Authen. Scheme
  
  utl_http.set_header(req, 'Content-Type', 'multipart/form-data; boundary="' || boundary || '"');
  utl_http.set_header(req, 'Content-Length', content_length);
  
  msg('writing message contents...');
  
  msg(header);
  utl_http.write_text(req, header);

  write_clob(req, p_message);

  utl_http.write_text(req, crlf);

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
  
  msg('send_email finished');
exception
  when others then
    msg(SQLERRM);
    reset;
    if resp_started then utl_http.end_response (resp); end if;
    raise;
end send_email;

procedure attach
  (p_file_content in blob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  attachment t_attachment;
begin
  msg('attach');
  
  attachment.header := '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="'
    || case when p_inline then 'inline' else 'attachment' end
    || '"; filename="' || p_file_name || '"' || crlf
    || 'Content-Type: ' || p_content_type || crlf
    || crlf;
  attachment.blob_content := p_file_content;  
  
  g_attachment(nvl(g_attachment.last,0)+1) := attachment;
  
end attach;

procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ) is
  attachment t_attachment;
begin
  msg('attach');
  
  attachment.header := '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="attachment"; '
    || 'filename="' || p_file_name || '"' || crlf
    || 'Content-Type: ' || p_content_type || crlf
    || crlf;
  attachment.clob_content := p_file_content;
  
  g_attachment(nvl(g_attachment.last,0)+1) := attachment;
  
end attach;

procedure reset is
begin
  msg('reset');
  
  g_attachment.delete;

end reset;

end mailgun_pkg;
/

show errors