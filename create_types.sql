drop type t_mailgun_email;
drop type t_mailgun_attachment_arr;
drop type t_mailgun_recipient_arr;
drop type t_mailgun_attachment;
drop type t_mailgun_recipient;

create type t_mailgun_recipient is object
  ( send_by    varchar2(3)
  , email_spec varchar2(1000)
  , email      varchar2(512)
  , name       varchar2(200)
  , first_name varchar2(200)
  , last_name  varchar2(200)
  , id         varchar2(200)
  );
/

create type t_mailgun_attachment is object
  ( file_name    varchar2(512)
  , blob_content blob
  , clob_content clob
  , header       varchar2(4000)
  );
/

create type t_mailgun_recipient_arr is table of t_mailgun_recipient;
/

create type t_mailgun_attachment_arr is table of t_mailgun_attachment;
/

create type t_mailgun_email is object
  ( requested_ts   timestamp
  , from_name      varchar2(4000)
  , from_email     varchar2(4000)
  , reply_to       varchar2(4000)
  , to_name        varchar2(4000)
  , to_email       varchar2(4000)
  , cc             varchar2(4000)
  , bcc            varchar2(4000)
  , subject        varchar2(4000)
  , message        clob
  , tag            varchar2(4000)
  , recipient      t_mailgun_recipient_arr
  , attachment     t_mailgun_attachment_arr
  );
/