-- table to record logs of sent/attempted emails
drop table mailgun_email_log;
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
  , recipients      varchar2(4000)
  , attachments     varchar2(4000)
  , total_bytes     integer
  , mailgun_id      varchar2(4000)
  , mailgun_message varchar2(4000)
  );