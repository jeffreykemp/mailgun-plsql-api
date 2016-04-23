prompt install.sql
prompt mailgun v0.4
-- run this script in the schema in which you wish the objects to be installed.

@create_tables.sql
@create_types.sql
@mailgun_pkg.pks
@mailgun_pkg.pkb

prompt create queue
begin mailgun_pkg.create_queue; end;
/

prompt create scheduler job
begin mailgun_pkg.create_job; end;
/

prompt attempt to recompile any invalid objects
begin dbms_utility.compile_schema(user,false); end;
/

set feedback off heading off

prompt list mailgun objects
select object_type, object_name, status from user_objects where object_name like '%MAILGUN%' order by object_type, object_name;

prompt list mailgun queues
select name, queue_table from user_queues where name like '%MAILGUN%' order by name;

prompt list mailgun scheduler jobs
select job_name, 'enabled='||enabled status, job_action, repeat_interval from user_scheduler_jobs where job_name like '%MAILGUN%';

prompt finished.
set feedback on heading on
