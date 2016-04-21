create or replace package body mailgun_aq_pkg is
/* mailgun asynchronous API v0.4
  by Jeffrey Kemp
  
  This is an optional layer on top of mailgun_pkg that makes calls to
  the Mailgun send email feature asynchronous using Oracle AQ.

  Refer to https://github.com/jeffreykemp/mailgun-plsql-api for detailed
  installation instructions and API reference.
*/

queue_name        constant varchar2(30) := 'mailgun_queue';
queue_table       constant varchar2(30) := 'mailgun_queue_tab';
job_name          constant varchar2(30) := 'mailgun_process_queue';
payload_type      constant varchar2(30) := 't_mailgun_email';
max_dequeue_count constant integer := 1000;

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
begin
  msg('send_email ' || p_to_email || ' "' || p_subject || '"');
  
  payload := mailgun_pkg.get_payload
    ( p_from_name    => p_from_name
    , p_from_email   => p_from_email
    , p_reply_to     => p_reply_to
    , p_to_name      => p_to_name
    , p_to_email     => p_to_email
    , p_cc           => p_cc
    , p_bcc          => p_bcc
    , p_subject      => p_subject
    , p_message      => p_message
    , p_tag          => p_tag
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
  
  msg('send_email finished');
exception
  when others then
    msg(sqlerrm);
    msg(dbms_utility.format_error_stack);
    msg(dbms_utility.format_error_backtrace);
    raise;
end send_email;

procedure create_queue is
begin
  msg('create_queue ' || queue_name);

  dbms_aqadm.create_queue_table
    (queue_table        => user||'.'||queue_table
    ,queue_payload_type => user||'.'||payload_type
    ,sort_list          => 'priority,enq_time'
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
  r_opt dbms_aqadm.aq$_purge_options_t;
begin
  msg('purge_queue ' || queue_table);

  dbms_aqadm.purge_queue_table
    (queue_table     => user||'.'||queue_table
    ,purge_condition => q'[ qtview.msg_state = 'EXPIRED' ]'
    ,purge_options   => r_opt);

end purge_queue;

procedure push_queue as
  r_dequeue_options    dbms_aq.dequeue_options_t;
  r_message_properties dbms_aq.message_properties_t;
  msgid                raw(16);
  payload              t_mailgun_email;
  dequeue_count        integer := 0;
begin
  msg('push_queue');
  
  -- commit any emails requested in the current session
  commit;
  
  r_dequeue_options.wait := dbms_aq.no_wait;

  -- loop through all messages in the queue until there is none
  -- exit this loop when the e_no_queue_data exception is raised.
  loop    

    dbms_aq.dequeue
      (queue_name         => user||'.'||queue_name
      ,dequeue_options    => r_dequeue_options
      ,message_properties => r_message_properties
      ,payload            => payload
      ,msgid              => msgid
      );

    -- process the message
    mailgun_pkg.send_email (p_payload => payload);  

    commit; -- the queue will treat the message as succeeded
    
    -- don't bite off everything in one go
    dequeue_count := dequeue_count + 1;    
    exit when dequeue_count >= max_dequeue_count;
  end loop;

exception
  when e_no_queue_data then
    msg('push_queue finished');
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
    ,job_type        => 'stored_procedure'
    ,job_action      => $$PLSQL_UNIT||'.push_queue'
    ,start_date      => systimestamp
    ,repeat_interval => p_repeat_interval
    );

  dbms_scheduler.set_attribute(job_name,'restartable',true);

  dbms_scheduler.enable(job_name);

end create_job;

procedure drop_job is
begin
  msg('drop_job ' || job_name);

  dbms_scheduler.drop_job (job_name);

end drop_job;

end mailgun_aq_pkg;
/

show errors