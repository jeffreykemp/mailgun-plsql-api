prompt install.sql
prompt mailgun v0.7
-- run this script in the schema in which you wish the objects to be installed.

@create_tables.sql
@create_types.sql
@mailgun_pkg.pks
@mailgun_pkg_with_logger.pkb

prompt create queue
begin mailgun_pkg.create_queue; end;
/

prompt create scheduler jobs
begin mailgun_pkg.create_job; end;
/

begin mailgun_pkg.create_purge_job; end;
/

prompt attempt to recompile any invalid objects
begin dbms_utility.compile_schema(user,false); end;
/

prompt update api_version
merge into mailgun_settings t
using (select 'api_version' as nm, '0.7' as val from dual) s
on (t.setting_name = s.nm)
when matched then update set setting_value = s.val
when not matched then insert (setting_name, setting_value)
values (s.nm, s.val);

commit;

begin logger.log_permanent('Mailgun PL/SQL API installed v0.7', 'mailgun'); end;
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