prompt create_tables.sql
-- tables for mailgun v0.6

-- table to record logs of sent/attempted emails
create table mailgun_email_log
  ( requested_ts    timestamp
  , sent_ts         timestamp
  , from_name       varchar2(4000)
  , from_email      varchar2(4000)
  , reply_to        varchar2(4000)
  , to_name         varchar2(4000)
  , to_email        varchar2(4000)
  , cc              varchar2(4000)
  , bcc             varchar2(4000)
  , subject         varchar2(4000)
  , message         varchar2(4000)
  , tag             varchar2(4000)
  , mail_headers    varchar2(4000)
  , recipients      varchar2(4000)
  , attachments     varchar2(4000)
  , total_bytes     integer
  , mailgun_id      varchar2(4000)
  , mailgun_message varchar2(4000)
  );

-- table to store the mailgun parameters for this system
create table mailgun_settings
  ( setting_name    varchar2(100) not null
  , setting_value   varchar2(4000)
  , constraint mailgun_settings_pk primary key (setting_name)
  );