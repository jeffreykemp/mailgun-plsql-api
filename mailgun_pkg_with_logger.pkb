create or replace package body mailgun_pkg is
/* mailgun API v0.7
  https://github.com/jeffreykemp/mailgun-plsql-api
  by Jeffrey Kemp
  Instrumented using Logger https://github.com/OraOpenSource/Logger
*/

scope_prefix constant varchar2(31) := lower($$plsql_unit) || '.';

-- default settings if these are not found in the settings table
default_api_url            constant varchar2(4000) := 'https://api.mailgun.net/v3/';
default_log_retention_days constant number := 30;
default_queue_expiration   constant integer := 24 * 60 * 60; -- failed emails expire from the queue after 24 hours
default_whitelist_action   constant varchar2(100) := whitelist_raise_exception;

boundary               constant varchar2(100) := '-----lgryztl0v2vk7fw3njd6cutmxtwysb';
max_recipients         constant integer := 1000; -- mailgun limitation for recipient variables
queue_name             constant varchar2(30) := sys_context('userenv','current_schema')||'.mailgun_queue';
queue_table            constant varchar2(30) := sys_context('userenv','current_schema')||'.mailgun_queue_tab';
job_name               constant varchar2(30) := 'mailgun_process_queue';
purge_job_name         constant varchar2(30) := 'mailgun_purge_logs';
payload_type           constant varchar2(30) := sys_context('userenv','current_schema')||'.t_mailgun_email';
max_dequeue_count      constant integer := 1000; -- max emails processed by push_queue in one go

-- mailgun setting names
setting_public_api_key         constant varchar2(100) := 'public_api_key';
setting_private_api_key        constant varchar2(100) := 'private_api_key';
setting_my_domain              constant varchar2(100) := 'my_domain';
setting_api_url                constant varchar2(100) := 'api_url';
setting_wallet_path            constant varchar2(100) := 'wallet_path';
setting_wallet_password        constant varchar2(100) := 'wallet_password';
setting_log_retention_days     constant varchar2(100) := 'log_retention_days';
setting_default_sender_name    constant varchar2(100) := 'default_sender_name';
setting_default_sender_email   constant varchar2(100) := 'default_sender_email';
setting_queue_expiration       constant varchar2(100) := 'queue_expiration';
setting_prod_instance_name     constant varchar2(100) := 'prod_instance_name';
setting_non_prod_recipient     constant varchar2(100) := 'non_prod_recipient';
setting_required_sender_domain constant varchar2(100) := 'required_sender_domain';
setting_recipient_whitelist    constant varchar2(100) := 'recipient_whitelist';
setting_whitelist_action       constant varchar2(100) := 'whitelist_action';

type t_key_val_arr is table of varchar2(4000) index by varchar2(100);

g_recipient       t_mailgun_recipient_arr;
g_attachment      t_mailgun_attachment_arr;
g_setting         t_key_val_arr;
g_whitelist       apex_application_global.vc_arr2;

e_no_queue_data exception;
pragma exception_init (e_no_queue_data, -25228);

/******************************************************************************
**                                                                           **
**                              PRIVATE METHODS                              **
**                                                                           **
******************************************************************************/

procedure assert (cond in boolean, err in varchar2) is
begin
  if not cond then
    raise_application_error(-20000, $$PLSQL_UNIT || ' assertion failed: ' || err);
  end if;
end assert;

-- set or update a setting
procedure set_setting
  (p_name  in varchar2
  ,p_value in varchar2
  ) is
  scope logger_logs.scope%type := scope_prefix || 'set_setting';
  params logger.tab_param;
begin
  logger.append_param(params,'p_name',p_name);
  logger.append_param(params,'p_value',case when p_value is null then 'null' else 'not null' end);
  logger.log('START', scope, null, params);
  
  assert(p_name is not null, 'p_name cannot be null');
  
  merge into mailgun_settings t
  using (select p_name  as setting_name
               ,p_value as setting_value
         from dual) s
    on (t.setting_name = s.setting_name)
  when matched then
    update set t.setting_value = s.setting_value
  when not matched then
    insert (setting_name, setting_value)
    values (s.setting_name, s.setting_value);
  
  logger.log('MERGE mailgun_settings: ' || SQL%ROWCOUNT, scope, null, params);
  
  logger.log('commit', scope, null, params);
  commit;
  
  -- cause the settings to be reloaded in this session
  reset;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end set_setting;

-- retrieve all the settings for a normal session
procedure load_settings is
  scope logger_logs.scope%type := scope_prefix || 'load_settings';
  params logger.tab_param;
begin
  logger.log('START', scope, null, params);
  
  -- set defaults first
  g_setting(setting_api_url)                := default_api_url;
  g_setting(setting_wallet_path)            := '';
  g_setting(setting_wallet_password)        := '';
  g_setting(setting_log_retention_days)     := default_log_retention_days;
  g_setting(setting_default_sender_name)    := '';
  g_setting(setting_default_sender_email)   := '';
  g_setting(setting_queue_expiration)       := default_queue_expiration;
  g_setting(setting_prod_instance_name)     := '';
  g_setting(setting_non_prod_recipient)     := '';
  g_setting(setting_required_sender_domain) := '';
  g_setting(setting_recipient_whitelist)    := '';
  g_setting(setting_whitelist_action)       := default_whitelist_action;

  for r in (
    select s.setting_name
          ,s.setting_value
    from   mailgun_settings s
    ) loop
    
    g_setting(r.setting_name) := r.setting_value;

    if r.setting_name not in (setting_private_api_key, setting_wallet_password) then
      logger.append_param(params,r.setting_name,r.setting_value);
    end if;
    
  end loop;
  
  if g_setting(setting_whitelist_action) is not null then
    g_whitelist := apex_util.string_to_table(g_setting(setting_recipient_whitelist), ';');
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end load_settings;

