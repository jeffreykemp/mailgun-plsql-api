begin
  dbms_scheduler.drop_job('mailgun_process_queue');
end;
/

begin
  dbms_aqadm.stop_queue (user||'.mailgun_queue');
  dbms_aqadm.drop_queue (user||'.mailgun_queue'); 
  dbms_aqadm.drop_queue_table (user||'.mailgun_queue_tab');  
end;
/

drop table mailgun_email_log;
drop type t_mailgun_email;
drop type t_mailgun_attachment_arr;
drop type t_mailgun_recipient_arr;
drop type t_mailgun_attachment;
drop type t_mailgun_recipient;
drop package mailgun_pkg;
drop package mailgun_aq_pkg;