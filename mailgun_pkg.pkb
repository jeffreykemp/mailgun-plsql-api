CREATE OR REPLACE PACKAGE BODY mailgun_pkg IS
  /* mailgun API v1.1 15/9/2018
    https://github.com/jeffreykemp/mailgun-plsql-api
    by Jeffrey Kemp
  */

  -- default settings if these are not found in the settings table
  default_api_url            CONSTANT VARCHAR2(4000) := 'https://api.mailgun.net/v3/';
  default_log_retention_days CONSTANT NUMBER := 30;
  default_queue_expiration   CONSTANT INTEGER := 24 * 60 * 60; -- failed emails expire from the queue after 24 hours
  default_whitelist_action   CONSTANT VARCHAR2(100) := whitelist_raise_exception;

  boundary          CONSTANT VARCHAR2(100) := '-----lgryztl0v2vk7fw3njd6cutmxtwysb';
  max_recipients    CONSTANT INTEGER := 1000; -- mailgun limitation for recipient variables
  queue_name        CONSTANT VARCHAR2(30) := sys_context('userenv',
                                                         'current_schema') ||
                                             '.mailgun_queue';
  queue_table       CONSTANT VARCHAR2(30) := sys_context('userenv',
                                                         'current_schema') ||
                                             '.mailgun_queue_tab';
  exc_queue_name    CONSTANT VARCHAR2(30) := sys_context('userenv',
                                                         'current_schema') ||
                                             '.aq$_mailgun_queue_tab_e';
  job_name          CONSTANT VARCHAR2(30) := 'mailgun_process_queue';
  purge_job_name    CONSTANT VARCHAR2(30) := 'mailgun_purge_logs';
  payload_type      CONSTANT VARCHAR2(30) := sys_context('userenv',
                                                         'current_schema') ||
                                             '.t_mailgun_email';
  max_dequeue_count CONSTANT INTEGER := 1000; -- max emails processed by push_queue in one go

  -- mailgun setting names
  setting_public_api_key         CONSTANT VARCHAR2(100) := 'public_api_key';
  setting_private_api_key        CONSTANT VARCHAR2(100) := 'private_api_key';
  setting_my_domain              CONSTANT VARCHAR2(100) := 'my_domain';
  setting_api_url                CONSTANT VARCHAR2(100) := 'api_url';
  setting_wallet_path            CONSTANT VARCHAR2(100) := 'wallet_path';
  setting_wallet_password        CONSTANT VARCHAR2(100) := 'wallet_password';
  setting_log_retention_days     CONSTANT VARCHAR2(100) := 'log_retention_days';
  setting_default_sender_name    CONSTANT VARCHAR2(100) := 'default_sender_name';
  setting_default_sender_email   CONSTANT VARCHAR2(100) := 'default_sender_email';
  setting_queue_expiration       CONSTANT VARCHAR2(100) := 'queue_expiration';
  setting_prod_instance_name     CONSTANT VARCHAR2(100) := 'prod_instance_name';
  setting_non_prod_recipient     CONSTANT VARCHAR2(100) := 'non_prod_recipient';
  setting_required_sender_domain CONSTANT VARCHAR2(100) := 'required_sender_domain';
  setting_recipient_whitelist    CONSTANT VARCHAR2(100) := 'recipient_whitelist';
  setting_whitelist_action       CONSTANT VARCHAR2(100) := 'whitelist_action';
  setting_max_email_size_mb      CONSTANT VARCHAR2(100) := 'max_email_size_mb';

  TYPE t_key_val_arr IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(100);

  g_recipient   t_mailgun_recipient_arr;
  g_attachment  t_mailgun_attachment_arr;
  g_setting     t_key_val_arr;
  g_whitelist   apex_application_global.vc_arr2;
  g_total_bytes NUMBER; -- track total size of email

  e_no_queue_data EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_no_queue_data, -25228);

  /******************************************************************************
  **                                                                           **
  **                              PRIVATE METHODS                              **
  **                                                                           **
  ******************************************************************************/

  PROCEDURE assert
  (
    cond IN BOOLEAN,
    err  IN VARCHAR2
  ) IS
  BEGIN
    IF NOT cond
    THEN
      raise_application_error(-20000,
                              $$PLSQL_UNIT || ' assertion failed: ' || err);
    END IF;
  END assert;

  -- set or update a setting
  PROCEDURE set_setting
  (
    p_name  IN VARCHAR2,
    p_value IN VARCHAR2
  ) IS
  BEGIN
  
    assert(p_name IS NOT NULL, 'p_name cannot be null');
  
    MERGE INTO mailgun_settings t
    USING (SELECT p_name  AS setting_name,
                  p_value AS setting_value
           FROM   dual) s
    ON (t.setting_name = s.setting_name)
    WHEN MATCHED THEN
      UPDATE SET t.setting_value = s.setting_value
    WHEN NOT MATCHED THEN
      INSERT
        (setting_name,
         setting_value)
      VALUES
        (s.setting_name,
         s.setting_value);
  
    COMMIT;
  
    -- cause the settings to be reloaded in this session
    reset;
  
  END set_setting;

  -- retrieve all the settings for a normal session
  PROCEDURE load_settings IS
  BEGIN
  
    -- set defaults first
    g_setting(setting_api_url) := default_api_url;
    g_setting(setting_wallet_path) := '';
    g_setting(setting_wallet_password) := '';
    g_setting(setting_log_retention_days) := default_log_retention_days;
    g_setting(setting_default_sender_name) := '';
    g_setting(setting_default_sender_email) := '';
    g_setting(setting_queue_expiration) := default_queue_expiration;
    g_setting(setting_prod_instance_name) := '';
    g_setting(setting_non_prod_recipient) := '';
    g_setting(setting_required_sender_domain) := '';
    g_setting(setting_recipient_whitelist) := '';
    g_setting(setting_whitelist_action) := default_whitelist_action;
    g_setting(setting_max_email_size_mb) := '';
  
    FOR r IN (SELECT s.setting_name,
                     s.setting_value
              FROM   mailgun_settings s)
    LOOP
    
      g_setting(r.setting_name) := r.setting_value;
    
    END LOOP;
  
    IF g_setting(setting_whitelist_action) IS NOT NULL
    THEN
      g_whitelist := apex_util.string_to_table(g_setting(setting_recipient_whitelist),
                                               ';');
    END IF;
  
  END load_settings;

  -- get a setting
  -- if p_default is set, a null/not found will return the default value
  -- if p_default is null, a not found will raise an exception
  FUNCTION setting(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    p_value mailgun_settings.setting_value%TYPE;
  BEGIN
  
    assert(p_name IS NOT NULL, 'p_name cannot be null');
  
    -- prime the settings array for this session
    IF g_setting.count = 0
    THEN
      load_settings;
    END IF;
  
    p_value := g_setting(p_name);
  
    RETURN p_value;
  EXCEPTION
    WHEN no_data_found THEN
      raise_application_error(-20000,
                              'mailgun setting not set "' || p_name ||
                              '" - please setup using ' || $$PLSQL_UNIT ||
                              '.init()');
  END setting;

  FUNCTION log_retention_days RETURN NUMBER IS
  BEGIN
    RETURN to_number(setting(setting_log_retention_days));
  END log_retention_days;

  FUNCTION max_email_size_bytes RETURN NUMBER IS
  BEGIN
    RETURN to_number(setting(setting_max_email_size_mb)) * 1024 * 1024;
  END max_email_size_bytes;

  FUNCTION get_global_name RETURN VARCHAR2 result_cache IS
    gn global_name.global_name%TYPE;
  BEGIN
  
    SELECT g.global_name INTO gn FROM sys.global_name g;
  
    RETURN gn;
  END get_global_name;

  PROCEDURE prod_check
  (
    p_is_prod            OUT BOOLEAN,
    p_non_prod_recipient OUT VARCHAR2
  ) IS
    prod_instance_name mailgun_settings.setting_value%TYPE;
  BEGIN
  
    prod_instance_name := setting(setting_prod_instance_name);
  
    IF prod_instance_name IS NOT NULL
    THEN
      p_is_prod := prod_instance_name = get_global_name;
    ELSE
      p_is_prod := TRUE; -- if setting not set, we treat this as a prod env
    END IF;
  
    IF NOT p_is_prod
    THEN
      p_non_prod_recipient := setting(setting_non_prod_recipient);
    END IF;
  
  END prod_check;

  FUNCTION enc_chars(m IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN regexp_replace(asciistr(m), '\\([0-9A-F]{4})', '&#x\1;');
  END enc_chars;

  FUNCTION enc_chars(clob_content IN CLOB) RETURN CLOB IS
    file_len PLS_INTEGER;
    modulo   PLS_INTEGER;
    pieces   PLS_INTEGER;
    amt      BINARY_INTEGER := 2000;
    buf      VARCHAR2(32767);
    filepos  PLS_INTEGER := 1;
    counter  PLS_INTEGER := 1;
    out_clob CLOB;
  BEGIN
  
    assert(clob_content IS NOT NULL,
           'enc_chars: clob_content cannot be null');
    sys.dbms_lob.createtemporary(out_clob, FALSE, sys.dbms_lob.call);
    file_len := sys.dbms_lob.getlength(clob_content);
    modulo   := MOD(file_len, amt);
    pieces   := trunc(file_len / amt);
    WHILE (counter <= pieces)
    LOOP
      sys.dbms_lob.read(clob_content, amt, filepos, buf);
      buf := enc_chars(buf);
      sys.dbms_lob.writeappend(out_clob, length(buf), buf);
      filepos := counter * amt + 1;
      counter := counter + 1;
    END LOOP;
    IF (modulo <> 0)
    THEN
      sys.dbms_lob.read(clob_content, modulo, filepos, buf);
      buf := enc_chars(buf);
      sys.dbms_lob.writeappend(out_clob, length(buf), buf);
    END IF;
  
    RETURN out_clob;
  END enc_chars;

  -- lengthb doesn't work directly for clobs, and dbms_lob.getlength returns number of chars, not bytes
  FUNCTION clob_size_bytes(clob_content IN CLOB) RETURN INTEGER IS
    ret    INTEGER := 0;
    chunks INTEGER;
    chunk_size CONSTANT INTEGER := 2000;
  BEGIN
  
    chunks := ceil(sys.dbms_lob.getlength(clob_content) / chunk_size);
  
    FOR i IN 1 .. chunks
    LOOP
      ret := ret +
             lengthb(sys.dbms_lob.substr(clob_content,
                                         amount       => chunk_size,
                                         offset       => (i - 1) * chunk_size + 1));
    END LOOP;
  
    RETURN ret;
  END clob_size_bytes;

  FUNCTION utc_to_session_tz(ts IN VARCHAR2) RETURN TIMESTAMP IS
  BEGIN
    RETURN to_timestamp_tz(ts, 'Dy, dd Mon yyyy hh24:mi:ss tzr') at LOCAL;
  END utc_to_session_tz;

  -- do some minimal checking of the format of an email address without going to an external service
  PROCEDURE val_email_min(email IN VARCHAR2) IS
  BEGIN
  
    IF email IS NOT NULL
    THEN
      IF instr(email, '@') = 0
      THEN
        raise_application_error(-20001,
                                'email address must include @ ("' || email || '")');
      END IF;
    END IF;
  
  END val_email_min;

  PROCEDURE log_headers(resp IN OUT NOCOPY sys.utl_http.resp) IS
    NAME  VARCHAR2(256);
    VALUE VARCHAR2(1024);
  BEGIN
  
    FOR i IN 1 .. sys.utl_http.get_header_count(resp)
    LOOP
      sys.utl_http.get_header(resp, i, NAME, VALUE);
    END LOOP;
  
  END log_headers;

  PROCEDURE set_wallet IS
    wallet_path     VARCHAR2(4000);
    wallet_password VARCHAR2(4000);
  BEGIN
  
    wallet_path     := setting(setting_wallet_path);
    wallet_password := setting(setting_wallet_password);
  
    IF wallet_path IS NOT NULL OR
       wallet_password IS NOT NULL
    THEN
      sys.utl_http.set_wallet(wallet_path, wallet_password);
    END IF;
  
  END set_wallet;

  FUNCTION get_response(resp IN OUT NOCOPY sys.utl_http.resp) RETURN CLOB IS
    buf VARCHAR2(32767);
    ret CLOB := empty_clob;
  BEGIN
  
    sys.dbms_lob.createtemporary(ret, TRUE);
  
    BEGIN
      LOOP
        sys.utl_http.read_text(resp, buf, 32767);
        sys.dbms_lob.writeappend(ret, length(buf), buf);
      END LOOP;
    EXCEPTION
      WHEN sys.utl_http.end_of_body THEN
        NULL;
    END;
    sys.utl_http.end_response(resp);
  
    RETURN ret;
  END get_response;

  FUNCTION get_json
  (
    p_url    IN VARCHAR2,
    p_params IN VARCHAR2 := NULL,
    p_user   IN VARCHAR2 := NULL,
    p_pwd    IN VARCHAR2 := NULL,
    p_method IN VARCHAR2 := 'GET'
  ) RETURN CLOB IS
    url  VARCHAR2(4000) := p_url;
    req  sys.utl_http.req;
    resp sys.utl_http.resp;
    ret  CLOB;
  BEGIN
  
    assert(p_url IS NOT NULL, 'get_json: p_url cannot be null');
    assert(p_method IS NOT NULL, 'get_json: p_method cannot be null');
  
    IF p_params IS NOT NULL
    THEN
      url := url || '?' || p_params;
    END IF;
  
    set_wallet;
  
    req := sys.utl_http.begin_request(url => url, method => p_method);
  
    IF p_user IS NOT NULL OR
       p_pwd IS NOT NULL
    THEN
      sys.utl_http.set_authentication(req, p_user, p_pwd);
    END IF;
  
    sys.utl_http.set_header(req, 'Accept', 'application/json');
  
    resp := sys.utl_http.get_response(req);
  
    log_headers(resp);
  
    IF resp.status_code != '200'
    THEN
      raise_application_error(-20000,
                              'get_json call failed ' || resp.status_code || ' ' ||
                              resp.reason_phrase || ' [' || url || ']');
    END IF;
  
    ret := get_response(resp);
  
    RETURN ret;
  END get_json;

  FUNCTION rcpt_count RETURN NUMBER IS
    ret INTEGER := 0;
  BEGIN
  
    IF g_recipient IS NOT NULL
    THEN
      ret := g_recipient.count;
    END IF;
  
    RETURN ret;
  END rcpt_count;

  FUNCTION attch_count RETURN NUMBER IS
    ret INTEGER := 0;
  BEGIN
  
    IF g_attachment IS NOT NULL
    THEN
      ret := g_attachment.count;
    END IF;
  
    RETURN ret;
  END attch_count;

  PROCEDURE add_recipient
  (
    p_email      IN VARCHAR2,
    p_name       IN VARCHAR2,
    p_first_name IN VARCHAR2,
    p_last_name  IN VARCHAR2,
    p_id         IN VARCHAR2,
    p_send_by    IN VARCHAR2
  ) IS
    NAME VARCHAR2(4000);
  BEGIN
  
    assert(rcpt_count < max_recipients,
           'maximum recipients per email exceeded (' || max_recipients || ')');
  
    assert(p_email IS NOT NULL, 'add_recipient: p_email cannot be null');
    assert(p_send_by IS NOT NULL,
           'add_recipient: p_send_by cannot be null');
    assert(p_send_by IN ('to', 'cc', 'bcc'), 'p_send_by must be to/cc/bcc');
  
    -- don't allow a list of email addresses in one call
    assert(instr(p_email, ',') = 0,
           'add_recipient: p_email cannot contain commas (,)');
    assert(instr(p_email, ';') = 0,
           'add_recipient: p_email cannot contain semicolons (;)');
  
    val_email_min(p_email);
  
    NAME := nvl(p_name, TRIM(p_first_name || ' ' || p_last_name));
  
    IF g_recipient IS NULL
    THEN
      g_recipient := t_mailgun_recipient_arr();
    END IF;
    g_recipient.extend(1);
    g_recipient(g_recipient.last) := t_mailgun_recipient(send_by    => p_send_by,
                                                         email_spec => CASE
                                                                         WHEN p_email LIKE '% <%>' THEN
                                                                          p_email
                                                                         ELSE
                                                                          nvl(NAME, p_email) || ' <' || p_email || '>'
                                                                       END,
                                                         email      => CASE
                                                                         WHEN p_email LIKE '% <%>' THEN
                                                                          rtrim(ltrim(regexp_substr(p_email,
                                                                                                    '<.*>',
                                                                                                    1,
                                                                                                    1),
                                                                                      '<'),
                                                                                '>')
                                                                         ELSE
                                                                          p_email
                                                                       END,
                                                         NAME       => NAME,
                                                         first_name => p_first_name,
                                                         last_name  => p_last_name,
                                                         id         => p_id);
  
  END add_recipient;

  FUNCTION attachment_header
  (
    p_file_name    IN VARCHAR2,
    p_content_type IN VARCHAR2,
    p_inline       IN BOOLEAN
  ) RETURN VARCHAR2 IS
    ret VARCHAR2(4000);
  BEGIN
  
    assert(p_file_name IS NOT NULL,
           'attachment_header: p_file_name cannot be null');
    assert(p_content_type IS NOT NULL,
           'attachment_header: p_content_type cannot be null');
  
    ret := '--' || boundary || crlf ||
           'Content-Disposition: form-data; name="' || CASE
             WHEN p_inline THEN
              'inline'
             ELSE
              'attachment'
           END || '"; filename="' || p_file_name || '"' || crlf ||
           'Content-Type: ' || p_content_type || crlf || crlf;
  
    RETURN ret;
  END attachment_header;

  PROCEDURE add_attachment
  (
    p_file_name    IN VARCHAR2,
    p_blob_content IN BLOB := NULL,
    p_clob_content IN CLOB := NULL,
    p_content_type IN VARCHAR2,
    p_inline       IN BOOLEAN
  ) IS
    max_size        NUMBER;
    attachment_size NUMBER;
    header          VARCHAR2(4000);
  BEGIN
    header := attachment_header(p_file_name    => p_file_name,
                                p_content_type => p_content_type,
                                p_inline       => p_inline);
  
    max_size := max_email_size_bytes;
  
    IF p_clob_content IS NOT NULL
    THEN
      attachment_size := clob_size_bytes(p_clob_content);
    ELSIF p_blob_content IS NOT NULL
    THEN
      attachment_size := sys.dbms_lob.getlength(p_blob_content);
    END IF;
  
    attachment_size := attachment_size + length(header);
  
    IF attachment_size > max_size
    THEN
      raise_application_error(-20000,
                              'attachment too large (' || p_file_name || ' ' ||
                              attachment_size || ' bytes; max is ' ||
                              max_size || ')');
    END IF;
  
    g_total_bytes := g_total_bytes + attachment_size;
  
    IF g_total_bytes > max_size
    THEN
      raise_application_error(-20000,
                              'total size of all attachments too large (' ||
                              g_total_bytes || ' bytes; max is ' ||
                              max_size || ')');
    END IF;
  
    IF g_attachment IS NULL
    THEN
      g_attachment := t_mailgun_attachment_arr();
    END IF;
    g_attachment.extend(1);
    g_attachment(g_attachment.last) := t_mailgun_attachment(file_name    => p_file_name,
                                                            blob_content => p_blob_content,
                                                            clob_content => p_clob_content,
                                                            header       => header);
  
  END add_attachment;

  FUNCTION field_header(p_tag IN VARCHAR2) RETURN VARCHAR2 IS
    ret VARCHAR2(4000);
  BEGIN
  
    assert(p_tag IS NOT NULL, 'field_header: p_tag cannot be null');
    ret := '--' || boundary || crlf ||
           'Content-Disposition: form-data; name="' || p_tag || '"' || crlf || crlf;
  
    RETURN ret;
  END field_header;

  FUNCTION form_field
  (
    p_tag  IN VARCHAR2,
    p_data IN VARCHAR2
  ) RETURN VARCHAR2 IS
    ret VARCHAR2(4000);
  BEGIN
  
    ret := CASE
             WHEN p_data IS NOT NULL THEN
              field_header(p_tag) || p_data || crlf
           END;
  
    RETURN ret;
  END form_field;

  FUNCTION render_mail_headers(p_mail_headers IN VARCHAR2) RETURN VARCHAR2 IS
    vals apex_json.t_values;
    tag  VARCHAR2(32767);
    val  apex_json.t_value;
    buf  VARCHAR2(32767);
  BEGIN
  
    apex_json.parse(vals, p_mail_headers);
  
    tag := vals.first;
    LOOP
      EXIT WHEN tag IS NULL;
    
      val := vals(tag);
    
      -- Mailgun accepts arbitrary MIME headers with the "h:" prefix, e.g.
      -- h:Priority
      CASE val.kind
        WHEN apex_json.c_varchar2 THEN
          buf := buf || form_field('h:' || tag, val.varchar2_value);
        WHEN apex_json.c_number THEN
          buf := buf || form_field('h:' || tag, to_char(val.number_value));
        ELSE
          NULL;
      END CASE;
    
      tag := vals.next(tag);
    END LOOP;
  
    RETURN buf;
  END render_mail_headers;

  PROCEDURE write_text
  (
    req IN OUT NOCOPY sys.utl_http.req,
    buf IN VARCHAR2
  ) IS
  BEGIN
  
    sys.utl_http.write_text(req, buf);
  
  END write_text;

  PROCEDURE write_clob
  (
    req          IN OUT NOCOPY sys.utl_http.req,
    file_content IN CLOB
  ) IS
    file_len PLS_INTEGER;
    modulo   PLS_INTEGER;
    pieces   PLS_INTEGER;
    amt      BINARY_INTEGER := 32767;
    buf      VARCHAR2(32767);
  
    filepos PLS_INTEGER := 1;
    counter PLS_INTEGER := 1;
  BEGIN
  
    assert(file_content IS NOT NULL,
           'write_clob: file_content cannot be null');
    file_len := sys.dbms_lob.getlength(file_content);
    modulo   := MOD(file_len, amt);
    pieces   := trunc(file_len / amt);
    WHILE (counter <= pieces)
    LOOP
      sys.dbms_lob.read(file_content, amt, filepos, buf);
      write_text(req, buf);
      filepos := counter * amt + 1;
      counter := counter + 1;
    END LOOP;
    IF (modulo <> 0)
    THEN
      sys.dbms_lob.read(file_content, modulo, filepos, buf);
      write_text(req, buf);
    END IF;
  
  END write_clob;

  PROCEDURE write_blob
  (
    req          IN OUT NOCOPY sys.utl_http.req,
    file_content IN OUT NOCOPY BLOB
  ) IS
    file_len PLS_INTEGER;
    modulo   PLS_INTEGER;
    pieces   PLS_INTEGER;
    amt      BINARY_INTEGER := 2000;
    buf      RAW(2000);
    filepos  PLS_INTEGER := 1;
    counter  PLS_INTEGER := 1;
  BEGIN
  
    assert(file_content IS NOT NULL,
           'write_blob: file_content cannot be null');
    file_len := sys.dbms_lob.getlength(file_content);
    modulo   := MOD(file_len, amt);
    pieces   := trunc(file_len / amt);
    WHILE (counter <= pieces)
    LOOP
      sys.dbms_lob.read(file_content, amt, filepos, buf);
      sys.utl_http.write_raw(req, buf);
      filepos := counter * amt + 1;
      counter := counter + 1;
    END LOOP;
    IF (modulo <> 0)
    THEN
      sys.dbms_lob.read(file_content, modulo, filepos, buf);
      sys.utl_http.write_raw(req, buf);
    END IF;
  
  END write_blob;

  PROCEDURE send_email(p_payload IN OUT NOCOPY t_mailgun_email) IS
    url                VARCHAR2(32767) := setting(setting_api_url) ||
                                          setting(setting_my_domain) ||
                                          '/messages';
    header             CLOB;
    sender             VARCHAR2(4000);
    recipients_to      VARCHAR2(32767);
    recipients_cc      VARCHAR2(32767);
    recipients_bcc     VARCHAR2(32767);
    footer             VARCHAR2(100);
    attachment_size    INTEGER;
    resp_text          VARCHAR2(32767);
    recipient_count    INTEGER := 0;
    attachment_count   INTEGER := 0;
    subject            VARCHAR2(4000);
    is_prod            BOOLEAN;
    non_prod_recipient VARCHAR2(255);
    log                mailgun_email_log%ROWTYPE;
  
    PROCEDURE append_recipient
    (
      rcpt_list IN OUT VARCHAR2,
      r         IN t_mailgun_recipient
    ) IS
    BEGIN
      IF rcpt_list IS NOT NULL
      THEN
        rcpt_list := rcpt_list || ',';
      END IF;
      rcpt_list := rcpt_list || r.email_spec;
    END append_recipient;
  
    PROCEDURE add_recipient_variable(r IN t_mailgun_recipient) IS
    BEGIN
      apex_json.open_object(r.email);
      apex_json.write('email', r.email);
      apex_json.write('name', r.name);
      apex_json.write('first_name', r.first_name);
      apex_json.write('last_name', r.last_name);
      apex_json.write('id', r.id);
      apex_json.close_object;
    END add_recipient_variable;
  
    PROCEDURE append_header(buf IN VARCHAR2) IS
    BEGIN
      sys.dbms_lob.writeappend(header, length(buf), buf);
    END append_header;
  
    PROCEDURE mailgun_post IS
      req  sys.utl_http.req;
      resp sys.utl_http.resp;
    BEGIN
    
      -- Turn off checking of status code. We will check it by ourselves.
      sys.utl_http.set_response_error_check(FALSE);
    
      set_wallet;
    
      req := sys.utl_http.begin_request(url, 'POST');
    
      sys.utl_http.set_authentication(req,
                                      'api',
                                      setting(setting_private_api_key)); -- Use HTTP Basic Authen. Scheme
    
      sys.utl_http.set_header(req,
                              'Content-Type',
                              'multipart/form-data; boundary="' || boundary || '"');
      sys.utl_http.set_header(req, 'Content-Length', log.total_bytes);
    
      write_clob(req, header);
    
      sys.dbms_lob.freetemporary(header);
    
      IF attachment_count > 0
      THEN
        FOR i IN 1 .. attachment_count
        LOOP
        
          write_text(req, p_payload.attachment(i).header);
        
          IF p_payload.attachment(i).clob_content IS NOT NULL
          THEN
            write_clob(req, p_payload.attachment(i).clob_content);
          ELSIF p_payload.attachment(i).blob_content IS NOT NULL
          THEN
            write_blob(req, p_payload.attachment(i).blob_content);
          END IF;
        
          write_text(req, crlf);
        
        END LOOP;
      END IF;
    
      write_text(req, footer);
    
      DECLARE
        my_scheme VARCHAR2(256);
        my_realm  VARCHAR2(256);
      BEGIN
        resp := sys.utl_http.get_response(req);
      
        log_headers(resp);
      
        IF resp.status_code = sys.utl_http.http_unauthorized
        THEN
          sys.utl_http.get_authentication(resp, my_scheme, my_realm, FALSE);
          raise_application_error(-20000, 'unauthorized');
        ELSIF resp.status_code = sys.utl_http.http_proxy_auth_required
        THEN
          sys.utl_http.get_authentication(resp, my_scheme, my_realm, TRUE);
          raise_application_error(-20000, 'proxy auth required');
        END IF;
      
        IF resp.status_code != '200'
        THEN
          raise_application_error(-20000,
                                  'post failed ' || resp.status_code || ' ' ||
                                  resp.reason_phrase || ' [' || url || ']');
        END IF;
      
        -- expected response will be a json document like this:
        --{
        --  "id": "<messageid@domain>",
        --  "message": "Queued. Thank you."
        --}
        resp_text := get_response(resp);
      
      EXCEPTION
        WHEN OTHERS THEN
          sys.utl_http.end_response(resp);
          RAISE;
      END;
    
    END mailgun_post;
  
    PROCEDURE log_response IS
      -- needs to commit the log entry independently of calling transaction
      PRAGMA AUTONOMOUS_TRANSACTION;
      buf VARCHAR2(32767);
    BEGIN
      buf := substr(p_payload.message, 1, 4000);
    
      log.sent_ts      := systimestamp;
      log.requested_ts := p_payload.requested_ts;
      log.from_name    := p_payload.reply_to;
      log.from_email   := p_payload.from_email;
      log.reply_to     := p_payload.reply_to;
      log.to_name      := p_payload.to_name;
      log.to_email     := p_payload.to_email;
      log.cc           := p_payload.cc;
      log.bcc          := p_payload.bcc;
      log.subject      := subject;
      log.message      := substr(buf, 1, 4000);
      log.tag          := p_payload.tag;
      log.mail_headers := substr(p_payload.mail_headers, 1, 4000);
      log.recipients   := substr(recipients_to, 1, 4000);
    
      BEGIN
        apex_json.parse(resp_text);
        log.mailgun_id      := apex_json.get_varchar2('id');
        log.mailgun_message := apex_json.get_varchar2('message');
      EXCEPTION
        WHEN OTHERS THEN
          log.mailgun_message := substr(resp_text, 1, 4000);
      END;
    
      INSERT INTO mailgun_email_log VALUES log;
    
      COMMIT;
    
    END log_response;
  
  BEGIN
  
    assert(p_payload.from_email IS NOT NULL,
           'send_email: from_email cannot be null');
  
    prod_check(p_is_prod            => is_prod,
               p_non_prod_recipient => non_prod_recipient);
  
    IF p_payload.recipient IS NOT NULL
    THEN
      recipient_count := p_payload.recipient.count;
    END IF;
  
    IF p_payload.attachment IS NOT NULL
    THEN
      attachment_count := p_payload.attachment.count;
    END IF;
  
    IF p_payload.from_email LIKE '% <%>%'
    THEN
      sender := p_payload.from_email;
    ELSE
      sender := nvl(p_payload.from_name, p_payload.from_email) || ' <' ||
                p_payload.from_email || '>';
    END IF;
  
    -- construct recipient lists
  
    IF NOT is_prod AND
       non_prod_recipient IS NOT NULL
    THEN
    
      -- replace all recipients with the non-prod recipient
      recipients_to := non_prod_recipient;
    
    ELSE
    
      IF p_payload.to_email IS NOT NULL
      THEN
        assert(recipient_count = 0,
               'cannot mix multiple recipients with to_email parameter');
      
        IF p_payload.to_name IS NOT NULL AND
           p_payload.to_email NOT LIKE '% <%>%' AND
           instr(p_payload.to_email, ',') = 0 AND
           instr(p_payload.to_email, ';') = 0
        THEN
          -- to_email is just a single, simple email address, and we have a to_name
          recipients_to := nvl(p_payload.to_name, p_payload.to_email) || ' <' ||
                           p_payload.to_email || '>';
        ELSE
          -- to_email is a formatted name+email, or a list, or we don't have any to_name
          recipients_to := REPLACE(p_payload.to_email, ';', ',');
        END IF;
      
      END IF;
    
      recipients_cc  := REPLACE(p_payload.cc, ';', ',');
      recipients_bcc := REPLACE(p_payload.bcc, ';', ',');
    
      IF recipient_count > 0
      THEN
        FOR i IN 1 .. recipient_count
        LOOP
          -- construct the comma-delimited recipient lists
          CASE p_payload.recipient(i).send_by
            WHEN 'to' THEN
              append_recipient(recipients_to, p_payload.recipient(i));
            WHEN 'cc' THEN
              append_recipient(recipients_cc, p_payload.recipient(i));
            WHEN 'bcc' THEN
              append_recipient(recipients_bcc, p_payload.recipient(i));
          END CASE;
        END LOOP;
      END IF;
    
    END IF;
  
    assert(recipients_to IS NOT NULL,
           'send_email: recipients list cannot be empty');
  
    sys.dbms_lob.createtemporary(header, FALSE, sys.dbms_lob.call);
  
    subject := substr(p_payload.subject
                      -- in non-prod environments, append the env name to the subject
                      || CASE
                        WHEN NOT is_prod THEN
                         ' *' || get_global_name || '*'
                      END,
                      1,
                      4000);
  
    append_header(crlf || form_field('from', sender) ||
                  form_field('h:Reply-To', p_payload.reply_to) ||
                  form_field('to', recipients_to) ||
                  form_field('cc', recipients_cc) ||
                  form_field('bcc', recipients_bcc) ||
                  form_field('o:tag', p_payload.tag) ||
                  form_field('subject', subject));
  
    IF recipient_count > 0
    THEN
      BEGIN
        -- construct the recipient variables json object
        apex_json.initialize_clob_output;
        apex_json.open_object;
        FOR i IN 1 .. recipient_count
        LOOP
          add_recipient_variable(p_payload.recipient(i));
        END LOOP;
        apex_json.close_object;
      
        append_header(field_header('recipient-variables'));
        sys.dbms_lob.append(header, apex_json.get_clob_output);
      
        apex_json.free_output;
      EXCEPTION
        WHEN OTHERS THEN
          apex_json.free_output;
          RAISE;
      END;
    END IF;
  
    IF p_payload.mail_headers IS NOT NULL
    THEN
      append_header(render_mail_headers(p_payload.mail_headers));
    END IF;
  
    append_header(field_header('html'));
    sys.dbms_lob.append(header, p_payload.message);
    append_header(crlf);
  
    footer := '--' || boundary || '--';
  
    -- encode characters (like MS Word "smart quotes") that the mail system can't handle
    header := enc_chars(header);
  
    log.total_bytes := clob_size_bytes(header) + length(footer);
  
    IF attachment_count > 0
    THEN
      FOR i IN 1 .. attachment_count
      LOOP
      
        IF p_payload.attachment(i).clob_content IS NOT NULL
        THEN
          attachment_size := clob_size_bytes(p_payload.attachment(i)
                                             .clob_content);
        ELSIF p_payload.attachment(i).blob_content IS NOT NULL
        THEN
          attachment_size := sys.dbms_lob.getlength(p_payload.attachment(i)
                                                    .blob_content);
        END IF;
      
        log.total_bytes := log.total_bytes +
                           length(p_payload.attachment(i).header) +
                           attachment_size + length(crlf);
      
        IF log.attachments IS NOT NULL
        THEN
          log.attachments := log.attachments || ', ';
        END IF;
        log.attachments := log.attachments || p_payload.attachment(i)
                          .file_name || ' (' || attachment_size ||
                           ' bytes)';
      
      END LOOP;
    END IF;
  
    IF is_prod OR
       non_prod_recipient IS NOT NULL
    THEN
    
      -- this is the bit that actually connects to mailgun to send the email
      mailgun_post;
    
    ELSE
    
      resp_text := 'email suppressed: ' || get_global_name;
    
    END IF;
  
    log_response;
  
  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        IF header IS NOT NULL
        THEN
          sys.dbms_lob.freetemporary(header);
        END IF;
      EXCEPTION
        WHEN OTHERS THEN
          NULL;
      END;
      RAISE;
  END send_email;

  FUNCTION get_epoch(p_date IN DATE) RETURN NUMBER AS
    /*
    Purpose: get epoch (number of seconds since January 1, 1970)
    Credit: Alexandria PL/SQL Library (AMAZON_AWS_AUTH_PKG)
    https://github.com/mortenbra/alexandria-plsql-utils
    Who     Date        Description
    ------  ----------  -------------------------------------
    MBR     09.01.2011  Created
    */
  BEGIN
    RETURN trunc((p_date - DATE '1970-01-01') * 24 * 60 * 60);
  END get_epoch;

  FUNCTION epoch_to_dt(p_epoch IN NUMBER) RETURN DATE AS
  BEGIN
    RETURN DATE '1970-01-01' +(p_epoch / 24 / 60 / 60);
  END epoch_to_dt;

  PROCEDURE url_param
  (
    buf  IN OUT VARCHAR2,
    attr IN VARCHAR2,
    val  IN VARCHAR2
  ) IS
  BEGIN
  
    IF val IS NOT NULL
    THEN
      IF buf IS NOT NULL
      THEN
        buf := buf || '&';
      END IF;
      buf := buf || attr || '=' || apex_util.url_encode(val);
    END IF;
  
  END url_param;

  PROCEDURE url_param
  (
    buf  IN OUT VARCHAR2,
    attr IN VARCHAR2,
    dt   IN DATE
  ) IS
  BEGIN
  
    IF dt IS NOT NULL
    THEN
      IF buf IS NOT NULL
      THEN
        buf := buf || '&';
      END IF;
      buf := buf || attr || '=' || get_epoch(dt);
    END IF;
  
  END url_param;

  -- return a comma-delimited string based on the array found at p_path (must already contain a %d), with
  -- all values for the given attribute
  FUNCTION json_arr_csv
  (
    p_path IN VARCHAR2,
    p0     IN VARCHAR2,
    p_attr IN VARCHAR2
  ) RETURN VARCHAR2 IS
    cnt NUMBER;
    buf VARCHAR2(32767);
  BEGIN
  
    cnt := apex_json.get_count(p_path, p0);
    FOR i IN 1 .. cnt
    LOOP
      IF buf IS NOT NULL
      THEN
        buf := buf || ',';
      END IF;
      buf := buf ||
             apex_json.get_varchar2(p_path || '[%d].' || p_attr, p0, i);
    END LOOP;
  
    RETURN buf;
  END json_arr_csv;

  -- comma-delimited list of attributes, plus values if required
  FUNCTION json_members_csv
  (
    p_path   IN VARCHAR2,
    p0       IN VARCHAR2,
    p_values IN BOOLEAN
  ) RETURN VARCHAR2 IS
    arr wwv_flow_t_varchar2;
    buf VARCHAR2(32767);
  BEGIN
  
    arr := apex_json.get_members(p_path, p0);
    IF arr.count > 0
    THEN
      FOR i IN 1 .. arr.count
      LOOP
        IF buf IS NOT NULL
        THEN
          buf := buf || ',';
        END IF;
        buf := buf || arr(i);
        IF p_values
        THEN
          buf := buf || '=' ||
                 apex_json.get_varchar2(p_path || '.' || arr(i), p0);
        END IF;
      END LOOP;
    END IF;
  
    RETURN buf;
  EXCEPTION
    WHEN value_error /*not an array or object*/
     THEN
      RETURN NULL;
  END json_members_csv;

  -- return the name portion of the email address
  FUNCTION get_mailbox(p_email IN VARCHAR2) RETURN VARCHAR2 IS
    ret VARCHAR2(255);
  BEGIN
  
    ret := substr(p_email, 1, instr(p_email, '@') - 1);
  
    RETURN ret;
  END get_mailbox;

  -- check one email address against the whitelist, take action if necessary
  FUNCTION whitelist_check_one(p_email IN VARCHAR2) RETURN VARCHAR2 IS
    i   PLS_INTEGER;
    ret VARCHAR2(4000);
  BEGIN
  
    IF p_email IS NOT NULL AND
       g_whitelist.count > 0
    THEN
      i := g_whitelist.first;
      LOOP
        EXIT WHEN i IS NULL;
      
        IF TRIM(lower(p_email)) LIKE TRIM(lower(g_whitelist(i)))
        THEN
          ret := p_email;
        END IF;
      
        i := g_whitelist.next(i);
      END LOOP;
    
      IF ret IS NULL
      THEN
        -- match not found: take whitelist action
        CASE setting(setting_whitelist_action)
          WHEN whitelist_suppress THEN
            ret := NULL;
          WHEN whitelist_raise_exception THEN
            raise_application_error(-20000,
                                    'Recipient email address blocked by whitelist (' ||
                                    p_email || ')');
          ELSE
            -- handle %@example.com or exact@example.com
            ret := REPLACE(setting(setting_whitelist_action),
                           '%',
                           get_mailbox(p_email));
        END CASE;
      END IF;
    
    ELSE
      ret := p_email;
    END IF;
  
    RETURN ret;
  END whitelist_check_one;

  -- split the email (potentially a list of email addresses, or name<email>)
  -- into each email; check each against the whitelist; reconstruct the new
  -- email list
  FUNCTION whitelist_check(p_email IN VARCHAR2) RETURN VARCHAR2 IS
    l_emails apex_application_global.vc_arr2;
    l_name   VARCHAR2(4000);
    l_email  VARCHAR2(4000);
    ret      VARCHAR2(4000);
  BEGIN
  
    IF p_email IS NOT NULL AND
       g_whitelist.count > 0
    THEN
    
      l_emails := apex_util.string_to_table(p_email, ',');
      IF l_emails.count > 0
      THEN
        FOR i IN 1 .. l_emails.count
        LOOP
        
          l_name  := '';
          l_email := TRIM(l_emails(i));
        
          IF l_email LIKE '% <%>'
          THEN
            -- split into name + email
            l_name  := substr(l_email, 1, instr(l_email, '<') - 1);
            l_email := TRIM(substr(l_email, instr(l_email, '<') + 1));
            l_email := TRIM(rtrim(l_email, '>'));
          END IF;
        
          l_email := whitelist_check_one(p_email => l_email);
        
          IF l_email IS NOT NULL
          THEN
            IF ret IS NOT NULL
            THEN
              ret := ret || ';';
            END IF;
            IF l_name IS NOT NULL
            THEN
              ret := ret || l_name || ' <' || l_email || '>';
            ELSE
              ret := ret || l_email;
            END IF;
          END IF;
        
        END LOOP;
      END IF;
    
    ELSE
      ret := p_email;
    END IF;
  
    RETURN ret;
  END whitelist_check;

  /******************************************************************************
  **                                                                           **
  **                              PUBLIC METHODS                               **
  **                                                                           **
  ******************************************************************************/

  PROCEDURE init
  (
    p_public_api_key         IN VARCHAR2 := default_no_change,
    p_private_api_key        IN VARCHAR2 := default_no_change,
    p_my_domain              IN VARCHAR2 := default_no_change,
    p_api_url                IN VARCHAR2 := default_no_change,
    p_wallet_path            IN VARCHAR2 := default_no_change,
    p_wallet_password        IN VARCHAR2 := default_no_change,
    p_log_retention_days     IN NUMBER := NULL,
    p_default_sender_name    IN VARCHAR2 := default_no_change,
    p_default_sender_email   IN VARCHAR2 := default_no_change,
    p_queue_expiration       IN NUMBER := NULL,
    p_prod_instance_name     IN VARCHAR2 := default_no_change,
    p_non_prod_recipient     IN VARCHAR2 := default_no_change,
    p_required_sender_domain IN VARCHAR2 := default_no_change,
    p_recipient_whitelist    IN VARCHAR2 := default_no_change,
    p_whitelist_action       IN VARCHAR2 := default_no_change,
    p_max_email_size_mb      IN VARCHAR2 := default_no_change
  ) IS
  BEGIN
  
    IF nvl(p_public_api_key, '*') != default_no_change
    THEN
      set_setting(setting_public_api_key, p_public_api_key);
    END IF;
  
    IF nvl(p_private_api_key, '*') != default_no_change
    THEN
      set_setting(setting_private_api_key, p_private_api_key);
    END IF;
  
    IF nvl(p_my_domain, '*') != default_no_change
    THEN
      set_setting(setting_my_domain, p_my_domain);
    END IF;
  
    IF nvl(p_api_url, '*') != default_no_change
    THEN
      set_setting(setting_api_url, p_api_url);
    END IF;
  
    IF nvl(p_wallet_path, '*') != default_no_change
    THEN
      set_setting(setting_wallet_path, p_wallet_path);
    END IF;
  
    IF nvl(p_wallet_password, '*') != default_no_change
    THEN
      set_setting(setting_wallet_password, p_wallet_password);
    END IF;
  
    IF p_log_retention_days IS NOT NULL
    THEN
      set_setting(setting_log_retention_days, p_log_retention_days);
    END IF;
  
    IF nvl(p_default_sender_name, '*') != default_no_change
    THEN
      set_setting(setting_default_sender_name, p_default_sender_name);
    END IF;
  
    IF nvl(p_default_sender_email, '*') != default_no_change
    THEN
      set_setting(setting_default_sender_email, p_default_sender_email);
    END IF;
  
    IF p_queue_expiration IS NOT NULL
    THEN
      set_setting(setting_queue_expiration, p_queue_expiration);
    END IF;
  
    IF nvl(p_prod_instance_name, '*') != default_no_change
    THEN
      set_setting(setting_prod_instance_name, p_prod_instance_name);
    END IF;
  
    IF nvl(p_non_prod_recipient, '*') != default_no_change
    THEN
      set_setting(setting_non_prod_recipient, p_non_prod_recipient);
    END IF;
  
    IF nvl(p_required_sender_domain, '*') != default_no_change
    THEN
      set_setting(setting_required_sender_domain, p_required_sender_domain);
    END IF;
  
    IF nvl(p_recipient_whitelist, '*') != default_no_change
    THEN
      set_setting(setting_recipient_whitelist, p_recipient_whitelist);
    END IF;
  
    IF nvl(p_whitelist_action, '*') != default_no_change
    THEN
      set_setting(setting_whitelist_action, p_whitelist_action);
    END IF;
  
    IF nvl(p_max_email_size_mb, '*') != default_no_change
    THEN
      set_setting(setting_max_email_size_mb, p_max_email_size_mb);
    END IF;
  
  END init;

  PROCEDURE validate_email
  (
    p_address    IN VARCHAR2,
    p_is_valid   OUT BOOLEAN,
    p_suggestion OUT VARCHAR2
  ) IS
    str          CLOB;
    is_valid_str VARCHAR2(100);
  BEGIN
  
    assert(p_address IS NOT NULL,
           'validate_email: p_address cannot be null');
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                'address/validate',
                    p_params => 'address=' || apex_util.url_encode(p_address),
                    p_user   => 'api',
                    p_pwd    => setting(setting_public_api_key));
  
    apex_json.parse(str);
  
    is_valid_str := apex_json.get_varchar2('is_valid');
  
    p_is_valid := is_valid_str = 'true';
  
    p_suggestion := apex_json.get_varchar2('did_you_mean');
  
  END validate_email;

  FUNCTION email_is_valid(p_address IN VARCHAR2) RETURN BOOLEAN IS
    is_valid   BOOLEAN;
    suggestion VARCHAR2(512);
  BEGIN
  
    validate_email(p_address    => p_address,
                   p_is_valid   => is_valid,
                   p_suggestion => suggestion);
  
    RETURN is_valid;
  END email_is_valid;

  PROCEDURE send_email
  (
    p_from_name    IN VARCHAR2 := NULL,
    p_from_email   IN VARCHAR2 := NULL,
    p_reply_to     IN VARCHAR2 := NULL,
    p_to_name      IN VARCHAR2 := NULL,
    p_to_email     IN VARCHAR2 := NULL -- optional if the send_xx have been called already
   ,
    p_cc           IN VARCHAR2 := NULL,
    p_bcc          IN VARCHAR2 := NULL,
    p_subject      IN VARCHAR2,
    p_message      IN CLOB -- html allowed
   ,
    p_tag          IN VARCHAR2 := NULL,
    p_mail_headers IN VARCHAR2 := NULL -- json structure of tag/value pairs
   ,
    p_priority     IN NUMBER := default_priority -- lower numbers are processed first
  ) IS
    r_enq_opts      sys.dbms_aq.enqueue_options_t;
    r_enq_msg_props sys.dbms_aq.message_properties_t;
    payload         t_mailgun_email;
    msgid           RAW(16);
    l_from_name     VARCHAR2(200);
    l_from_email    VARCHAR2(512);
    l_to_email      VARCHAR2(4000);
    l_cc            VARCHAR2(4000);
    l_bcc           VARCHAR2(4000);
    max_size        NUMBER;
  BEGIN
  
    IF p_to_email IS NOT NULL
    THEN
      assert(rcpt_count = 0,
             'cannot mix multiple recipients with p_to_email parameter');
    END IF;
  
    assert(p_priority IS NOT NULL, 'p_priority cannot be null');
  
    -- we only use the default sender name if both sender name + email are null
    l_from_name := nvl(p_from_name,
                       CASE
                         WHEN p_from_email IS NULL THEN
                          setting(setting_default_sender_name)
                       END);
    l_from_email := nvl(p_from_email, setting(setting_default_sender_email));
  
    -- check if sender is in required sender domain
    IF p_from_email IS NOT NULL AND
       setting(setting_required_sender_domain) IS NOT NULL AND
       p_from_email NOT LIKE
       '%@' || setting(setting_required_sender_domain)
    THEN
    
      l_from_email := setting(setting_default_sender_email);
    
      IF l_from_email IS NULL
      THEN
        raise_application_error(-20000,
                                'Sender domain not allowed (' ||
                                p_from_email || ')');
      END IF;
    
    END IF;
  
    assert(l_from_email IS NOT NULL, 'from_email cannot be null');
  
    val_email_min(l_from_email);
    val_email_min(p_reply_to);
    val_email_min(p_to_email);
    val_email_min(p_cc);
    val_email_min(p_bcc);
  
    l_to_email := whitelist_check(p_to_email);
    l_cc       := whitelist_check(p_cc);
    l_bcc      := whitelist_check(p_bcc);
  
    assert(rcpt_count > 0 OR coalesce(l_to_email, l_cc, l_bcc) IS NOT NULL,
           'must be at least one recipient');
  
    max_size := max_email_size_bytes;
    -- g_total_bytes at this stage is total size of all attachments
    -- add in the length of the subject, and message, plus a margin for error for other overhead
    g_total_bytes := g_total_bytes + length(p_subject) +
                     sys.dbms_lob.getlength(p_message) + 1000;
    IF g_total_bytes > max_size
    THEN
      raise_application_error(-20000,
                              'total email too large (est. ' ||
                              g_total_bytes || ' bytes; max ' || max_size || ')');
    END IF;
  
    payload := t_mailgun_email(requested_ts => systimestamp,
                               from_name    => l_from_name,
                               from_email   => l_from_email,
                               reply_to     => p_reply_to,
                               to_name      => p_to_name,
                               to_email     => l_to_email,
                               cc           => l_cc,
                               bcc          => l_bcc,
                               subject      => p_subject,
                               message      => p_message,
                               tag          => p_tag,
                               mail_headers => p_mail_headers,
                               recipient    => g_recipient,
                               attachment   => g_attachment);
  
    reset;
  
    r_enq_msg_props.expiration := setting(setting_queue_expiration);
    r_enq_msg_props.priority   := p_priority;
  
    sys.dbms_aq.enqueue(queue_name         => queue_name,
                        enqueue_options    => r_enq_opts,
                        message_properties => r_enq_msg_props,
                        payload            => payload,
                        msgid              => msgid);
  
  END send_email;

  PROCEDURE send_to
  (
    p_email      IN VARCHAR2,
    p_name       IN VARCHAR2 := NULL,
    p_first_name IN VARCHAR2 := NULL,
    p_last_name  IN VARCHAR2 := NULL,
    p_id         IN VARCHAR2 := NULL,
    p_send_by    IN VARCHAR2 := 'to'
  ) IS
    l_email VARCHAR2(255);
  BEGIN
  
    l_email := whitelist_check(p_email);
  
    IF l_email IS NOT NULL
    THEN
    
      add_recipient(p_email      => l_email,
                    p_name       => p_name,
                    p_first_name => p_first_name,
                    p_last_name  => p_last_name,
                    p_id         => p_id,
                    p_send_by    => p_send_by);
    
    END IF;
  
  END send_to;

  PROCEDURE send_cc
  (
    p_email      IN VARCHAR2,
    p_name       IN VARCHAR2 := NULL,
    p_first_name IN VARCHAR2 := NULL,
    p_last_name  IN VARCHAR2 := NULL,
    p_id         IN VARCHAR2 := NULL
  ) IS
    l_email VARCHAR2(255);
  BEGIN
  
    l_email := whitelist_check(p_email);
  
    IF l_email IS NOT NULL
    THEN
    
      add_recipient(p_email      => l_email,
                    p_name       => p_name,
                    p_first_name => p_first_name,
                    p_last_name  => p_last_name,
                    p_id         => p_id,
                    p_send_by    => 'cc');
    
    END IF;
  
  END send_cc;

  PROCEDURE send_bcc
  (
    p_email      IN VARCHAR2,
    p_name       IN VARCHAR2 := NULL,
    p_first_name IN VARCHAR2 := NULL,
    p_last_name  IN VARCHAR2 := NULL,
    p_id         IN VARCHAR2 := NULL
  ) IS
    l_email VARCHAR2(255);
  BEGIN
  
    l_email := whitelist_check(p_email);
  
    IF l_email IS NOT NULL
    THEN
    
      add_recipient(p_email      => l_email,
                    p_name       => p_name,
                    p_first_name => p_first_name,
                    p_last_name  => p_last_name,
                    p_id         => p_id,
                    p_send_by    => 'bcc');
    
    END IF;
  
  END send_bcc;

  PROCEDURE attach
  (
    p_file_content IN BLOB,
    p_file_name    IN VARCHAR2,
    p_content_type IN VARCHAR2,
    p_inline       IN BOOLEAN := FALSE
  ) IS
  BEGIN
  
    assert(p_file_content IS NOT NULL,
           'attach(blob): p_file_content cannot be null');
  
    add_attachment(p_file_name    => p_file_name,
                   p_blob_content => p_file_content,
                   p_content_type => p_content_type,
                   p_inline       => p_inline);
  
  END attach;

  PROCEDURE attach
  (
    p_file_content IN CLOB,
    p_file_name    IN VARCHAR2,
    p_content_type IN VARCHAR2,
    p_inline       IN BOOLEAN := FALSE
  ) IS
  BEGIN
  
    assert(p_file_content IS NOT NULL,
           'attach(clob): p_file_content cannot be null');
  
    add_attachment(p_file_name    => p_file_name,
                   p_clob_content => p_file_content,
                   p_content_type => p_content_type,
                   p_inline       => p_inline);
  
  END attach;

  PROCEDURE reset IS
  BEGIN
  
    IF g_recipient IS NOT NULL
    THEN
      g_recipient.delete;
    END IF;
  
    IF g_attachment IS NOT NULL
    THEN
      g_attachment.delete;
    END IF;
  
    -- we also drop the settings so they are reloaded between calls, in case they
    -- are changed
    g_setting.delete;
    g_whitelist.delete;
  
    g_total_bytes := NULL;
  
  END reset;

  PROCEDURE create_queue
  (
    p_max_retries IN NUMBER := default_max_retries,
    p_retry_delay IN NUMBER := default_retry_delay
  ) IS
  BEGIN
  
    sys.dbms_aqadm.create_queue_table(queue_table        => queue_table,
                                      queue_payload_type => payload_type,
                                      sort_list          => 'priority,enq_time',
                                      storage_clause     => 'nested table user_data.recipient store as mailgun_recipient_tab' ||
                                                            ',nested table user_data.attachment store as mailgun_attachment_tab');
  
    sys.dbms_aqadm.create_queue(queue_name  => queue_name,
                                queue_table => queue_table,
                                max_retries => p_max_retries,
                                retry_delay => p_retry_delay);
  
    sys.dbms_aqadm.start_queue(queue_name);
  
  END create_queue;

  PROCEDURE drop_queue IS
  BEGIN
  
    sys.dbms_aqadm.stop_queue(queue_name);
  
    sys.dbms_aqadm.drop_queue(queue_name);
  
    sys.dbms_aqadm.drop_queue_table(queue_table);
  
  END drop_queue;

  PROCEDURE purge_queue(p_msg_state IN VARCHAR2 := default_purge_msg_state) IS
    r_opt sys.dbms_aqadm.aq$_purge_options_t;
  BEGIN
  
    sys.dbms_aqadm.purge_queue_table(queue_table     => queue_table,
                                     purge_condition => CASE
                                                          WHEN p_msg_state IS NOT NULL THEN
                                                           REPLACE(q'[ qtview.msg_state = '#STATE#' ]',
                                                                   '#STATE#',
                                                                   p_msg_state)
                                                        END,
                                     purge_options   => r_opt);
  
  END purge_queue;

  PROCEDURE push_queue(p_asynchronous IN BOOLEAN := FALSE) AS
    r_dequeue_options    sys.dbms_aq.dequeue_options_t;
    r_message_properties sys.dbms_aq.message_properties_t;
    msgid                RAW(16);
    payload              t_mailgun_email;
    dequeue_count        INTEGER := 0;
    job                  BINARY_INTEGER;
  BEGIN
  
    IF p_asynchronous
    THEN
    
      -- use dbms_job so that it is only run if/when this session commits
    
      sys.dbms_job.submit(job  => job,
                          what => $$PLSQL_UNIT || '.push_queue;');
    
    ELSE
    
      -- commit any emails requested in the current session
      COMMIT;
    
      r_dequeue_options.wait := sys.dbms_aq.no_wait;
    
      -- loop through all messages in the queue until there is none
      -- exit this loop when the e_no_queue_data exception is raised.
      LOOP
      
        sys.dbms_aq.dequeue(queue_name         => queue_name,
                            dequeue_options    => r_dequeue_options,
                            message_properties => r_message_properties,
                            payload            => payload,
                            msgid              => msgid);
      
        -- process the message
        send_email(p_payload => payload);
      
        COMMIT; -- the queue will treat the message as succeeded
      
        -- don't bite off everything in one go
        dequeue_count := dequeue_count + 1;
        EXIT WHEN dequeue_count >= max_dequeue_count;
      END LOOP;
    
    END IF;
  
  EXCEPTION
    WHEN e_no_queue_data THEN
      NULL;
    WHEN OTHERS THEN
      ROLLBACK; -- the queue will treat the message as failed
      RAISE;
  END push_queue;

  PROCEDURE re_queue AS
    -- for this to work, the exception queue must first be started, e.g.:
    -- exec dbms_aqadm.start_queue('owner.aq$_mailgun_queue_tab_e',false, true);
    r_dequeue_options    sys.dbms_aq.dequeue_options_t;
    r_message_properties sys.dbms_aq.message_properties_t;
    r_enq_opts           sys.dbms_aq.enqueue_options_t;
    r_enq_msg_props      sys.dbms_aq.message_properties_t;
    msgid                RAW(16);
    payload              t_mailgun_email;
    dequeue_count        INTEGER := 0;
  BEGIN
  
    r_dequeue_options.wait := sys.dbms_aq.no_wait;
  
    -- loop through all messages in the queue until there is none
    -- exit this loop when the e_no_queue_data exception is raised.
    LOOP
    
      sys.dbms_aq.dequeue(queue_name         => exc_queue_name,
                          dequeue_options    => r_dequeue_options,
                          message_properties => r_message_properties,
                          payload            => payload,
                          msgid              => msgid);
    
      r_enq_msg_props.expiration := setting(setting_queue_expiration);
      r_enq_msg_props.priority   := r_message_properties.priority;
    
      sys.dbms_aq.enqueue(queue_name         => queue_name,
                          enqueue_options    => r_enq_opts,
                          message_properties => r_enq_msg_props,
                          payload            => payload,
                          msgid              => msgid);
    
      --  logger.log('commit', scope, null, params);
      COMMIT; -- the queue will treat the message as succeeded
    
      -- don't bite off everything in one go
      dequeue_count := dequeue_count + 1;
      EXIT WHEN dequeue_count >= max_dequeue_count;
    END LOOP;
  
  EXCEPTION
    WHEN e_no_queue_data THEN
      NULL;
    WHEN OTHERS THEN
      ROLLBACK; -- the queue will treat the message as failed
      RAISE;
  END re_queue;

  PROCEDURE create_job(p_repeat_interval IN VARCHAR2 := default_repeat_interval) IS
  BEGIN
  
    assert(p_repeat_interval IS NOT NULL,
           'create_job: p_repeat_interval cannot be null');
  
    sys.dbms_scheduler.create_job(job_name        => job_name,
                                  job_type        => 'stored_procedure',
                                  job_action      => $$PLSQL_UNIT ||
                                                     '.push_queue',
                                  start_date      => systimestamp,
                                  repeat_interval => p_repeat_interval);
  
    sys.dbms_scheduler.set_attribute(job_name, 'restartable', TRUE);
  
    sys.dbms_scheduler.enable(job_name);
  
  END create_job;

  PROCEDURE drop_job IS
  BEGIN
  
    BEGIN
      sys.dbms_scheduler.stop_job(job_name);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -27366 /*job already stopped*/
        THEN
          RAISE;
        END IF;
    END;
  
    sys.dbms_scheduler.drop_job(job_name);
  
  END drop_job;

  PROCEDURE purge_logs(p_log_retention_days IN NUMBER := NULL) IS
    l_log_retention_days NUMBER;
  BEGIN
  
    l_log_retention_days := nvl(p_log_retention_days, log_retention_days);
  
    DELETE mailgun_email_log
    WHERE  requested_ts < SYSDATE - l_log_retention_days;
  
    COMMIT;
  
  END purge_logs;

  PROCEDURE create_purge_job(p_repeat_interval IN VARCHAR2 := default_purge_repeat_interval) IS
  BEGIN
  
    assert(p_repeat_interval IS NOT NULL,
           'create_purge_job: p_repeat_interval cannot be null');
  
    sys.dbms_scheduler.create_job(job_name        => purge_job_name,
                                  job_type        => 'stored_procedure',
                                  job_action      => $$PLSQL_UNIT ||
                                                     '.purge_logs',
                                  start_date      => systimestamp,
                                  repeat_interval => p_repeat_interval);
  
    sys.dbms_scheduler.set_attribute(job_name, 'restartable', TRUE);
  
    sys.dbms_scheduler.enable(purge_job_name);
  
  END create_purge_job;

  PROCEDURE drop_purge_job IS
  BEGIN
  
    BEGIN
      sys.dbms_scheduler.stop_job(purge_job_name);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -27366 /*job already stopped*/
        THEN
          RAISE;
        END IF;
    END;
  
    sys.dbms_scheduler.drop_job(purge_job_name);
  
  END drop_purge_job;

  -- get mailgun stats
  FUNCTION get_stats
  (
    p_event_types IN VARCHAR2 := 'all',
    p_resolution  IN VARCHAR2 := NULL,
    p_start_time  IN DATE := NULL,
    p_end_time    IN DATE := NULL,
    p_duration    IN NUMBER := NULL
  ) RETURN t_mailgun_stat_arr
    PIPELINED IS
    prm         VARCHAR2(4000);
    str         CLOB;
    stats_count NUMBER;
    res         VARCHAR2(10);
    dt          DATE;
  
    FUNCTION get_stat
    (
      i           IN INTEGER,
      stat_name   IN VARCHAR2,
      stat_detail IN VARCHAR2
    ) RETURN t_mailgun_stat IS
    BEGIN
      RETURN t_mailgun_stat(stat_datetime => dt,
                            resolution    => res,
                            stat_name     => stat_name,
                            stat_detail   => stat_detail,
                            val           => nvl(apex_json.get_number(p_path => 'stats[%d].' ||
                                                                                stat_name || '.' ||
                                                                                stat_detail,
                                                                      p0     => i),
                                                 0));
    END get_stat;
  BEGIN
  
    assert(p_event_types IS NOT NULL, 'p_event_types cannot be null');
    assert(p_resolution IN ('hour', 'day', 'month'),
           'p_resolution must be day, month or hour');
    assert(p_start_time IS NULL OR p_duration IS NULL,
           'p_start_time or p_duration may be set but not both');
    assert(p_duration >= 1 AND p_duration = trunc(p_duration),
           'p_duration must be a positive integer');
  
    IF lower(p_event_types) = 'all'
    THEN
      prm := 'accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored';
    ELSE
      prm := REPLACE(lower(p_event_types), ' ', '');
    END IF;
    -- convert comma-delimited list to parameter list
    prm := 'event=' ||
           REPLACE(apex_util.url_encode(prm), ',', '&' || 'event=');
  
    url_param(prm, 'start', p_start_time);
    url_param(prm, 'end', p_end_time);
    url_param(prm, 'resolution', p_resolution);
    IF p_duration IS NOT NULL
    THEN
      url_param(prm, 'duration', p_duration || substr(p_resolution, 1, 1));
    END IF;
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/stats/total',
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    apex_json.parse(str);
  
    stats_count := apex_json.get_count('stats');
    res         := apex_json.get_varchar2('resolution');
  
    IF stats_count > 0
    THEN
      FOR i IN 1 .. stats_count
      LOOP
        dt := utc_to_session_tz(apex_json.get_varchar2(p_path => 'stats[%d].time',
                                                       p0     => i));
        PIPE ROW(get_stat(i, 'accepted', 'incoming'));
        PIPE ROW(get_stat(i, 'accepted', 'outgoing'));
        PIPE ROW(get_stat(i, 'accepted', 'total'));
        PIPE ROW(get_stat(i, 'delivered', 'smtp'));
        PIPE ROW(get_stat(i, 'delivered', 'http'));
        PIPE ROW(get_stat(i, 'delivered', 'total'));
        PIPE ROW(get_stat(i, 'failed.temporary', 'espblock'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-bounce'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-unsubscribe'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-complaint'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'bounce'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'total'));
        PIPE ROW(get_stat(i, 'stored', 'total'));
        PIPE ROW(get_stat(i, 'opened', 'total'));
        PIPE ROW(get_stat(i, 'clicked', 'total'));
        PIPE ROW(get_stat(i, 'unsubscribed', 'total'));
        PIPE ROW(get_stat(i, 'complained', 'total'));
      END LOOP;
    END IF;
  
    RETURN;
  END get_stats;

  -- get mailgun stats
  FUNCTION get_tag_stats
  (
    p_tag         IN VARCHAR2,
    p_event_types IN VARCHAR2 := 'all',
    p_resolution  IN VARCHAR2 := NULL,
    p_start_time  IN DATE := NULL,
    p_end_time    IN DATE := NULL,
    p_duration    IN NUMBER := NULL
  ) RETURN t_mailgun_stat_arr
    PIPELINED IS
    prm         VARCHAR2(4000);
    str         CLOB;
    stats_count NUMBER;
    res         VARCHAR2(10);
    dt          DATE;
  
    FUNCTION get_stat
    (
      i           IN INTEGER,
      stat_name   IN VARCHAR2,
      stat_detail IN VARCHAR2
    ) RETURN t_mailgun_stat IS
    BEGIN
      RETURN t_mailgun_stat(stat_datetime => dt,
                            resolution    => res,
                            stat_name     => stat_name,
                            stat_detail   => stat_detail,
                            val           => nvl(apex_json.get_number(p_path => 'stats[%d].' ||
                                                                                stat_name || '.' ||
                                                                                stat_detail,
                                                                      p0     => i),
                                                 0));
    END get_stat;
  BEGIN
  
    assert(p_tag IS NOT NULL, 'p_tag cannot be null');
    assert(instr(p_tag, ' ') = 0, 'p_tag cannot contain spaces');
    assert(p_event_types IS NOT NULL, 'p_event_types cannot be null');
    assert(p_resolution IN ('hour', 'day', 'month'),
           'p_resolution must be day, month or hour');
    assert(p_start_time IS NULL OR p_duration IS NULL,
           'p_start_time or p_duration may be set but not both');
    assert(p_duration >= 1 AND p_duration = trunc(p_duration),
           'p_duration must be a positive integer');
  
    IF lower(p_event_types) = 'all'
    THEN
      prm := 'accepted,delivered,failed,opened,clicked,unsubscribed,complained,stored';
    ELSE
      prm := REPLACE(lower(p_event_types), ' ', '');
    END IF;
    -- convert comma-delimited list to parameter list
    prm := 'event=' ||
           REPLACE(apex_util.url_encode(prm), ',', '&' || 'event=');
  
    url_param(prm, 'start', p_start_time);
    url_param(prm, 'end', p_end_time);
    url_param(prm, 'resolution', p_resolution);
    IF p_duration IS NOT NULL
    THEN
      url_param(prm, 'duration', p_duration || substr(p_resolution, 1, 1));
    END IF;
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/tags/' ||
                                apex_util.url_encode(p_tag) || '/stats',
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    apex_json.parse(str);
  
    stats_count := apex_json.get_count('stats');
    res         := apex_json.get_varchar2('resolution');
  
    IF stats_count > 0
    THEN
      FOR i IN 1 .. stats_count
      LOOP
        dt := utc_to_session_tz(apex_json.get_varchar2(p_path => 'stats[%d].time',
                                                       p0     => i));
        PIPE ROW(get_stat(i, 'accepted', 'incoming'));
        PIPE ROW(get_stat(i, 'accepted', 'outgoing'));
        PIPE ROW(get_stat(i, 'accepted', 'total'));
        PIPE ROW(get_stat(i, 'delivered', 'smtp'));
        PIPE ROW(get_stat(i, 'delivered', 'http'));
        PIPE ROW(get_stat(i, 'delivered', 'total'));
        PIPE ROW(get_stat(i, 'failed.temporary', 'espblock'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-bounce'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-unsubscribe'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'suppress-complaint'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'bounce'));
        PIPE ROW(get_stat(i, 'failed.permanent', 'total'));
        PIPE ROW(get_stat(i, 'stored', 'total'));
        PIPE ROW(get_stat(i, 'opened', 'total'));
        PIPE ROW(get_stat(i, 'clicked', 'total'));
        PIPE ROW(get_stat(i, 'unsubscribed', 'total'));
        PIPE ROW(get_stat(i, 'complained', 'total'));
      END LOOP;
    END IF;
  
    RETURN;
  END get_tag_stats;

  FUNCTION get_events
  (
    p_start_time IN DATE := NULL,
    p_end_time   IN DATE := NULL,
    p_page_size  IN NUMBER := default_page_size -- max 300
   ,
    p_event      IN VARCHAR2 := NULL,
    p_sender     IN VARCHAR2 := NULL,
    p_recipient  IN VARCHAR2 := NULL,
    p_subject    IN VARCHAR2 := NULL,
    p_tags       IN VARCHAR2 := NULL,
    p_severity   IN VARCHAR2 := NULL
  ) RETURN t_mailgun_event_arr
    PIPELINED IS
    prm         VARCHAR2(4000);
    str         CLOB;
    event_count NUMBER;
    url         VARCHAR2(4000);
  BEGIN
  
    assert(p_page_size <= 300,
           'p_page_size cannot be greater than 300 (' || p_page_size || ')');
    assert(p_severity IN ('temporary', 'permanent'),
           'p_severity must be "temporary" or "permanent"');
  
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
    url := setting(setting_api_url) || setting(setting_my_domain) ||
           '/events';
  
    LOOP
    
      str := get_json(p_url    => url,
                      p_params => prm,
                      p_user   => 'api',
                      p_pwd    => setting(setting_private_api_key));
    
      apex_json.parse(str);
    
      event_count := apex_json.get_count('items');
    
      EXIT WHEN event_count = 0;
    
      FOR i IN 1 .. event_count
      LOOP
        PIPE ROW(t_mailgun_event(event             => substr(apex_json.get_varchar2('items[%d].event',
                                                                                    i),
                                                             1,
                                                             100),
                                 event_ts          => epoch_to_dt(apex_json.get_number('items[%d].timestamp',
                                                                                       i)),
                                 event_id          => substr(apex_json.get_varchar2('items[%d].id',
                                                                                    i),
                                                             1,
                                                             200),
                                 message_id        => substr(apex_json.get_varchar2('items[%d].message.headers."message-id"',
                                                                                    i),
                                                             1,
                                                             200),
                                 sender            => substr(apex_json.get_varchar2('items[%d].envelope.sender',
                                                                                    i),
                                                             1,
                                                             4000),
                                 recipient         => substr(apex_json.get_varchar2('items[%d].recipient',
                                                                                    i),
                                                             1,
                                                             4000),
                                 subject           => substr(apex_json.get_varchar2('items[%d].message.headers.subject',
                                                                                    i),
                                                             1,
                                                             4000),
                                 attachments       => substr(json_arr_csv('items[%d].message.attachments',
                                                                          i,
                                                                          'filename'),
                                                             1,
                                                             4000),
                                 size_bytes        => apex_json.get_number('items[%d].message.size',
                                                                           i),
                                 method            => substr(apex_json.get_varchar2('items[%d].method',
                                                                                    i),
                                                             1,
                                                             100),
                                 tags              => substr(json_members_csv('items[%d].tags',
                                                                              i,
                                                                              p_values => FALSE),
                                                             1,
                                                             4000),
                                 user_variables    => substr(json_members_csv('items[%d]."user-variables"',
                                                                              i,
                                                                              p_values => TRUE),
                                                             1,
                                                             4000),
                                 log_level         => substr(apex_json.get_varchar2('items[%d]."log-level"',
                                                                                    i),
                                                             1,
                                                             100),
                                 failed_severity   => substr(apex_json.get_varchar2('items[%d].severity',
                                                                                    i),
                                                             1,
                                                             100),
                                 failed_reason     => substr(apex_json.get_varchar2('items[%d].reason',
                                                                                    i),
                                                             1,
                                                             100),
                                 delivery_status   => substr(TRIM(apex_json.get_varchar2('items[%d]."delivery-status".code',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d]."delivery-status".message',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d]."delivery-status".description',
                                                                                         i)),
                                                             1,
                                                             4000),
                                 geolocation       => substr(TRIM(apex_json.get_varchar2('items[%d].geolocation.country',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d].geolocation.region',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d].geolocation.city',
                                                                                         i)),
                                                             1,
                                                             4000),
                                 recipient_ip      => substr(apex_json.get_varchar2('items[%d].ip',
                                                                                    i),
                                                             1,
                                                             100),
                                 client_info       => substr(TRIM(apex_json.get_varchar2('items[%d]."client-info"."client-type"',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d]."client-info"."client-os"',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d]."client-info"."device-type"',
                                                                                         i) || ' ' ||
                                                                  apex_json.get_varchar2('items[%d]."client-info"."client-name"',
                                                                                         i)),
                                                             1,
                                                             4000),
                                 client_user_agent => substr(apex_json.get_varchar2('items[%d]."client-info"."user-agent"',
                                                                                    i),
                                                             1,
                                                             4000)));
      END LOOP;
    
      -- get next page of results
      prm := NULL;
      url := apex_json.get_varchar2('paging.next');
      -- convert url to use reverse-apache version, if necessary
      url := REPLACE(url, default_api_url, setting(setting_api_url));
      EXIT WHEN url IS NULL;
    END LOOP;
  
    RETURN;
  END get_events;

  FUNCTION get_tags(p_limit IN NUMBER := NULL -- max rows to fetch (default 100)
                    ) RETURN t_mailgun_tag_arr
    PIPELINED IS
    prm        VARCHAR2(4000);
    str        CLOB;
    item_count NUMBER;
  
  BEGIN
  
    url_param(prm, 'limit', p_limit);
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/tags',
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    apex_json.parse(str);
  
    item_count := apex_json.get_count('items');
  
    IF item_count > 0
    THEN
      FOR i IN 1 .. item_count
      LOOP
        PIPE ROW(t_mailgun_tag(tag_name    => substr(apex_json.get_varchar2('items[%d].tag',
                                                                            i),
                                                     1,
                                                     4000),
                               description => substr(apex_json.get_varchar2('items[%d].description',
                                                                            i),
                                                     1,
                                                     4000)));
      END LOOP;
    END IF;
  
    RETURN;
  END get_tags;

  PROCEDURE update_tag
  (
    p_tag         IN VARCHAR2,
    p_description IN VARCHAR2 := NULL
  ) IS
    prm VARCHAR2(4000);
    str CLOB;
  
  BEGIN
  
    assert(p_tag IS NOT NULL, 'p_tag cannot be null');
    assert(instr(p_tag, ' ') = 0, 'p_tag cannot contain spaces');
  
    url_param(prm, 'description', p_description);
  
    str := get_json(p_method => 'PUT',
                    p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/tags/' ||
                                apex_util.url_encode(p_tag),
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    -- normally it returns {"message":"Tag updated"}
  
  END update_tag;

  PROCEDURE delete_tag(p_tag IN VARCHAR2) IS    
    str CLOB;
  
  BEGIN
  
    assert(p_tag IS NOT NULL, 'p_tag cannot be null');
    assert(instr(p_tag, ' ') = 0, 'p_tag cannot contain spaces');
  
    str := get_json(p_method => 'DELETE',
                    p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/tags/' ||
                                apex_util.url_encode(p_tag),
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    -- normally it returns {"message":"Tag deleted"}
  
  END delete_tag;

  FUNCTION get_suppressions
  (
    p_type  IN VARCHAR2 -- 'bounces', 'unsubscribes', or 'complaints'
   ,
    p_limit IN NUMBER := NULL -- max rows to fetch (default 100)
  ) RETURN t_mailgun_suppression_arr
    PIPELINED IS
    prm        VARCHAR2(4000);
    str        CLOB;
    item_count NUMBER;
  
  BEGIN
  
    assert(p_type IS NOT NULL, 'p_type cannot be null');
    assert(p_type IN ('bounces', 'unsubscribes', 'complaints'),
           'p_type must be bounces, unsubscribes, or complaints');
  
    url_param(prm, 'limit', p_limit);
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/' || p_type,
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key));
  
    apex_json.parse(str);
  
    item_count := apex_json.get_count('items');
  
    IF item_count > 0
    THEN
      FOR i IN 1 .. item_count
      LOOP
        PIPE ROW(t_mailgun_suppression(suppression_type => substr(p_type,
                                                                  1,
                                                                  length(p_type) - 1),
                                       email_address    => substr(apex_json.get_varchar2('items[%d].address',
                                                                                         i),
                                                                  1,
                                                                  4000),
                                       unsubscribe_tag  => substr(apex_json.get_varchar2('items[%d].tag',
                                                                                         i),
                                                                  1,
                                                                  4000),
                                       bounce_code      => substr(apex_json.get_varchar2('items[%d].code',
                                                                                         i),
                                                                  1,
                                                                  255),
                                       bounce_error     => substr(apex_json.get_varchar2('items[%d].error',
                                                                                         i),
                                                                  1,
                                                                  4000),
                                       created_dt       => utc_to_session_tz(apex_json.get_varchar2('items[%d].created_at',
                                                                                                    i))));
      END LOOP;
    END IF;
  
    RETURN;
  END get_suppressions;

  -- remove an email address from the bounce list
  PROCEDURE delete_bounce(p_email_address IN VARCHAR2) IS
    str CLOB;
  BEGIN
  
    assert(p_email_address IS NOT NULL, 'p_email_address cannot be null');
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/bounces/' ||
                                apex_util.url_encode(p_email_address),
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key),
                    p_method => 'DELETE');
  
    -- normally it returns {"address":"...the address...","message":"Bounced address has been removed"}
  
  END delete_bounce;

  -- add an email address to the unsubscribe list
  PROCEDURE add_unsubscribe
  (
    p_email_address IN VARCHAR2,
    p_tag           IN VARCHAR2 := NULL
  ) IS
    prm VARCHAR2(4000);
    str CLOB;
  BEGIN
  
    assert(p_email_address IS NOT NULL, 'p_email_address cannot be null');
  
    url_param(prm, 'address', p_email_address);
    url_param(prm, 'tag', p_tag);
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) ||
                                '/unsubscribes',
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key),
                    p_method => 'POST');
  
  END add_unsubscribe;

  -- remove an email address from the unsubscribe list
  PROCEDURE delete_unsubscribe
  (
    p_email_address IN VARCHAR2,
    p_tag           IN VARCHAR2 := NULL
  ) IS
    prm VARCHAR2(4000);
    str CLOB;
  BEGIN
  
    assert(p_email_address IS NOT NULL, 'p_email_address cannot be null');
  
    url_param(prm, 'tag', p_tag);
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) ||
                                '/unsubscribes/' ||
                                apex_util.url_encode(p_email_address),
                    p_params => prm,
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key),
                    p_method => 'DELETE');
  
    -- normally it returns {"message":"Unsubscribe event has been removed"}
  
  END delete_unsubscribe;

  -- remove an email address from the complaint list
  PROCEDURE delete_complaint(p_email_address IN VARCHAR2) IS
    str CLOB;
  BEGIN
  
    assert(p_email_address IS NOT NULL, 'p_email_address cannot be null');
  
    str := get_json(p_url    => setting(setting_api_url) ||
                                setting(setting_my_domain) || '/complaints/' ||
                                apex_util.url_encode(p_email_address),
                    p_user   => 'api',
                    p_pwd    => setting(setting_private_api_key),
                    p_method => 'DELETE');
  
    -- normally it returns {"message":"Spam complaint has been removed"}
  
  END delete_complaint;

  PROCEDURE send_test_email
  (
    p_from_name       IN VARCHAR2 := NULL,
    p_from_email      IN VARCHAR2 := NULL,
    p_to_name         IN VARCHAR2 := NULL,
    p_to_email        IN VARCHAR2,
    p_subject         IN VARCHAR2 := NULL,
    p_message         IN VARCHAR2 := NULL,
    p_private_api_key IN VARCHAR2 := default_no_change,
    p_my_domain       IN VARCHAR2 := default_no_change,
    p_api_url         IN VARCHAR2 := default_no_change,
    p_wallet_path     IN VARCHAR2 := default_no_change,
    p_wallet_password IN VARCHAR2 := default_no_change
  ) IS
    payload t_mailgun_email;
  BEGIN
  
    -- set up settings just for this call
    load_settings;
    IF p_private_api_key != default_no_change
    THEN
      g_setting(setting_private_api_key) := p_private_api_key;
    END IF;
    IF p_my_domain != default_no_change
    THEN
      g_setting(setting_my_domain) := p_my_domain;
    END IF;
    IF p_api_url != default_no_change
    THEN
      g_setting(setting_api_url) := p_api_url;
    END IF;
    IF p_wallet_path != default_no_change
    THEN
      g_setting(setting_wallet_path) := p_wallet_path;
    END IF;
    IF p_wallet_password != default_no_change
    THEN
      g_setting(setting_wallet_password) := p_wallet_password;
    END IF;
  
    payload := t_mailgun_email(requested_ts => systimestamp,
                               from_name    => nvl(p_from_name,
                                                   CASE
                                                     WHEN p_from_email IS NULL THEN
                                                      setting(setting_default_sender_name)
                                                   END),
                               from_email   => nvl(p_from_email,
                                                   setting(setting_default_sender_email)),
                               reply_to     => '',
                               to_name      => p_to_name,
                               to_email     => p_to_email,
                               cc           => '',
                               bcc          => '',
                               subject      => nvl(p_subject,
                                                   'test subject ' ||
                                                   to_char(systimestamp,
                                                           'DD/MM/YYYY HH24:MI:SS.FF') || ' ' ||
                                                   get_global_name),
                               message      => nvl(p_message,
                                                   'This test email was sent from ' ||
                                                   get_global_name || ' at ' ||
                                                   to_char(systimestamp,
                                                           'DD/MM/YYYY HH24:MI:SS.FF')),
                               tag          => '',
                               mail_headers => '',
                               recipient    => g_recipient,
                               attachment   => g_attachment);
  
    send_email(p_payload => payload);
  
    -- reset everything back to normal
    reset;
  
  EXCEPTION
    WHEN OTHERS THEN
      reset;
      RAISE;
  END send_test_email;

END mailgun_pkg;