-- get a setting
-- if p_default is set, a null/not found will return the default value
-- if p_default is null, a not found will raise an exception
function setting (p_name in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'setting';
  params logger.tab_param;
  p_value mailgun_settings.setting_value%type;
begin
  logger.append_param(params,'p_name',p_name);
  logger.log('START', scope, null, params);

  assert(p_name is not null, 'p_name cannot be null');
  
  -- prime the settings array for this session
  if g_setting.count = 0 then
    load_settings;
  end if;
  
  p_value := g_setting(p_name);

  logger.log('END ' || case when p_name not in (setting_private_api_key,setting_wallet_password) then p_value end, scope, null, params);
  return p_value;
exception
  when no_data_found then
    logger.log_error('No Data Found', scope, null, params);
    raise_application_error(-20000, 'mailgun setting not set "' || p_name || '" - please setup using ' || $$plsql_unit || '.init()');
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end setting;

function log_retention_days return number is
begin
  return to_number(setting(setting_log_retention_days));
end log_retention_days;

function get_global_name return varchar2 result_cache is
  scope  logger_logs.scope%type := scope_prefix || 'get_global_name';
  params logger.tab_param;
  gn global_name.global_name%type;
begin
  logger.log('START', scope, null, params);

  select g.global_name into gn from sys.global_name g;

  logger.log('END gn=' || gn, scope, null, params);
  return gn;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_global_name;

procedure prod_check
  (p_is_prod            out boolean
  ,p_non_prod_recipient out varchar2
  ) is
  scope  logger_logs.scope%type := scope_prefix || 'prod_check';
  params logger.tab_param;
  prod_instance_name mailgun_settings.setting_value%type;
begin
  logger.log('START', scope, null, params);
  
  prod_instance_name := setting(setting_prod_instance_name);
  
  if prod_instance_name is not null then  
    p_is_prod := prod_instance_name = get_global_name;
  else
    p_is_prod := true; -- if setting not set, we treat this as a prod env
  end if;
  
  if not p_is_prod then
    p_non_prod_recipient := setting(setting_non_prod_recipient);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end prod_check;

function enc_chars (m in varchar2) return varchar2 is
begin
  return regexp_replace(asciistr(m),'\\([0-9A-F]{4})','&#x\1;');
end enc_chars;

function enc_chars (clob_content in clob) return clob is
  scope logger_logs.scope%type := scope_prefix || 'enc_chars';
  params logger.tab_param;
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 2000;
  buf          varchar2(32767);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
  out_clob     clob;
begin
  logger.append_param(params,'clob_content.len',sys.dbms_lob.getlength(clob_content));
  logger.log('START', scope, null, params);

  assert(clob_content is not null, 'enc_chars: clob_content cannot be null');
  sys.dbms_lob.createtemporary(out_clob, false, sys.dbms_lob.call);
  file_len := sys.dbms_lob.getlength (clob_content);
  logger.log('enc_chars ' || file_len || ' bytes', scope, null, params);
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    sys.dbms_lob.read (clob_content, amt, filepos, buf);
    buf := enc_chars(buf);
    sys.dbms_lob.writeappend(out_clob, length(buf), buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    sys.dbms_lob.read (clob_content, modulo, filepos, buf);
    buf := enc_chars(buf);
    sys.dbms_lob.writeappend(out_clob, length(buf), buf);
  end if;

  logger.log('END', scope, null, params);
  return out_clob;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end enc_chars;

-- lengthb doesn't work directly for clobs, and dbms_lob.getlength returns number of chars, not bytes
function clob_size_bytes (clob_content in clob) return integer is
  scope      logger_logs.scope%type := scope_prefix || 'clob_size_bytes';
  params     logger.tab_param;
  ret        integer := 0;
  chunks     integer;
  chunk_size constant integer := 2000;
begin
  logger.append_param(params,'clob_content.len',sys.dbms_lob.getlength(clob_content));
  logger.log('START', scope, null, params);
  
  chunks := ceil(sys.dbms_lob.getlength(clob_content) / chunk_size);
  
  for i in 1..chunks loop
    ret := ret + lengthb(sys.dbms_lob.substr(clob_content, amount => chunk_size, offset => (i-1)*chunk_size+1));
  end loop;

  logger.log('END ret=' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end clob_size_bytes;

function utc_to_session_tz (ts in varchar2) return timestamp is
begin
  return to_timestamp_tz(ts, 'Dy, dd Mon yyyy hh24:mi:ss tzr') at local;
end utc_to_session_tz;

-- do some minimal checking of the format of an email address without going to an external service
procedure val_email_min (email in varchar2) is
  scope logger_logs.scope%type := scope_prefix || 'val_email_min';
  params logger.tab_param;
begin
  logger.append_param(params,'email',email);
  logger.log('START', scope, null, params);

  if email is not null then
    if instr(email,'@') = 0 then
      raise_application_error(-20001, 'email address must include @ ("' || email || '")');
    end if;
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end val_email_min;

procedure log_headers (resp in out nocopy sys.utl_http.resp) is
  scope logger_logs.scope%type := scope_prefix || 'log_headers';
  params logger.tab_param;
  name  varchar2(256);
  value varchar2(1024);
begin
  logger.log('START', scope, null, params);

  for i in 1..sys.utl_http.get_header_count(resp) loop
    sys.utl_http.get_header(resp, i, name, value);
    logger.log(name || ': ' || value, scope, null, params);
  end loop;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end log_headers;

procedure set_wallet is
  scope logger_logs.scope%type := scope_prefix || 'set_wallet';
  params logger.tab_param;
  wallet_path     varchar2(4000);
  wallet_password varchar2(4000);
begin
  logger.log('START', scope, null, params);
  
  wallet_path := setting(setting_wallet_path);
  wallet_password := setting(setting_wallet_password);

  if wallet_path is not null or wallet_password is not null then
    sys.utl_http.set_wallet(wallet_path, wallet_password);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end set_wallet;

function get_response (resp in out nocopy sys.utl_http.resp) return clob is
  scope logger_logs.scope%type := scope_prefix || 'get_response';
  params logger.tab_param;
  buf varchar2(32767);
  ret clob := empty_clob;
begin
  logger.log('START', scope, null, params);
  
  sys.dbms_lob.createtemporary(ret, true);

  begin
    loop
      sys.utl_http.read_text(resp, buf, 32767);
      sys.dbms_lob.writeappend(ret, length(buf), buf);
    end loop;
  exception
    when sys.utl_http.end_of_body then
      null;
  end;
  sys.utl_http.end_response(resp);

  logger.log('END', scope, ret, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_response;

function get_json
  (p_url    in varchar2
  ,p_params in varchar2 := null
  ,p_user   in varchar2 := null
  ,p_pwd    in varchar2 := null
  ,p_method in varchar2 := 'GET'
  ) return clob is
  scope logger_logs.scope%type := scope_prefix || 'get_json';
  params logger.tab_param;
  url   varchar2(4000) := p_url;
  req   sys.utl_http.req;
  resp  sys.utl_http.resp;
  ret   clob;
begin
  logger.append_param(params,'p_url',p_url);
  logger.append_param(params,'p_params',p_params);
  logger.append_param(params,'p_user',p_user);
  logger.append_param(params,'p_pwd',CASE WHEN p_pwd IS NOT NULL THEN '(not null)' ELSE 'NULL' END);
  logger.append_param(params,'p_method',p_method);
  logger.log('START', scope, null, params);

  assert(p_url is not null, 'get_json: p_url cannot be null');
  assert(p_method is not null, 'get_json: p_method cannot be null');
  
  if p_params is not null then
    url := url || '?' || p_params;
  end if;
  
  set_wallet;

  req := sys.utl_http.begin_request(url => url, method => p_method);

  if p_user is not null or p_pwd is not null then
    sys.utl_http.set_authentication(req, p_user, p_pwd);
  end if;

  sys.utl_http.set_header (req,'Accept','application/json');

  resp := sys.utl_http.get_response(req);
  logger.log('HTTP response: ' || resp.status_code || ' ' || resp.reason_phrase, scope, null, params);

  log_headers(resp);

  if resp.status_code != '200' then
    raise_application_error(-20000, 'get_json call failed ' || resp.status_code || ' ' || resp.reason_phrase || ' [' || url || ']');
  end if;

  ret := get_response(resp);

  logger.log('END', scope, ret, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_json;

function rcpt_count return number is
  scope  logger_logs.scope%type := scope_prefix || 'rcpt_count';
  params logger.tab_param;
  ret    integer := 0;
begin
  logger.log('START', scope, null, params);

  if g_recipient is not null then
    ret := g_recipient.count;
  end if;

  logger.log('END ' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end rcpt_count;

function attch_count return number is
  scope logger_logs.scope%type := scope_prefix || 'attch_count';
  params logger.tab_param;
  ret    integer := 0;
begin
  logger.log('START', scope, null, params);

  if g_attachment is not null then
    ret := g_attachment.count;
  end if;

  logger.log('END ' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end attch_count;

procedure add_recipient
  (p_email      in varchar2
  ,p_name       in varchar2
  ,p_first_name in varchar2
  ,p_last_name  in varchar2
  ,p_id         in varchar2
  ,p_send_by    in varchar2
  ) is
  scope logger_logs.scope%type := scope_prefix || 'add_recipient';
  params logger.tab_param;
  name varchar2(4000);
begin
  logger.append_param(params,'p_email',p_email);
  logger.append_param(params,'p_name',p_name);
  logger.append_param(params,'p_first_name',p_first_name);
  logger.append_param(params,'p_last_name',p_last_name);
  logger.append_param(params,'p_id',p_id);
  logger.append_param(params,'p_send_by',p_send_by);
  logger.log('START', scope, null, params);

  assert(rcpt_count < max_recipients, 'maximum recipients per email exceeded (' || max_recipients || ')');
  
  assert(p_email is not null, 'add_recipient: p_email cannot be null');
  assert(p_send_by is not null, 'add_recipient: p_send_by cannot be null');
  assert(p_send_by in ('to','cc','bcc'), 'p_send_by must be to/cc/bcc');
  
  -- don't allow a list of email addresses in one call
  assert(instr(p_email,',')=0, 'add_recipient: p_email cannot contain commas (,)');
  assert(instr(p_email,';')=0, 'add_recipient: p_email cannot contain semicolons (;)');
  
  val_email_min(p_email);
  
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

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end add_recipient;

function attachment_header
  (p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean
  ) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'attachment_header';
  params logger.tab_param;
  ret    varchar2(4000);
begin
  logger.append_param(params,'p_file_name',p_file_name);
  logger.append_param(params,'p_content_type',p_content_type);
  logger.append_param(params,'p_inline',p_inline);
  logger.log('START', scope, null, params);

  assert(p_file_name is not null, 'attachment_header: p_file_name cannot be null');
  assert(p_content_type is not null, 'attachment_header: p_content_type cannot be null');

  ret := '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="'
    || case when p_inline then 'inline' else 'attachment' end
    || '"; filename="' || p_file_name || '"' || crlf
    || 'Content-Type: ' || p_content_type || crlf
    || crlf;

  logger.log('END', scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end attachment_header;

procedure add_attachment
  (p_file_name    in varchar2
  ,p_blob_content in blob := null
  ,p_clob_content in clob := null
  ,p_content_type in varchar2
  ,p_inline       in boolean
  ) is
  scope logger_logs.scope%type := scope_prefix || 'add_attachment';
  params logger.tab_param;
begin
  logger.append_param(params,'p_file_name',p_file_name);
  logger.append_param(params,'p_blob_content',sys.dbms_lob.getlength(p_blob_content));
  logger.append_param(params,'p_clob_content',sys.dbms_lob.getlength(p_clob_content));
  logger.append_param(params,'p_content_type',p_content_type);
  logger.append_param(params,'p_inline',p_inline);
  logger.log('START', scope, null, params);

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

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end add_attachment;

function field_header (p_tag in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'field_header';
  params logger.tab_param;
  ret    varchar2(4000);
begin
  logger.append_param(params,'p_tag',p_tag);
  logger.log('START', scope, null, params);

  assert(p_tag is not null, 'field_header: p_tag cannot be null');
  ret := '--' || boundary || crlf
    || 'Content-Disposition: form-data; name="' || p_tag || '"' || crlf
    || crlf;

  logger.log('END', scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end field_header;

function form_field (p_tag in varchar2, p_data in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'form_field';
  params logger.tab_param;
  ret    varchar2(4000);
begin
  logger.append_param(params,'p_tag',p_tag);
  logger.append_param(params,'p_data',p_data);
  logger.log('START', scope, null, params);

  ret := case when p_data is not null
         then field_header(p_tag) || p_data || crlf
         end;

  logger.log('END', scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end form_field;

function render_mail_headers (p_mail_headers in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'render_mail_headers';
  params logger.tab_param;
  vals apex_json.t_values;
  tag  varchar2(32767);
  val  apex_json.t_value;
  buf  varchar2(32767);
begin
  logger.append_param(params,'p_mail_headers',p_mail_headers);
  logger.log('START', scope, null, params);

  apex_json.parse(vals, p_mail_headers);

  tag := vals.first;
  loop
    exit when tag is null;

    val := vals(tag);

    -- Mailgun accepts arbitrary MIME headers with the "h:" prefix, e.g.
    -- h:Priority
    case val.kind
    when apex_json.c_varchar2 then
      logger.log('h:'||tag||' = ' || val.varchar2_value, scope, null, params);
      buf := buf || form_field('h:'||tag, val.varchar2_value);
    when apex_json.c_number then
      logger.log('h:'||tag||' = ' || val.number_value, scope, null, params);
      buf := buf || form_field('h:'||tag, to_char(val.number_value));
    else
      null;
    end case;

    tag := vals.next(tag);
  end loop;
  
  logger.log('END', scope, null, params);
  return buf;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end render_mail_headers;

procedure write_text
  (req in out nocopy sys.utl_http.req
  ,buf in varchar2) is
  scope logger_logs.scope%type := scope_prefix || 'write_text';
  params logger.tab_param;
begin
  logger.append_param(params,'buf',length(buf));
  logger.log('START', scope, null, params);

  sys.utl_http.write_text(req, buf);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end write_text;

procedure write_clob
  (req          in out nocopy sys.utl_http.req
  ,file_content in clob) is
  scope logger_logs.scope%type := scope_prefix || 'write_clob';
  params logger.tab_param;
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 32767;
  buf          varchar2(32767);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
begin
  logger.append_param(params,'file_content',sys.dbms_lob.getlength(file_content));
  logger.log('START', scope, null, params);

  assert(file_content is not null, 'write_clob: file_content cannot be null');
  file_len := sys.dbms_lob.getlength (file_content);
  logger.log('write_clob ' || file_len || ' chars', scope, null, params);
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    sys.dbms_lob.read (file_content, amt, filepos, buf);
    write_text(req, buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    sys.dbms_lob.read (file_content, modulo, filepos, buf);
    write_text(req, buf);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end write_clob;

procedure write_blob
  (req          in out nocopy sys.utl_http.req
  ,file_content in out nocopy blob) is
  scope logger_logs.scope%type := scope_prefix || 'write_blob';
  params logger.tab_param;
  file_len     pls_integer;
  modulo       pls_integer;
  pieces       pls_integer;
  amt          binary_integer      := 2000;
  buf          raw(2000);
  pos          pls_integer         := 1;
  filepos      pls_integer         := 1;
  counter      pls_integer         := 1;
begin
  logger.append_param(params,'file_content',sys.dbms_lob.getlength(file_content));
  logger.log('START', scope, null, params);

  assert(file_content is not null, 'write_blob: file_content cannot be null');
  file_len := sys.dbms_lob.getlength (file_content);
  logger.log('write_blob ' || file_len || ' bytes', scope, null, params);
  modulo := mod (file_len, amt);
  pieces := trunc (file_len / amt);  
  while (counter <= pieces) loop
    sys.dbms_lob.read (file_content, amt, filepos, buf);
    sys.utl_http.write_raw(req, buf);
    filepos := counter * amt + 1;
    counter := counter + 1;
  end loop;  
  if (modulo <> 0) then
    sys.dbms_lob.read (file_content, modulo, filepos, buf);
    sys.utl_http.write_raw(req, buf);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end write_blob;

procedure send_email (p_payload in out nocopy t_mailgun_email) is
  scope logger_logs.scope%type := scope_prefix || 'send_email';
  params logger.tab_param;
  url varchar2(32767) := setting(setting_api_url) || setting(setting_my_domain) || '/messages';
  header               clob;
  sender               varchar2(4000);
  recipients_to        varchar2(32767);
  recipients_cc        varchar2(32767);
  recipients_bcc       varchar2(32767);
  footer               varchar2(100);
  attachment_size      integer;
  resp_text            varchar2(32767);
  recipient_count      integer := 0;
  attachment_count     integer := 0;
  subject              varchar2(4000);
  is_prod              boolean;
  non_prod_recipient   varchar2(255);
  log                  mailgun_email_log%rowtype;

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
    sys.dbms_lob.writeappend(header, length(buf), buf);
  end append_header;
  
  procedure mailgun_post is
    req       sys.utl_http.req;
    resp      sys.utl_http.resp;
  begin
    logger.log('mailgun_post', scope, null, params);

    -- Turn off checking of status code. We will check it by ourselves.
    sys.utl_http.set_response_error_check(false);
  
    set_wallet;
    
    req := sys.utl_http.begin_request(url, 'POST');
    
    sys.utl_http.set_authentication(req, 'api', setting(setting_private_api_key)); -- Use HTTP Basic Authen. Scheme
    
    sys.utl_http.set_header(req, 'Content-Type', 'multipart/form-data; boundary="' || boundary || '"');
    sys.utl_http.set_header(req, 'Content-Length', log.total_bytes);
    
    logger.log('writing message contents...', scope, null, params);
    
    write_clob(req, header);
  
    sys.dbms_lob.freetemporary(header);
  
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
  
    declare
      my_scheme varchar2(256);
      my_realm  varchar2(256);
    begin
      logger.log('reading response from server...', scope, null, params);
      resp := sys.utl_http.get_response(req);
      
      log_headers(resp);
  
      if resp.status_code = sys.utl_http.http_unauthorized then
        sys.utl_http.get_authentication(resp, my_scheme, my_realm, false);
        logger.log('Unauthorized: please supply the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.', scope, null, params);
        raise_application_error(-20000, 'unauthorized');
      elsif resp.status_code = sys.utl_http.http_proxy_auth_required then
        sys.utl_http.get_authentication(resp, my_scheme, my_realm, true);
        logger.log('Proxy auth required: please supplied the required ' || my_scheme || ' authentication username/password for realm ' || my_realm || '.', scope, null, params);
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
        sys.utl_http.end_response(resp);
        raise;
    end;

  end mailgun_post;

  procedure log_response is
    -- needs to commit the log entry independently of calling transaction
    pragma autonomous_transaction;
  begin
    logger.log('log_response', scope, null, params);

    log.sent_ts         := systimestamp;
    log.requested_ts    := p_payload.requested_ts;
    log.from_name       := p_payload.reply_to;
    log.from_email      := p_payload.from_email;
    log.reply_to        := p_payload.reply_to;
    log.to_name         := p_payload.to_name;
    log.to_email        := p_payload.to_email;
    log.cc              := p_payload.cc;
    log.bcc             := p_payload.bcc;
    log.subject         := subject;
    log.message         := substr(p_payload.message, 1, 4000);
    log.tag             := p_payload.tag;
    log.mail_headers    := substr(p_payload.mail_headers, 1, 4000);
    log.recipients      := substr(recipients_to, 1, 4000);

    begin
      apex_json.parse( resp_text );
      log.mailgun_id      := apex_json.get_varchar2('id');
      log.mailgun_message := apex_json.get_varchar2('message');
      
      logger.log('response: ' || log.mailgun_message, scope, null, params);
      logger.log('msg id: ' || log.mailgun_id, scope, null, params);
    exception
      when others then
        logger.log_warning('error parsing response: ' || SQLERRM, scope, resp_text, params);
        log.mailgun_message := substr(resp_text, 1, 4000);
    end;

    insert into mailgun_email_log values log;
    logger.log('inserted mailgun_email_log: ' || sql%rowcount, scope, null, params);

    logger.log('commit', scope, null, params);
    commit;
    
  end log_response;

begin
  logger.append_param(params, 'p_payload.requested_ts', p_payload.requested_ts);
  logger.append_param(params, 'p_payload.from_name', p_payload.from_name);
  logger.append_param(params, 'p_payload.from_email', p_payload.from_email);
  logger.append_param(params, 'p_payload.reply_to', p_payload.reply_to);
  logger.append_param(params, 'p_payload.to_name', p_payload.to_name);
  logger.append_param(params, 'p_payload.to_email', p_payload.to_email);
  logger.append_param(params, 'p_payload.cc', p_payload.cc);
  logger.append_param(params, 'p_payload.bcc', p_payload.bcc);
  logger.append_param(params, 'p_payload.subject', p_payload.subject);
  logger.append_param(params, 'p_payload.message', sys.dbms_lob.getlength(p_payload.message));
  logger.append_param(params, 'p_payload.tag', p_payload.tag);
  logger.append_param(params, 'p_payload.mail_headers', p_payload.mail_headers);
  logger.log('START', scope, null, params);

  assert(p_payload.from_email is not null, 'send_email: from_email cannot be null');
  
  prod_check
    (p_is_prod            => is_prod
    ,p_non_prod_recipient => non_prod_recipient
    );
  
  if p_payload.recipient is not null then
    recipient_count := p_payload.recipient.count;
    logger.append_param(params, 'recipient_count', recipient_count);
  end if;

  if p_payload.attachment is not null then
    attachment_count := p_payload.attachment.count;
    logger.append_param(params, 'attachment_count', attachment_count);
  end if;
  
  if p_payload.from_email like '% <%>%' then
    sender := p_payload.from_email;
  else
    sender := nvl(p_payload.from_name,p_payload.from_email) || ' <'||p_payload.from_email||'>';
  end if;
  logger.append_param(params, 'sender', sender);
  
  -- construct recipient lists
  
  if not is_prod and non_prod_recipient is not null then
  
    -- replace all recipients with the non-prod recipient 
    recipients_to := non_prod_recipient;
    
  else

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
  
  end if;

  assert(recipients_to is not null, 'send_email: recipients list cannot be empty');
  
  sys.dbms_lob.createtemporary(header, false, sys.dbms_lob.call);
  
  subject := substr(p_payload.subject
    -- in non-prod environments, append the env name to the subject
    || case when not is_prod then ' *' || get_global_name || '*' end
    ,1,4000);
  
  append_header(crlf
    || form_field('from', sender)
    || form_field('h:Reply-To', p_payload.reply_to)
    || form_field('to', recipients_to)
    || form_field('cc', recipients_cc)
    || form_field('bcc', recipients_bcc)
    || form_field('o:tag', p_payload.tag)
    || form_field('subject', subject)
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
      sys.dbms_lob.append(header, apex_json.get_clob_output);
      
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
  sys.dbms_lob.append(header, p_payload.message);
  append_header(crlf);

  footer := '--' || boundary || '--';
  
  -- encode characters (like MS Word "smart quotes") that the mail system can't handle
  header := enc_chars(header);
  
  log.total_bytes := clob_size_bytes(header)
                   + length(footer);

  if attachment_count > 0 then
    for i in 1..attachment_count loop

      if p_payload.attachment(i).clob_content is not null then
        attachment_size := clob_size_bytes(p_payload.attachment(i).clob_content);
      elsif p_payload.attachment(i).blob_content is not null then
        attachment_size := sys.dbms_lob.getlength(p_payload.attachment(i).blob_content);
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
  
  logger.log('content_length=' || log.total_bytes, scope, null, params);

  if is_prod or non_prod_recipient is not null then
  
    -- this is the bit that actually connects to mailgun to send the email
    mailgun_post;  
  
  else
  
    logger.log_warning('email suppressed', scope, null, params);
  
    resp_text := 'email suppressed: ' || get_global_name;
  
  end if;

  log_response;
  
  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    begin
      if header is not null then
        sys.dbms_lob.freetemporary(header);
      end if;
    exception
      when others then
        null;
    end;
    raise;
end send_email;

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
  scope  logger_logs.scope%type := scope_prefix || 'url_param(1)';
  params logger.tab_param;
begin
  logger.append_param(params,'attr',attr);
  logger.append_param(params,'val',val);
  logger.log('START', scope, null, params);

  if val is not null then
    if buf is not null then
      buf := buf || '&';
    end if;
    buf := buf || attr || '=' || apex_util.url_encode(val);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end url_param;

procedure url_param (buf in out varchar2, attr in varchar2, dt in date) is
  scope  logger_logs.scope%type := scope_prefix || 'url_param(2)';
  params logger.tab_param;
begin
  logger.append_param(params,'attr',attr);
  logger.append_param(params,'dt',dt);
  logger.log('START', scope, null, params);

  if dt is not null then
    if buf is not null then
      buf := buf || '&';
    end if;
    buf := buf || attr || '=' || get_epoch(dt);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end url_param;

-- return a comma-delimited string based on the array found at p_path (must already contain a %d), with
-- all values for the given attribute
function json_arr_csv
  (p_path in varchar2
  ,p0     in varchar2
  ,p_attr in varchar2
  ) return varchar2 is
  scope  logger_logs.scope%type := scope_prefix || 'json_arr_csv';
  params logger.tab_param;
  cnt    number;
  buf    varchar2(32767);
begin
  logger.append_param(params,'p_path',p_path);
  logger.append_param(params,'p0',p0);
  logger.append_param(params,'p_attr',p_attr);
  logger.log('START', scope, null, params);

  cnt := apex_json.get_count(p_path, p0);
  for i in 1..cnt loop
    if buf is not null then
      buf := buf || ',';
    end if;
    buf := buf || apex_json.get_varchar2(p_path || '[%d].' || p_attr, p0, i);
  end loop;

  logger.log('END', scope, null, params);
  return buf;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end json_arr_csv;

-- comma-delimited list of attributes, plus values if required
function json_members_csv
  (p_path   in varchar2
  ,p0       in varchar2
  ,p_values in boolean
  ) return varchar2 is
  scope  logger_logs.scope%type := scope_prefix || 'json_members_csv';
  params logger.tab_param;
  arr wwv_flow_t_varchar2;
  buf varchar2(32767);
begin
  logger.append_param(params,'p_path',p_path);
  logger.append_param(params,'p0',p0);
  logger.append_param(params,'p_values',p_values);
  logger.log('START', scope, null, params);

  arr := apex_json.get_members(p_path, p0);
  if arr.count > 0 then
    for i in 1..arr.count loop
      if buf is not null then
        buf := buf || ',';
      end if;
      buf := buf || arr(i);
      if p_values then
        buf := buf || '=' || apex_json.get_varchar2(p_path || '.' || arr(i), p0);
      end if;
    end loop;
  end if;

  logger.log('END', scope, null, params);
  return buf;
exception
  when value_error /*not an array or object*/ then
    logger.log('END value_error', scope, null, params);
    return null;
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end json_members_csv;

-- return the name portion of the email address
function get_mailbox (p_email in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'get_mailbox';
  params logger.tab_param;
  ret varchar2(255);
begin
  logger.append_param(params,'p_email',p_email);
  logger.log('START', scope, null, params);
  
  ret := substr(p_email, 1, instr(p_email, '@') - 1);

  logger.log('END ' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_mailbox;

-- check one email address against the whitelist, take action if necessary
function whitelist_check_one (p_email in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'whitelist_check_one';
  params logger.tab_param;
  i pls_integer;
  ret varchar2(4000);
begin
  logger.append_param(params,'p_email',p_email);
  logger.log('START', scope, null, params);
  
  if p_email is not null and g_whitelist.count > 0 then
    i := g_whitelist.first;
    loop
      exit when i is null;
    
      if trim(lower(p_email)) like trim(lower(g_whitelist(i))) then
        ret := p_email;
      end if;
      
      i := g_whitelist.next(i);
    end loop;
    
    if ret is null then
      -- match not found: take whitelist action
      case setting(setting_whitelist_action)
      when whitelist_suppress then
        ret := null;
      when whitelist_raise_exception then
        raise_application_error(-20000, 'Recipient email address blocked by whitelist (' || p_email || ')');
      else
        -- handle %@example.com or exact@example.com
        ret := replace(setting(setting_whitelist_action), '%', get_mailbox(p_email));
      end case;
    end if;
    
  else
    ret := p_email;
  end if;

  logger.log('END ' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end whitelist_check_one;

-- split the email (potentially a list of email addresses, or name<email>)
-- into each email; check each against the whitelist; reconstruct the new
-- email list
function whitelist_check (p_email in varchar2) return varchar2 is
  scope logger_logs.scope%type := scope_prefix || 'whitelist_check';
  params logger.tab_param;
  l_emails apex_application_global.vc_arr2;
  l_name   varchar2(4000);
  l_email  varchar2(4000);
  ret      varchar2(4000);
begin
  logger.append_param(params,'p_email',p_email);
  logger.log('START', scope, null, params);
  
  if p_email is not null and g_whitelist.count > 0 then
  
    l_emails := apex_util.string_to_table(p_email, ',');
    if l_emails.count > 0 then
      for i in 1..l_emails.count loop
        
        l_name := '';
        l_email := trim(l_emails(i));
        
        if l_email like '% <%>' then
          -- split into name + email
          l_name := substr(l_email, 1, instr(l_email, '<')-1);
          l_email := trim(substr(l_email, instr(l_email, '<')+1));
          l_email := trim(rtrim(l_email, '>'));
        end if;
        
        l_email := whitelist_check_one(p_email => l_email);
        
        if l_email is not null then
          if ret is not null then
            ret := ret || ';';
          end if;
          if l_name is not null then
            ret := ret || l_name || ' <' || l_email || '>';
          else
            ret := ret || l_email;
          end if;
        end if;

      end loop;
    end if;
  
  else
    ret := p_email;
  end if;

  logger.log('END ' || ret, scope, null, params);
  return ret;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end whitelist_check;

/******************************************************************************
**                                                                           **
**                              PUBLIC METHODS                               **
**                                                                           **
******************************************************************************/

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
  ) is
  scope logger_logs.scope%type := scope_prefix || 'init';
  params logger.tab_param;
begin
  logger.append_param(params,'p_public_api_key',p_public_api_key);
  logger.append_param(params,'p_private_api_key',case when p_private_api_key is null then 'null' else 'not null' end);
  logger.append_param(params,'p_my_domain',p_my_domain);
  logger.append_param(params,'p_api_url',p_api_url);
  logger.append_param(params,'p_wallet_path',p_wallet_path);
  logger.append_param(params,'p_wallet_password',case when p_wallet_password is null then 'null' else 'not null' end);
  logger.append_param(params,'p_log_retention_days',p_log_retention_days);
  logger.append_param(params,'p_default_sender_name',p_default_sender_name);
  logger.append_param(params,'p_default_sender_email',p_default_sender_email);
  logger.append_param(params,'p_queue_expiration',p_queue_expiration);
  logger.append_param(params,'p_prod_instance_name',p_prod_instance_name);
  logger.append_param(params,'p_non_prod_recipient',p_non_prod_recipient);
  logger.append_param(params,'p_required_sender_domain',p_required_sender_domain);
  logger.append_param(params,'p_recipient_whitelist',p_recipient_whitelist);
  logger.append_param(params,'p_whitelist_action',p_whitelist_action);
  logger.log('START', scope, null, params);
  
  if nvl(p_public_api_key,'*') != default_no_change then
    set_setting(setting_public_api_key, p_public_api_key);
  end if;

  if nvl(p_private_api_key,'*') != default_no_change then
    set_setting(setting_private_api_key, p_private_api_key);
  end if;

  if nvl(p_my_domain,'*') != default_no_change then
    set_setting(setting_my_domain, p_my_domain);
  end if;

  if nvl(p_api_url,'*') != default_no_change then
    set_setting(setting_api_url, p_api_url);
  end if;

  if nvl(p_wallet_path,'*') != default_no_change then
    set_setting(setting_wallet_path, p_wallet_path);
  end if;

  if nvl(p_wallet_password,'*') != default_no_change then
    set_setting(setting_wallet_password, p_wallet_password);
  end if;

  if p_log_retention_days is not null then
    set_setting(setting_log_retention_days, p_log_retention_days);
  end if;

  if nvl(p_default_sender_name,'*') != default_no_change then
    set_setting(setting_default_sender_name, p_default_sender_name);
  end if;

  if nvl(p_default_sender_email,'*') != default_no_change then
    set_setting(setting_default_sender_email, p_default_sender_email);
  end if;

  if p_queue_expiration is not null then
    set_setting(setting_queue_expiration, p_queue_expiration);
  end if;

  if nvl(p_prod_instance_name,'*') != default_no_change then
    set_setting(setting_prod_instance_name, p_prod_instance_name);
  end if;

  if nvl(p_non_prod_recipient,'*') != default_no_change then
    set_setting(setting_non_prod_recipient, p_non_prod_recipient);
  end if;

  if nvl(p_required_sender_domain,'*') != default_no_change then
    set_setting(setting_required_sender_domain, p_required_sender_domain);
  end if;

  if nvl(p_recipient_whitelist,'*') != default_no_change then
    set_setting(setting_recipient_whitelist, p_recipient_whitelist);
  end if;

  if nvl(p_whitelist_action,'*') != default_no_change then
    set_setting(setting_whitelist_action, p_whitelist_action);
  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end init;

procedure validate_email
  (p_address    in varchar2
  ,p_is_valid   out boolean
  ,p_suggestion out varchar2
  ) is
  scope logger_logs.scope%type := scope_prefix || 'validate_email';
  params logger.tab_param;
  str          clob;
  is_valid_str varchar2(100);
begin
  logger.append_param(params,'p_address',p_address);
  logger.log('START', scope, null, params);

  assert(p_address is not null, 'validate_email: p_address cannot be null');
  
  str := get_json
    (p_url    => setting(setting_api_url) || 'address/validate'
    ,p_params => 'address=' || apex_util.url_encode(p_address)
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_public_api_key));
  
  apex_json.parse(str);

  logger.log('address=' || apex_json.get_varchar2('address'), scope, null, params);

  is_valid_str := apex_json.get_varchar2('is_valid');
  logger.log('is_valid_str=' || is_valid_str, scope, null, params);
  
  p_is_valid := is_valid_str = 'true';

  p_suggestion := apex_json.get_varchar2('did_you_mean');

  logger.append_param(params,'p_is_valid',p_is_valid);
  logger.append_param(params,'p_suggestion',p_suggestion);
  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end validate_email;

function email_is_valid (p_address in varchar2) return boolean is
  scope logger_logs.scope%type := scope_prefix || 'email_is_valid';
  params logger.tab_param;
  is_valid   boolean;
  suggestion varchar2(512);  
begin
  logger.append_param(params,'p_address',p_address);
  logger.log('START', scope, null, params);

  validate_email
    (p_address    => p_address
    ,p_is_valid   => is_valid
    ,p_suggestion => suggestion);

  logger.log('END', scope, null, params);
  return is_valid;
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end email_is_valid;

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
  ) is
  scope logger_logs.scope%type := scope_prefix || 'send_email';
  params logger.tab_param;
  enq_opts        sys.dbms_aq.enqueue_options_t;
  enq_msg_props   sys.dbms_aq.message_properties_t;
  payload         t_mailgun_email;
  msgid           raw(16);
  l_from_name     varchar2(200);
  l_from_email    varchar2(512);
  l_to_email      varchar2(4000);
  l_cc            varchar2(4000);
  l_bcc           varchar2(4000);
begin
  logger.append_param(params,'p_from_name',p_from_name);
  logger.append_param(params,'p_from_email',p_from_email);
  logger.append_param(params,'p_reply_to',p_reply_to);
  logger.append_param(params,'p_to_name',p_to_name);
  logger.append_param(params,'p_to_email',p_to_email);
  logger.append_param(params,'p_cc',p_cc);
  logger.append_param(params,'p_bcc',p_bcc);
  logger.append_param(params,'p_subject',p_subject);
  logger.append_param(params,'p_message',sys.dbms_lob.getlength(p_message));
  logger.append_param(params,'p_tag',p_tag);
  logger.append_param(params,'p_mail_headers',p_mail_headers);
  logger.append_param(params,'p_priority',p_priority);
  logger.log('START', scope, null, params);
  
  if p_to_email is not null then
    assert(rcpt_count = 0, 'cannot mix multiple recipients with p_to_email parameter');
  end if;
  
  assert(p_priority is not null, 'p_priority cannot be null');
  
  -- we only use the default sender name if both sender name + email are null
  l_from_name := nvl(p_from_name, case when p_from_email is null then setting(setting_default_sender_name) end);
  l_from_email := nvl(p_from_email, setting(setting_default_sender_email));

  -- check if sender is in required sender domain
  if p_from_email is not null
  and setting(setting_required_sender_domain) is not null
  and p_from_email not like '%@' || setting(setting_required_sender_domain) then
  
    l_from_email := setting(setting_default_sender_email);        

    if l_from_email is null then
      raise_application_error(-20000, 'Sender domain not allowed (' || p_from_email || ')');
    end if;

  end if;
  
  assert(l_from_email is not null, 'from_email cannot be null');
  
  val_email_min(l_from_email);
  val_email_min(p_reply_to);
  val_email_min(p_to_email);
  val_email_min(p_cc);
  val_email_min(p_bcc);
  
  l_to_email := whitelist_check(p_to_email);
  l_cc := whitelist_check(p_cc);
  l_bcc := whitelist_check(p_bcc);

  assert(rcpt_count > 0 or coalesce(l_to_email, l_cc, l_bcc) is not null, 'must be at least one recipient');
  
  payload := t_mailgun_email
    ( requested_ts => systimestamp
    , from_name    => l_from_name
    , from_email   => l_from_email
    , reply_to     => p_reply_to
    , to_name      => p_to_name
    , to_email     => l_to_email
    , cc           => l_cc
    , bcc          => l_bcc
    , subject      => p_subject
    , message      => p_message
    , tag          => p_tag
    , mail_headers => p_mail_headers
    , recipient    => g_recipient
    , attachment   => g_attachment
    );

  reset;

  enq_msg_props.expiration := setting(setting_queue_expiration);
  enq_msg_props.priority   := p_priority;

  sys.dbms_aq.enqueue
    (queue_name         => queue_name
    ,enqueue_options    => enq_opts
    ,message_properties => enq_msg_props
    ,payload            => payload
    ,msgid              => msgid
    );
  
  logger.log('email queued ' || msgid, scope, null, params);
  
  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
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
  scope logger_logs.scope%type := scope_prefix || 'send_to';
  params logger.tab_param;
  l_email varchar2(255);
begin
  logger.append_param(params,'p_email',p_email);
  logger.append_param(params,'p_name',p_name);
  logger.append_param(params,'p_first_name',p_first_name);
  logger.append_param(params,'p_last_name',p_last_name);
  logger.append_param(params,'p_id',p_id);
  logger.append_param(params,'p_send_by',p_send_by);
  logger.log('START', scope, null, params);
  
  l_email := whitelist_check(p_email);
  
  if l_email is not null then
  
    add_recipient
      (p_email      => l_email
      ,p_name       => p_name
      ,p_first_name => p_first_name
      ,p_last_name  => p_last_name
      ,p_id         => p_id
      ,p_send_by    => p_send_by);

  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end send_to;

procedure send_cc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ) is
  scope logger_logs.scope%type := scope_prefix || 'send_cc';
  params logger.tab_param;
  l_email varchar2(255);
begin
  logger.append_param(params,'p_email',p_email);
  logger.append_param(params,'p_name',p_name);
  logger.append_param(params,'p_first_name',p_first_name);
  logger.append_param(params,'p_last_name',p_last_name);
  logger.append_param(params,'p_id',p_id);
  logger.log('START', scope, null, params);

  l_email := whitelist_check(p_email);
  
  if l_email is not null then
  
    add_recipient
      (p_email      => l_email
      ,p_name       => p_name
      ,p_first_name => p_first_name
      ,p_last_name  => p_last_name
      ,p_id         => p_id
      ,p_send_by    => 'cc');

  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end send_cc;

procedure send_bcc
  (p_email      in varchar2
  ,p_name       in varchar2 := null
  ,p_first_name in varchar2 := null
  ,p_last_name  in varchar2 := null
  ,p_id         in varchar2 := null
  ) is
  scope logger_logs.scope%type := scope_prefix || 'send_bcc';
  params logger.tab_param;
  l_email varchar2(255);
begin
  logger.append_param(params,'p_email',p_email);
  logger.append_param(params,'p_name',p_name);
  logger.append_param(params,'p_first_name',p_first_name);
  logger.append_param(params,'p_last_name',p_last_name);
  logger.append_param(params,'p_id',p_id);
  logger.log('START', scope, null, params);

  l_email := whitelist_check(p_email);
  
  if l_email is not null then
  
    add_recipient
      (p_email      => l_email
      ,p_name       => p_name
      ,p_first_name => p_first_name
      ,p_last_name  => p_last_name
      ,p_id         => p_id
      ,p_send_by    => 'bcc');

  end if;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end send_bcc;

procedure attach
  (p_file_content in blob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  scope logger_logs.scope%type := scope_prefix || 'attach';
  params logger.tab_param;
begin
  logger.append_param(params,'p_file_content',sys.dbms_lob.getlength(p_file_content));
  logger.append_param(params,'p_file_name',p_file_name);
  logger.append_param(params,'p_content_type',p_content_type);
  logger.append_param(params,'p_inline',p_inline);
  logger.log('START', scope, null, params);

  assert(p_file_content is not null, 'attach(blob): p_file_content cannot be null');
  
  add_attachment
    (p_file_name    => p_file_name
    ,p_blob_content => p_file_content
    ,p_content_type => p_content_type
    ,p_inline       => p_inline
    );

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end attach;

procedure attach
  (p_file_content in clob
  ,p_file_name    in varchar2
  ,p_content_type in varchar2
  ,p_inline       in boolean := false
  ) is
  scope logger_logs.scope%type := scope_prefix || 'attach';
  params logger.tab_param;
begin
  logger.append_param(params,'p_file_content',sys.dbms_lob.getlength(p_file_content));
  logger.append_param(params,'p_file_name',p_file_name);
  logger.append_param(params,'p_content_type',p_content_type);
  logger.append_param(params,'p_inline',p_inline);
  logger.log('START', scope, null, params);

  assert(p_file_content is not null, 'attach(clob): p_file_content cannot be null');

  add_attachment
    (p_file_name    => p_file_name
    ,p_clob_content => p_file_content
    ,p_content_type => p_content_type
    ,p_inline       => p_inline
    );

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end attach;

procedure reset is
  scope logger_logs.scope%type := scope_prefix || 'reset';
  params logger.tab_param;
begin
  logger.log('START', scope, null, params);

  if g_recipient is not null then
    g_recipient.delete;
  end if;
  
  if g_attachment is not null then
    g_attachment.delete;
  end if;
  
  -- we also drop the settings so they are reloaded between calls, in case they
  -- are changed
  g_setting.delete;  
  g_whitelist.delete;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end reset;

procedure create_queue
  (p_max_retries in number := default_max_retries
  ,p_retry_delay in number := default_retry_delay
  ) is
  scope logger_logs.scope%type := scope_prefix || 'create_queue';
  params logger.tab_param;
begin
  logger.append_param(params,'p_max_retries',p_max_retries);
  logger.append_param(params,'p_retry_delay',p_retry_delay);
  logger.log('START', scope, null, params);

  sys.dbms_aqadm.create_queue_table
    (queue_table        => queue_table
    ,queue_payload_type => payload_type
    ,sort_list          => 'priority,enq_time'
    ,storage_clause     => 'nested table user_data.recipient store as mailgun_recipient_tab'
                        ||',nested table user_data.attachment store as mailgun_attachment_tab'
    );

  sys.dbms_aqadm.create_queue
    (queue_name  => queue_name
    ,queue_table => queue_table
    ,max_retries => p_max_retries
    ,retry_delay => p_retry_delay
    );

  sys.dbms_aqadm.start_queue (queue_name);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end create_queue;

procedure drop_queue is
  scope logger_logs.scope%type := scope_prefix || 'drop_queue';
  params logger.tab_param;
begin
  logger.log('START', scope, null, params);

  sys.dbms_aqadm.stop_queue (queue_name);
  
  sys.dbms_aqadm.drop_queue (queue_name);
  
  sys.dbms_aqadm.drop_queue_table (queue_table);  

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end drop_queue;

procedure purge_queue (p_msg_state IN VARCHAR2 := default_purge_msg_state) is
  scope logger_logs.scope%type := scope_prefix || 'purge_queue';
  params logger.tab_param;
  r_opt sys.dbms_aqadm.aq$_purge_options_t;
begin
  logger.append_param(params,'p_msg_state',p_msg_state);
  logger.log('START', scope, null, params);

  sys.dbms_aqadm.purge_queue_table
    (queue_table     => queue_table
    ,purge_condition => case when p_msg_state is not null
                        then replace(q'[ qtview.msg_state = '#STATE#' ]'
                                    ,'#STATE#', p_msg_state)
                        end
    ,purge_options   => r_opt);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end purge_queue;

procedure push_queue
  (p_asynchronous in boolean := false) as
  scope logger_logs.scope%type := scope_prefix || 'push_queue';
  params logger.tab_param;
  r_dequeue_options    sys.dbms_aq.dequeue_options_t;
  r_message_properties sys.dbms_aq.message_properties_t;
  msgid                raw(16);
  payload              t_mailgun_email;
  dequeue_count        integer := 0;
  job                  binary_integer;
begin
  logger.append_param(params,'p_asynchronous',p_asynchronous);
  logger.log('START', scope, null, params);

  if p_asynchronous then
  
    -- use dbms_job so that it is only run if/when this session commits
  
    sys.dbms_job.submit
      (job  => job
      ,what => $$PLSQL_UNIT || '.push_queue;'
      );
      
    logger.log('submitted job=' || job, scope, null, params);
      
  else
    
    -- commit any emails requested in the current session
    logger.log('commit', scope, null, params);
    commit;
    
    r_dequeue_options.wait := sys.dbms_aq.no_wait;
  
    -- loop through all messages in the queue until there is none
    -- exit this loop when the e_no_queue_data exception is raised.
    loop    
  
      sys.dbms_aq.dequeue
        (queue_name         => queue_name
        ,dequeue_options    => r_dequeue_options
        ,message_properties => r_message_properties
        ,payload            => payload
        ,msgid              => msgid
        );
      
      logger.log('payload priority: ' || r_message_properties.priority
        || ' enqeued: ' || to_char(r_message_properties.enqueue_time,'dd/mm/yyyy hh24:mi:ss')
        || ' attempts: ' || r_message_properties.attempts
        , scope, null, params);
  
      -- process the message
      send_email (p_payload => payload);  
  
      logger.log('commit', scope, null, params);
      commit; -- the queue will treat the message as succeeded
      
      -- don't bite off everything in one go
      dequeue_count := dequeue_count + 1;
      exit when dequeue_count >= max_dequeue_count;
    end loop;

  end if;

  logger.log('END', scope, null, params);
exception
  when e_no_queue_data then
    logger.log('END push_queue finished count=' || dequeue_count, scope, null, params);
  when others then
    rollback; -- the queue will treat the message as failed
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end push_queue;

procedure create_job
  (p_repeat_interval in varchar2 := default_repeat_interval) is
  scope logger_logs.scope%type := scope_prefix || 'create_job';
  params logger.tab_param;
begin
  logger.append_param(params,'p_repeat_interval',p_repeat_interval);
  logger.log('START', scope, null, params);

  assert(p_repeat_interval is not null, 'create_job: p_repeat_interval cannot be null');

  sys.dbms_scheduler.create_job
    (job_name        => job_name
    ,job_type        => 'stored_procedure'
    ,job_action      => $$PLSQL_UNIT||'.push_queue'
    ,start_date      => systimestamp
    ,repeat_interval => p_repeat_interval
    );

  sys.dbms_scheduler.set_attribute(job_name,'restartable',true);

  sys.dbms_scheduler.enable(job_name);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end create_job;

procedure drop_job is
  scope logger_logs.scope%type := scope_prefix || 'drop_job';
  params logger.tab_param;
begin
  logger.log('START', scope, null, params);

  begin
    sys.dbms_scheduler.stop_job (job_name);
  exception
    when others then
      if sqlcode != -27366 /*job already stopped*/ then
        raise;
      end if;
  end;
  
  sys.dbms_scheduler.drop_job (job_name);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end drop_job;

procedure purge_logs (p_log_retention_days in number := null) is
  scope logger_logs.scope%type := scope_prefix || 'purge_logs';
  params logger.tab_param;
  l_log_retention_days number;
begin
  logger.append_param(params,'p_log_retention_days',p_log_retention_days);
  logger.log('START', scope, null, params);

  l_log_retention_days := nvl(p_log_retention_days, log_retention_days);
  logger.append_param(params,'l_log_retention_days',l_log_retention_days);
  
  delete mailgun_email_log
  where requested_ts < sysdate - l_log_retention_days;
  
  logger.log_info('DELETED mailgun_email_log: ' || SQL%ROWCOUNT, scope, null, params);
  
  logger.log('commit', scope, null, params);
  commit;

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end purge_logs;

procedure create_purge_job
  (p_repeat_interval in varchar2 := default_purge_repeat_interval) is
  scope logger_logs.scope%type := scope_prefix || 'create_purge_job';
  params logger.tab_param;
begin
  logger.append_param(params,'p_repeat_interval',p_repeat_interval);
  logger.log('START', scope, null, params);

  assert(p_repeat_interval is not null, 'create_purge_job: p_repeat_interval cannot be null');

  sys.dbms_scheduler.create_job
    (job_name        => purge_job_name
    ,job_type        => 'stored_procedure'
    ,job_action      => $$PLSQL_UNIT||'.purge_logs'
    ,start_date      => systimestamp
    ,repeat_interval => p_repeat_interval
    );

  sys.dbms_scheduler.set_attribute(job_name,'restartable',true);

  sys.dbms_scheduler.enable(purge_job_name);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end create_purge_job;

procedure drop_purge_job is
  scope logger_logs.scope%type := scope_prefix || 'drop_purge_job';
  params logger.tab_param;
begin
  logger.log('START', scope, null, params);

  begin
    sys.dbms_scheduler.stop_job (purge_job_name);
  exception
    when others then
      if sqlcode != -27366 /*job already stopped*/ then
        raise;
      end if;
  end;
  
  sys.dbms_scheduler.drop_job (purge_job_name);

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end drop_purge_job;

-- get mailgun stats
function get_stats
  (p_event_types     in varchar2 := 'all'
  ,p_resolution      in varchar2 := null
  ,p_start_time      in date     := null
  ,p_end_time        in date     := null
  ,p_duration        in number   := null
  ) return t_mailgun_stat_arr pipelined is
  scope       logger_logs.scope%type := scope_prefix || 'get_stats';
  params      logger.tab_param;
  prm         varchar2(4000);
  str         clob;
  stats_count number;
  res         varchar2(10);
  dt          date;

  function get_stat (i in integer, stat_name in varchar2, stat_detail in varchar2)
    return t_mailgun_stat is
  begin
    return t_mailgun_stat
      ( stat_datetime => dt
      , resolution    => res
      , stat_name     => stat_name
      , stat_detail   => stat_detail
      , val           => nvl(apex_json.get_number(p_path=>'stats[%d].'||stat_name||'.'||stat_detail, p0=>i), 0)
      );
  end get_stat;
begin
  logger.append_param(params,'p_event_types',p_event_types);
  logger.append_param(params,'p_resolution',p_resolution);
  logger.append_param(params,'p_start_time',p_start_time);
  logger.append_param(params,'p_end_time',p_end_time);
  logger.append_param(params,'p_duration',p_duration);
  logger.log('START', scope, null, params);

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
    (p_url    => setting(setting_api_url) || setting(setting_my_domain) || '/stats/total'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));
  
  apex_json.parse(str);
  
  stats_count := apex_json.get_count('stats');
  res := apex_json.get_varchar2('resolution');
  
  if stats_count > 0 then
    for i in 1..stats_count loop
      logger.log(i||' '||json_members_csv('stats[%d]', i, p_values => true), scope, null, params);
      dt := utc_to_session_tz(apex_json.get_varchar2(p_path=>'stats[%d].time', p0=>i));
      pipe row (get_stat(i,'accepted','incoming'));
      pipe row (get_stat(i,'accepted','outgoing'));
      pipe row (get_stat(i,'accepted','total'));
      pipe row (get_stat(i,'delivered','smtp'));
      pipe row (get_stat(i,'delivered','http'));
      pipe row (get_stat(i,'delivered','total'));
      pipe row (get_stat(i,'failed.temporary','espblock'));
      pipe row (get_stat(i,'failed.permanent','suppress-bounce'));
      pipe row (get_stat(i,'failed.permanent','suppress-unsubscribe'));
      pipe row (get_stat(i,'failed.permanent','suppress-complaint'));
      pipe row (get_stat(i,'failed.permanent','bounce'));
      pipe row (get_stat(i,'failed.permanent','total'));
      pipe row (get_stat(i,'stored','total'));
      pipe row (get_stat(i,'opened','total'));
      pipe row (get_stat(i,'clicked','total'));
      pipe row (get_stat(i,'unsubscribed','total'));
      pipe row (get_stat(i,'complained','total'));
    end loop;
  end if;

  logger.log('END', scope, null, params);
  return;
exception
  when no_data_needed then
    logger.log('END No Data needed', scope, null, params);
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_stats;

-- get mailgun stats
function get_tag_stats
  (p_tag             in varchar2
  ,p_event_types     in varchar2 := 'all'
  ,p_resolution      in varchar2 := null
  ,p_start_time      in date     := null
  ,p_end_time        in date     := null
  ,p_duration        in number   := null
  ) return t_mailgun_stat_arr pipelined is
  scope       logger_logs.scope%type := scope_prefix || 'get_tag_stats';
  params      logger.tab_param;
  prm         varchar2(4000);
  str         clob;
  stats_count number;
  res         varchar2(10);
  dt          date;

  function get_stat (i in integer, stat_name in varchar2, stat_detail in varchar2)
    return t_mailgun_stat is
  begin
    return t_mailgun_stat
      ( stat_datetime => dt
      , resolution    => res
      , stat_name     => stat_name
      , stat_detail   => stat_detail
      , val           => nvl(apex_json.get_number(p_path=>'stats[%d].'||stat_name||'.'||stat_detail, p0=>i), 0)
      );
  end get_stat;
begin
  logger.append_param(params,'p_tag',p_tag);
  logger.append_param(params,'p_event_types',p_event_types);
  logger.append_param(params,'p_resolution',p_resolution);
  logger.append_param(params,'p_start_time',p_start_time);
  logger.append_param(params,'p_end_time',p_end_time);
  logger.append_param(params,'p_duration',p_duration);
  logger.log('START', scope, null, params);

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
    (p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/tags/' || apex_util.url_encode(p_tag) || '/stats'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));
  
  apex_json.parse(str);
  
  stats_count := apex_json.get_count('stats');
  res := apex_json.get_varchar2('resolution');
  
  if stats_count > 0 then
    for i in 1..stats_count loop
      logger.log(i||' '||json_members_csv('stats[%d]', i, p_values => true), scope, null, params);
      dt := utc_to_session_tz(apex_json.get_varchar2(p_path=>'stats[%d].time', p0=>i));
      pipe row (get_stat(i,'accepted','incoming'));
      pipe row (get_stat(i,'accepted','outgoing'));
      pipe row (get_stat(i,'accepted','total'));
      pipe row (get_stat(i,'delivered','smtp'));
      pipe row (get_stat(i,'delivered','http'));
      pipe row (get_stat(i,'delivered','total'));
      pipe row (get_stat(i,'failed.temporary','espblock'));
      pipe row (get_stat(i,'failed.permanent','suppress-bounce'));
      pipe row (get_stat(i,'failed.permanent','suppress-unsubscribe'));
      pipe row (get_stat(i,'failed.permanent','suppress-complaint'));
      pipe row (get_stat(i,'failed.permanent','bounce'));
      pipe row (get_stat(i,'failed.permanent','total'));
      pipe row (get_stat(i,'stored','total'));
      pipe row (get_stat(i,'opened','total'));
      pipe row (get_stat(i,'clicked','total'));
      pipe row (get_stat(i,'unsubscribed','total'));
      pipe row (get_stat(i,'complained','total'));
    end loop;
  end if;

  logger.log('END', scope, null, params);
  return;
exception
  when no_data_needed then
    logger.log('END No Data needed', scope, null, params);
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_tag_stats;

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
  scope       logger_logs.scope%type := scope_prefix || 'get_events';
  params      logger.tab_param;
  prm         varchar2(4000);
  str         clob;
  event_count number;
  url         varchar2(4000);
begin
  logger.append_param(params,'p_start_time',p_start_time);
  logger.append_param(params,'p_end_time',p_end_time);
  logger.append_param(params,'p_page_size',p_page_size);
  logger.append_param(params,'p_event',p_event);
  logger.append_param(params,'p_sender',p_sender);
  logger.append_param(params,'p_recipient',p_recipient);
  logger.append_param(params,'p_subject',p_subject);
  logger.append_param(params,'p_tags',p_tags);
  logger.append_param(params,'p_severity',p_severity);
  logger.log('START', scope, null, params);
  
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
  url := setting(setting_api_url) || setting(setting_my_domain) || '/events';
  
  loop
  
    str := get_json
      (p_url    => url
      ,p_params => prm
      ,p_user   => 'api'
      ,p_pwd    => setting(setting_private_api_key));  

    apex_json.parse(str);
    
    event_count := apex_json.get_count('items');

    exit when event_count = 0;
    
    for i in 1..event_count loop
      logger.log(i||' '||json_members_csv('items[%d]', i, p_values => true), scope, null, params);
      pipe row (t_mailgun_event
        ( event                => substr(apex_json.get_varchar2('items[%d].event', i), 1, 100)
        , event_ts             => epoch_to_dt(apex_json.get_number('items[%d].timestamp', i))
        , event_id             => substr(apex_json.get_varchar2('items[%d].id', i), 1, 200)
        , message_id           => substr(apex_json.get_varchar2('items[%d].message.headers."message-id"', i), 1, 200)
        , sender               => substr(apex_json.get_varchar2('items[%d].envelope.sender', i), 1, 4000)
        , recipient            => substr(apex_json.get_varchar2('items[%d].recipient', i), 1, 4000)
        , subject              => substr(apex_json.get_varchar2('items[%d].message.headers.subject', i), 1, 4000)
        , attachments          => substr(json_arr_csv('items[%d].message.attachments', i, 'filename'), 1, 4000)
        , size_bytes           => apex_json.get_number('items[%d].message.size', i)
        , method               => substr(apex_json.get_varchar2('items[%d].method', i), 1, 100)
        , tags                 => substr(json_members_csv('items[%d].tags', i, p_values => false), 1, 4000)
        , user_variables       => substr(json_members_csv('items[%d]."user-variables"', i, p_values => true), 1, 4000)
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
    logger.log('next url=' || url, scope, null, params);
    -- convert url to use reverse-apache version, if necessary
    url := replace(url, default_api_url, setting(setting_api_url));
    logger.log('next url[converted]=' || url, scope, null, params);
    exit when url is null;
  end loop;
    
  logger.log('END', scope, null, params);
  return;
exception
  when no_data_needed then
    logger.log('END No Data Needed', scope, null, params);
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_events;

function get_tags
  (p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_tag_arr pipelined is
  scope      logger_logs.scope%type := scope_prefix || 'get_tags';
  params     logger.tab_param;
  prm        varchar2(4000);
  str        clob;
  item_count number;

begin
  logger.append_param(params,'p_limit',p_limit);
  logger.log('START', scope, null, params);

  url_param(prm, 'limit', p_limit);
  
  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain) || '/tags'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));

  apex_json.parse(str);
  
  item_count := apex_json.get_count('items');
  
  if item_count > 0 then  
    for i in 1..item_count loop
      logger.log(i||' '||json_members_csv('items[%d]', i, p_values => true), scope, null, params);
      pipe row (t_mailgun_tag
        ( tag_name    => substr(apex_json.get_varchar2('items[%d].tag', i), 1, 4000)
        , description => substr(apex_json.get_varchar2('items[%d].description', i), 1, 4000)
        ));
    end loop;
  end if;
    
  logger.log('END', scope, null, params);
  return;
exception
  when no_data_needed then
    logger.log('END No Data Needed', scope, null, params);
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_tags;

procedure update_tag
  (p_tag         in varchar2
  ,p_description in varchar2 := null) is
  scope logger_logs.scope%type := scope_prefix || 'update_tag';
  params logger.tab_param;
  prm  varchar2(4000);
  str  clob;

begin
  logger.append_param(params,'p_tag',p_tag);
  logger.append_param(params,'p_description',p_description);
  logger.log('START', scope, null, params);

  assert(p_tag is not null, 'p_tag cannot be null');
  assert(instr(p_tag,' ') = 0, 'p_tag cannot contain spaces');

  url_param(prm, 'description', p_description);
  
  str := get_json
    (p_method => 'PUT'
    ,p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/tags/' || apex_util.url_encode(p_tag)
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));
  
  -- normally it returns {"message":"Tag updated"}

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end update_tag;

procedure delete_tag (p_tag in varchar2) is
  scope logger_logs.scope%type := scope_prefix || 'delete_tag';
  params logger.tab_param;
  prm  varchar2(4000);
  str  clob;

begin
  logger.append_param(params,'p_tag',p_tag);
  logger.log('START', scope, null, params);

  assert(p_tag is not null, 'p_tag cannot be null');
  assert(instr(p_tag,' ') = 0, 'p_tag cannot contain spaces');
  
  str := get_json
    (p_method => 'DELETE'
    ,p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/tags/' || apex_util.url_encode(p_tag)
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));
  
  -- normally it returns {"message":"Tag deleted"}

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end delete_tag;

function get_suppressions
  (p_type  in varchar2 -- 'bounces', 'unsubscribes', or 'complaints'
  ,p_limit in number := null -- max rows to fetch (default 100)
  ) return t_mailgun_suppression_arr pipelined is
  scope      logger_logs.scope%type := scope_prefix || 'get_suppressions';
  params     logger.tab_param;
  prm        varchar2(4000);
  str        clob;
  item_count number;

begin
  logger.append_param(params,'p_type',p_type);
  logger.append_param(params,'p_limit',p_limit);
  logger.log('START', scope, null, params);
  
  assert(p_type is not null, 'p_type cannot be null');
  assert(p_type in ('bounces','unsubscribes','complaints'), 'p_type must be bounces, unsubscribes, or complaints');

  url_param(prm, 'limit', p_limit);
  
  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain) || '/' || p_type
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key));

  apex_json.parse(str);
  
  item_count := apex_json.get_count('items');

  if item_count > 0 then
    for i in 1..item_count loop
      logger.log(i||' '||json_members_csv('items[%d]', i, p_values => true), scope, null, params);
      pipe row (t_mailgun_suppression
        ( suppression_type => substr(p_type, 1, length(p_type)-1)
        , email_address    => substr(apex_json.get_varchar2('items[%d].address', i), 1, 4000)
        , unsubscribe_tag  => substr(apex_json.get_varchar2('items[%d].tag', i), 1, 4000)
        , bounce_code      => substr(apex_json.get_varchar2('items[%d].code', i), 1, 255)
        , bounce_error     => substr(apex_json.get_varchar2('items[%d].error', i), 1, 4000)
        , created_dt       => utc_to_session_tz(apex_json.get_varchar2('items[%d].created_at', i))
        ));
    end loop;
  end if;
    
  logger.log('END', scope, null, params);
  return;
exception
  when no_data_needed then
    logger.log('END No Data Needed', scope, null, params);
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end get_suppressions;

-- remove an email address from the bounce list
procedure delete_bounce (p_email_address in varchar2) is
  scope logger_logs.scope%type := scope_prefix || 'delete_bounce';
  params logger.tab_param;
  str  clob;
begin
  logger.append_param(params,'p_email_address',p_email_address);
  logger.log('START', scope, null, params);
  
  assert(p_email_address is not null, 'p_email_address cannot be null');

  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/bounces/' || apex_util.url_encode(p_email_address)
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key)
    ,p_method => 'DELETE');

  -- normally it returns {"address":"...the address...","message":"Bounced address has been removed"}

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end delete_bounce;

-- add an email address to the unsubscribe list
procedure add_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null
  ) is
  scope logger_logs.scope%type := scope_prefix || 'add_unsubscribe';
  params logger.tab_param;
  prm  varchar2(4000);
  str  clob;
begin
  logger.append_param(params,'p_email_address',p_email_address);
  logger.append_param(params,'p_tag',p_tag);
  logger.log('START', scope, null, params);
  
  assert(p_email_address is not null, 'p_email_address cannot be null');

  url_param(prm, 'address', p_email_address);
  url_param(prm, 'tag', p_tag);

  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain) || '/unsubscribes'
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key)
    ,p_method => 'POST');

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end add_unsubscribe;

-- remove an email address from the unsubscribe list
procedure delete_unsubscribe
  (p_email_address in varchar2
  ,p_tag           in varchar2 := null
  ) is
  scope logger_logs.scope%type := scope_prefix || 'delete_unsubscribe';
  params logger.tab_param;
  prm  varchar2(4000);
  str  clob;
begin
  logger.append_param(params,'p_email_address',p_email_address);
  logger.append_param(params,'p_tag',p_tag);
  logger.log('START', scope, null, params);
  
  assert(p_email_address is not null, 'p_email_address cannot be null');

  url_param(prm, 'tag', p_tag);

  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/unsubscribes/' || apex_util.url_encode(p_email_address)
    ,p_params => prm
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key)
    ,p_method => 'DELETE');

  -- normally it returns {"message":"Unsubscribe event has been removed"}

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end delete_unsubscribe;

-- remove an email address from the complaint list
procedure delete_complaint (p_email_address in varchar2) is
  scope logger_logs.scope%type := scope_prefix || 'delete_complaint';
  params logger.tab_param;
  str  clob;
begin
  logger.append_param(params,'p_email_address',p_email_address);
  logger.log('START', scope, null, params);
  
  assert(p_email_address is not null, 'p_email_address cannot be null');

  str := get_json
    (p_url    => setting(setting_api_url) || setting(setting_my_domain)
              || '/complaints/' || apex_util.url_encode(p_email_address)
    ,p_user   => 'api'
    ,p_pwd    => setting(setting_private_api_key)
    ,p_method => 'DELETE');

  -- normally it returns {"message":"Spam complaint has been removed"}

  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    raise;
end delete_complaint;

procedure send_test_email
  (p_from_name       in varchar2 := null
  ,p_from_email      in varchar2 := null
  ,p_to_name         in varchar2 := null
  ,p_to_email        in varchar2
  ,p_subject         in varchar2 := null
  ,p_message         in varchar2 := null
  ,p_private_api_key in varchar2 := default_no_change
  ,p_my_domain       in varchar2 := default_no_change
  ,p_api_url         in varchar2 := default_no_change
  ,p_wallet_path     in varchar2 := default_no_change
  ,p_wallet_password in varchar2 := default_no_change
  ) is
  scope logger_logs.scope%type := scope_prefix || 'send_test_email';
  params logger.tab_param;
  payload t_mailgun_email;
begin
  logger.append_param(params,'p_from_name',p_from_name);
  logger.append_param(params,'p_from_email',p_from_email);
  logger.append_param(params,'p_to_name',p_to_name);
  logger.append_param(params,'p_to_email',p_to_email);
  logger.append_param(params,'p_subject',p_subject);
  logger.append_param(params,'p_message',p_message);
  logger.append_param(params,'p_private_api_key',case when p_private_api_key is null then 'null' else 'not null' end);
  logger.append_param(params,'p_my_domain',p_my_domain);
  logger.append_param(params,'p_api_url',p_api_url);
  logger.append_param(params,'p_wallet_path',p_wallet_path);
  logger.append_param(params,'p_wallet_password',case when p_wallet_password is null then 'null' else 'not null' end);
  logger.log('START', scope, null, params);
  
  -- set up settings just for this call  
  load_settings;  
  if p_private_api_key != default_no_change then
    g_setting(setting_private_api_key) := p_private_api_key;
  end if;
  if p_my_domain != default_no_change then
    g_setting(setting_my_domain) := p_my_domain;
  end if;
  if p_api_url != default_no_change then
    g_setting(setting_api_url) := p_api_url;
  end if;
  if p_wallet_path != default_no_change then
    g_setting(setting_wallet_path) := p_wallet_path;
  end if;
  if p_wallet_password != default_no_change then
    g_setting(setting_wallet_password) := p_wallet_password;
  end if;

  payload := t_mailgun_email
    ( requested_ts => systimestamp
    , from_name    => nvl(p_from_name, case when p_from_email is null then setting(setting_default_sender_name) end)
    , from_email   => nvl(p_from_email, setting(setting_default_sender_email))
    , reply_to     => ''
    , to_name      => p_to_name
    , to_email     => p_to_email
    , cc           => ''
    , bcc          => ''
    , subject      => nvl(p_subject
                         ,'test subject '
                          || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF')
                          || ' ' || get_global_name)
    , message      => nvl(p_message
                         ,'This test email was sent from '
                          || get_global_name
                          || ' at '
                          || to_char(systimestamp,'DD/MM/YYYY HH24:MI:SS.FF'))
    , tag          => ''
    , mail_headers => ''
    , recipient    => g_recipient
    , attachment   => g_attachment
    );

  send_email(p_payload => payload);
    
  -- reset everything back to normal  
  reset;
  
  logger.log('END', scope, null, params);
exception
  when others then
    logger.log_error('Unhandled Exception', scope, null, params);
    reset;
    raise;
end send_test_email;

end mailgun_pkg;
/

show errors