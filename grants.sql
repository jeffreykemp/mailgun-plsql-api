-- grants required for mailgun_pkg v0.7
undef myschema

accept myschema prompt 'Enter the schema in which you will install mailgun:'

grant create table to &&myschema;
grant create job to &&myschema;
grant create procedure to &&myschema;
grant create type to &&myschema;

grant execute on sys.dbms_aq to &&myschema;
grant execute on sys.dbms_aqadm to &&myschema;
grant execute on sys.dbms_job to &&myschema;
grant execute on sys.dbms_scheduler to &&myschema;
grant execute on sys.utl_http to &&myschema;
